// SPDX-License-Identifier: MIT OR Apache-2.0
//! The protocol client: fetch samples from an agent or hub.
//!
//! [`RemoteCollector`] implements [`Collector`] by fetching
//! `/v1/snapshot` over plain HTTP/1.1, so `ztop connect` can drive the
//! regular TUI loop against a remote host with no new dependencies.
//! TLS arrives with the pairing work (decision 0003): this module's
//! HTTP parsing is stream-agnostic, so the transport swaps out.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::collector::{CollectError, Collector};
use crate::model::Sample;

/// The protocol version this client speaks; agents and hubs answer in
/// the same envelope (decision 0035).
pub const PROTOCOL_VERSION: u32 = 1;

/// The protocol paths the client fetches.
pub const SNAPSHOT_PATH: &str = "/v1/snapshot";

/// A collector that samples a remote agent or hub instead of the local
/// host. One connection per fetch (HTTP/1.1 with `Connection: close`):
/// the TUI's cadence is seconds, so the handshake cost is noise, and a
/// dropped connection heals at the next tick instead of wedging.
#[derive(Debug)]
pub struct RemoteCollector {
    /// The `host:port` to connect to.
    target: String,
    /// Read/write timeout for one fetch.
    timeout: Duration,
}

impl RemoteCollector {
    /// Point the collector at `host:port` with a five-second timeout.
    pub fn new(target: String) -> Self {
        Self {
            target,
            timeout: Duration::from_secs(5),
        }
    }
}

impl Collector for RemoteCollector {
    fn sample(&mut self) -> Result<Sample, CollectError> {
        let body = http_get(&self.target, SNAPSHOT_PATH, self.timeout)?;
        // Clients check the protocol version before the payload
        // (decision 0035): a newer agent's envelope is a mismatch, not
        // a misread sample.
        let envelope: serde_json::Value =
            serde_json::from_str(&body).map_err(|_| CollectError::Unavailable {
                origin: "agent",
                what: "an understandable envelope",
            })?;
        let protocol = envelope.get("protocol").and_then(serde_json::Value::as_u64);
        if protocol != Some(PROTOCOL_VERSION as u64) {
            return Err(CollectError::Unavailable {
                origin: "agent",
                what: "protocol version 1",
            });
        }
        serde_json::from_value(envelope["sample"].clone()).map_err(|_| CollectError::Unavailable {
            origin: "agent",
            what: "an understandable sample",
        })
    }
}

/// One HTTP/1.1 GET against `host:port`, returning the body text.
///
/// Handles the two response shapes a small server produces: the body
/// delimited by `Content-Length`, and (for a server that streams)
/// `chunked`. Anything else — no body, a redirect, a compressed body —
/// is an error, never a guess.
fn http_get(target: &str, path: &str, timeout: Duration) -> Result<String, CollectError> {
    let mut stream = TcpStream::connect(target).map_err(CollectError::Io)?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(CollectError::Io)?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(CollectError::Io)?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {target}\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .map_err(CollectError::Io)?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).map_err(CollectError::Io)?;

    let text = String::from_utf8(raw).map_err(|_| CollectError::Unavailable {
        origin: "agent",
        what: "a text HTTP response",
    })?;
    let (head, body) = text
        .split_once("\r\n\r\n")
        .ok_or(CollectError::Unavailable {
            origin: "agent",
            what: "a complete HTTP response",
        })?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let status = status_line
        .split(' ')
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or(CollectError::Unavailable {
            origin: "agent",
            what: "an HTTP status line",
        })?;
    if status >= 400 {
        return Err(CollectError::Unavailable {
            origin: "agent",
            what: "a successful response",
        });
    }
    let chunked = head
        .lines()
        .any(|line| line.eq_ignore_ascii_case("transfer-encoding: chunked"));
    if chunked {
        return dechunk(body);
    }
    let length = head.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("content-length")
            .then(|| value.trim().parse::<usize>().ok())?
    });
    match length {
        // Exactly the announced bytes: the connection may have shut
        // down cleanly, so a short read is an error, not EOF.
        Some(length) if body.len() >= length => Ok(body[..length].to_string()),
        Some(_) => Err(CollectError::Unavailable {
            origin: "agent",
            what: "a complete response body",
        }),
        // No Content-Length: with `Connection: close` the body is
        // everything up to the end of the stream.
        None => Ok(body.to_string()),
    }
}

/// Undo `Transfer-Encoding: chunked`: a run of `size`-hex lines, each
/// followed by that many bytes, until a zero-size chunk.
fn dechunk(body: &str) -> Result<String, CollectError> {
    let mut out = String::new();
    let mut rest = body;
    loop {
        let (size_line, after) = rest.split_once("\r\n").ok_or(CollectError::Unavailable {
            origin: "agent",
            what: "a complete chunked response",
        })?;
        let size =
            usize::from_str_radix(size_line.split(';').next().unwrap_or_default().trim(), 16)
                .map_err(|_| CollectError::Unavailable {
                    origin: "agent",
                    what: "a valid chunk size",
                })?;
        if size == 0 {
            return Ok(out);
        }
        if after.len() < size {
            return Err(CollectError::Unavailable {
                origin: "agent",
                what: "a complete chunked response",
            });
        }
        out.push_str(&after[..size]);
        rest = &after[size..];
        rest = rest.strip_prefix("\r\n").unwrap_or(rest);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RESPONSE: &str = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 15\r\n\r\n{\"protocol\": 1}\r\n";

    #[test]
    fn a_content_length_response_yields_exactly_the_body() {
        let (head, body) = RESPONSE.split_once("\r\n\r\n").expect("split");
        let length: usize = head
            .lines()
            .find_map(|l| {
                let (n, v) = l.split_once(':')?;
                n.eq_ignore_ascii_case("content-length")
                    .then(|| v.trim().parse().ok())?
            })
            .expect("length");
        assert_eq!(&body[..length], "{\"protocol\": 1}");
    }

    #[test]
    fn a_chunked_response_is_reassembled() {
        let chunked = "4\r\n{\"pr\r\n4\r\notoc\r\n4\r\nol\"}\r\n0\r\n\r\n";
        assert_eq!(dechunk(chunked).expect("dechunk"), "{\"protocol\"}");
    }

    #[test]
    fn a_truncated_chunk_is_an_error() {
        assert!(dechunk("5\r\nshort\r\n").is_err());
    }
}
