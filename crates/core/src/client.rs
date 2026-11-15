// SPDX-License-Identifier: MIT OR Apache-2.0
//! The protocol client: fetch samples from an agent or hub.
//!
//! [`RemoteCollector`] implements [`Collector`] by fetching
//! `/v1/snapshot` over HTTP/1.1, so `ztop connect` can drive the
//! regular TUI loop against a remote host. Plain loopback needs no
//! TLS; for a remote host the collector speaks TLS (rustls, sync
//! `StreamOwned`) and verifies nothing but the pin the user gave:
//! the agent's self-signed certificate must hash to exactly
//! `SHA256:<hex>` (decision 0039). With a token the requests carry
//! `Authorization: Bearer`; a 401 reads as "pair first".
//! [`pair_with`] trades a pairing code for a token over that same
//! pinned TLS, and the saved trust lives per host under the state
//! dir so a later connect re-pins without re-pairing.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use sha2::Digest;

use crate::collector::{CollectError, Collector};
use crate::control::Plan;
use crate::model::Sample;

/// The protocol version this client speaks; agents and hubs answer in
/// the same envelope (decision 0035).
pub const PROTOCOL_VERSION: u32 = 1;

/// The protocol paths the client fetches.
pub const SNAPSHOT_PATH: &str = "/v1/snapshot";

/// The control route a remote plan is POSTed to.
const CONTROL_PATH: &str = "/v1/control";

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
    /// The pinned TLS configuration; `None` speaks plain HTTP.
    tls: Option<Arc<rustls::ClientConfig>>,
    /// The bearer token from pairing, if any.
    token: Option<String>,
}

impl RemoteCollector {
    /// Point the collector at `host:port` with a five-second timeout,
    /// plain HTTP.
    pub fn new(target: String) -> Self {
        Self {
            target,
            timeout: Duration::from_secs(5),
            tls: None,
            token: None,
        }
    }

    /// Point the collector at `host:port` over TLS, trusting only the
    /// pin: the leaf certificate must hash to it. `pin` is what the
    /// agent printed, `SHA256:<hex>`.
    pub fn tls(target: String, pin: &str, token: Option<String>) -> Result<Self, CollectError> {
        Ok(Self {
            tls: Some(tls_config_for(pin).map_err(|_| CollectError::Unavailable {
                origin: "pin",
                what: "a fingerprint the agent would print: SHA256:<64 hex>",
            })?),
            target,
            timeout: Duration::from_secs(5),
            token,
        })
    }
}

/// A client configuration whose only trust is the pin: the verifier
/// hashes the leaf certificate and compares. Signature checks still
/// run against the provider's algorithms, so a broken handshake is
/// not mistaken for a mismatched pin.
#[derive(Debug)]
struct PinVerifier {
    pin: [u8; 32],
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl rustls::client::danger::ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        let hash = sha2::Sha256::digest(end_entity.as_ref());
        if hash.as_slice() == self.pin {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "the agent's certificate does not match the pin".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Parse `SHA256:<64 hex>` into the 32 pin bytes.
fn parse_pin(pin: &str) -> Option<[u8; 32]> {
    let hex = pin.strip_prefix("SHA256:")?;
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut bytes = [0u8; 32];
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16).ok()?;
    }
    Some(bytes)
}

/// Build the pinned client configuration for `pin`.
fn tls_config_for(pin: &str) -> Result<Arc<rustls::ClientConfig>, ()> {
    let pin = parse_pin(pin).ok_or(())?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("the TLS 1.3 version is supported")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinVerifier { pin, provider }))
        .with_no_client_auth();
    config.alpn_protocols = Vec::new();
    Ok(Arc::new(config))
}

/// The `ServerName` to open a TLS session with: the host part of
/// `host:port` (brackets of an IPv6 literal stripped). The pin
/// verifier ignores it; rustls still wants a parseable name.
fn server_name_of(target: &str) -> Option<rustls::pki_types::ServerName<'static>> {
    let host = target
        .rsplit_once(':')
        .map(|(host, _)| host)
        .unwrap_or(target);
    let host = host.trim_start_matches('[').trim_end_matches(']');
    rustls::pki_types::ServerName::try_from(host.to_string()).ok()
}

/// One HTTP/1.1 POST of `body` against `host:port` over pinned TLS,
/// returning the status and body text.
fn https_post(
    target: &str,
    path: &str,
    body: &str,
    config: &Arc<rustls::ClientConfig>,
    token: Option<&str>,
    timeout: Duration,
) -> Result<(u16, String), CollectError> {
    let name = server_name_of(target).ok_or(CollectError::Unavailable {
        origin: "target",
        what: "a host a TLS session can name",
    })?;
    let mut stream = rustls::StreamOwned::new(
        rustls::ClientConnection::new(config.clone(), name).map_err(tls_error)?,
        {
            let tcp = TcpStream::connect(target).map_err(CollectError::Io)?;
            tcp.set_read_timeout(Some(timeout))
                .map_err(CollectError::Io)?;
            tcp.set_write_timeout(Some(timeout))
                .map_err(CollectError::Io)?;
            tcp
        },
    );
    exchange(&mut stream, "POST", target, path, Some(body), token)
}

/// The TLS handshake or session layer failed before HTTP.
fn tls_error(error: rustls::Error) -> CollectError {
    CollectError::Unavailable {
        origin: "tls",
        what: match error {
            rustls::Error::General(message) if message.contains("pin") => {
                "a certificate matching the pin"
            }
            _ => "a completed TLS handshake",
        },
    }
}

impl Collector for RemoteCollector {
    fn sample(&mut self) -> Result<Sample, CollectError> {
        let body = match (&self.tls, &self.token) {
            (Some(config), token) => {
                let (status, text) = https_get(
                    &self.target,
                    SNAPSHOT_PATH,
                    config,
                    token.as_deref(),
                    self.timeout,
                )?;
                // A refused token is a pairing problem, not a broken
                // agent: say so instead of a generic failure.
                if status == 401 {
                    return Err(CollectError::Unavailable {
                        origin: "agent",
                        what: "a paired token (401): pair with --code",
                    });
                }
                text
            }
            (None, _) => http_get(&self.target, SNAPSHOT_PATH, self.timeout)?,
        };
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

    /// Forward the plan to the agent. Control needs the authenticated
    /// channel: a plaintext connect refuses, and the agent answers
    /// per-pid results that become the same `Vec` the local path
    /// produces, so the status line reads identically either way.
    fn execute_plan(&mut self, plan: &Plan) -> Vec<(u32, Result<(), String>)> {
        let refuse = |message: String| {
            plan.pids
                .iter()
                .map(|pid| (*pid, Err(message.clone())))
                .collect()
        };
        let Some(config) = self.tls.clone() else {
            return refuse(
                "control needs --tls: the action would cross an unauthenticated channel"
                    .to_string(),
            );
        };
        let Some(token) = self.token.clone() else {
            return refuse("a paired token (401): pair with --code".to_string());
        };
        let body = match serde_json::to_string(plan) {
            Ok(body) => body,
            Err(error) => return refuse(format!("serializing the plan failed: {error}")),
        };
        let (status, text) = match https_post(
            &self.target,
            CONTROL_PATH,
            &body,
            &config,
            Some(&token),
            self.timeout,
        ) {
            Ok(answer) => answer,
            Err(error) => return refuse(error.to_string()),
        };
        match status {
            200 => parse_control_reply(&text, &plan.pids),
            401 => refuse("a paired token (401): pair with --code".to_string()),
            403 => refuse(if text.trim().is_empty() {
                "the agent refuses control for this token".to_string()
            } else {
                format!("the agent refuses: {}", text.trim())
            }),
            _ => refuse(format!(
                "the agent answered {status} to the control request"
            )),
        }
    }
}

/// The agent's per-pid answer to a control plan.
#[derive(Debug, serde::Deserialize)]
struct ControlOutcome {
    pid: u32,
    ok: bool,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
struct ControlReply {
    results: Vec<ControlOutcome>,
}

/// Map the agent's reply onto the plan's pids: every pid the agent did
/// not answer for reads as a failure, so the counts always add up.
fn parse_control_reply(text: &str, pids: &[u32]) -> Vec<(u32, Result<(), String>)> {
    let reply: ControlReply = serde_json::from_str(text).unwrap_or(ControlReply {
        results: Vec::new(),
    });
    let answered: std::collections::HashMap<u32, Result<(), String>> = reply
        .results
        .into_iter()
        .map(|outcome| {
            let result = if outcome.ok {
                Ok(())
            } else {
                Err(outcome.error.unwrap_or_else(|| "refused".to_string()))
            };
            (outcome.pid, result)
        })
        .collect();
    pids.iter()
        .map(|pid| {
            (
                *pid,
                answered
                    .get(pid)
                    .cloned()
                    .unwrap_or_else(|| Err("the agent did not answer for this pid".to_string())),
            )
        })
        .collect()
}

/// One HTTP/1.1 GET against `host:port` over pinned TLS, returning the
/// status and body.
fn https_get(
    target: &str,
    path: &str,
    config: &Arc<rustls::ClientConfig>,
    token: Option<&str>,
    timeout: Duration,
) -> Result<(u16, String), CollectError> {
    let name = server_name_of(target).ok_or(CollectError::Unavailable {
        origin: "target",
        what: "a host a TLS session can name",
    })?;
    let mut stream = rustls::StreamOwned::new(
        rustls::ClientConnection::new(config.clone(), name).map_err(tls_error)?,
        {
            let tcp = TcpStream::connect(target).map_err(CollectError::Io)?;
            tcp.set_read_timeout(Some(timeout))
                .map_err(CollectError::Io)?;
            tcp.set_write_timeout(Some(timeout))
                .map_err(CollectError::Io)?;
            tcp
        },
    );
    exchange(&mut stream, "GET", target, path, None, token)
}

/// Trade a pairing code for a token: `POST /v1/pair` over pinned TLS.
/// The error text is what `ztop connect` prints.
pub fn pair_with(target: &str, pin: &str, code: &str) -> Result<String, String> {
    let config = tls_config_for(pin).map_err(|()| {
        "the pin must look like what the agent prints: SHA256:<64 hex>".to_string()
    })?;
    let body = serde_json::json!({ "code": code }).to_string();
    let (status, text) = https_post(target, "/v1/pair", &body, &config, None, PAIR_TIMEOUT)
        .map_err(|error| error.to_string())?;
    if status == 403 {
        return Err("the pairing code does not match, is used up or expired".to_string());
    }
    if status != 200 {
        return Err(format!("the agent answered {status} to the pairing"));
    }
    let answer: serde_json::Value = serde_json::from_str(&text)
        .map_err(|_| "the agent answered no understandable token".to_string())?;
    answer["token"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "the agent answered no understandable token".to_string())
}

/// The pairing round trip gets its own, shorter timeout: a code lives
/// five minutes, so an unreachable agent should fail fast, not hang
/// the terminal for five seconds.
const PAIR_TIMEOUT: Duration = Duration::from_secs(3);

/// The saved trust for one remote host:
/// `state_dir()/hosts/<sanitized host>.json`, mode 0600.
///
/// The host is sanitized for the file name (anything outside ASCII
/// letters, digits and `.`, `_`, `-` becomes `_`) but kept verbatim in
/// the record; a record whose `host` does not match is ignored, so a
/// name collision cannot hand out one host's token to another.
pub fn save_host_token(dir: &Path, host: &str, pin: &str, token: &str) -> std::io::Result<()> {
    let file = host_file(dir, host);
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let record = serde_json::json!({ "host": host, "pin": pin, "token": token });
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&file)?;
    serde_json::to_writer_pretty(&mut file, &record)?;
    Ok(())
}

/// The saved `(pin, token)` for `host`, or `None` when the host was
/// never paired (or its record belongs to another host).
pub fn load_host_token(dir: &Path, host: &str) -> Option<(String, String)> {
    let text = std::fs::read_to_string(host_file(dir, host)).ok()?;
    let record: serde_json::Value = serde_json::from_str(&text).ok()?;
    if record["host"].as_str()? != host {
        return None;
    }
    Some((
        record["pin"].as_str()?.to_string(),
        record["token"].as_str()?.to_string(),
    ))
}

/// Where `host`'s saved trust lives under `dir`.
fn host_file(dir: &Path, host: &str) -> PathBuf {
    let safe: String = host
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    dir.join("hosts").join(format!("{safe}.json"))
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
    let (status, text) = exchange(&mut stream, "GET", target, path, None, None)?;
    if status >= 400 {
        return Err(CollectError::Unavailable {
            origin: "agent",
            what: "a successful response",
        });
    }
    Ok(text)
}

/// Write one request, read the whole response, and return the status
/// with the body. Works for any stream that reads and writes bytes:
/// a plain `TcpStream` or a TLS session over one. Timeouts belong to
/// the socket and are set by the caller before the stream arrives.
fn exchange<S: Read + Write>(
    stream: &mut S,
    method: &str,
    target: &str,
    path: &str,
    body: Option<&str>,
    token: Option<&str>,
) -> Result<(u16, String), CollectError> {
    let authorization = token
        .map(|token| format!("Authorization: Bearer {token}\r\n"))
        .unwrap_or_default();
    let payload = body.unwrap_or_default();
    let content = body
        .map(|body| {
            format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                body.len()
            )
        })
        .unwrap_or_default();
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: {target}\r\nAccept: application/json\r\n\
         {authorization}{content}Connection: close\r\n\r\n{payload}"
    );
    stream
        .write_all(request.as_bytes())
        .map_err(CollectError::Io)?;
    // A TLS session buffers writes and only sends on flush; a plain
    // socket flushes immediately, so this is a no-op there.
    stream.flush().map_err(CollectError::Io)?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).map_err(CollectError::Io)?;

    let text = String::from_utf8(raw).map_err(|_| CollectError::Unavailable {
        origin: "agent",
        what: "a text HTTP response",
    })?;
    let (head, rest) = text
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
    let chunked = head
        .lines()
        .any(|line| line.eq_ignore_ascii_case("transfer-encoding: chunked"));
    let body = if chunked {
        dechunk(rest)?
    } else {
        let length = head.lines().find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().ok())?
        });
        match length {
            // Exactly the announced bytes: the connection may have shut
            // down cleanly, so a short read is an error, not EOF.
            Some(length) if rest.len() >= length => rest[..length].to_string(),
            Some(_) => {
                return Err(CollectError::Unavailable {
                    origin: "agent",
                    what: "a complete response body",
                });
            }
            // No Content-Length: with `Connection: close` the body is
            // everything up to the end of the stream.
            None => rest.to_string(),
        }
    };
    Ok((status, body))
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
    fn a_pin_parses_when_well_formed_and_fails_otherwise() {
        let hex: String = "ab".repeat(32);
        assert_eq!(parse_pin(&format!("SHA256:{hex}")), Some([0xab; 32]));
        // Wrong prefix, wrong length, non-hex digits: all refused.
        assert_eq!(parse_pin(&format!("sha256:{hex}")), None);
        assert_eq!(parse_pin(&format!("SHA256:{hex}a")), None);
        assert_eq!(parse_pin("SHA256:zz"), None);
        assert_eq!(parse_pin("7100"), None);
    }

    #[test]
    fn saved_host_trust_round_trips_and_rejects_a_foreign_host() {
        let dir = std::env::temp_dir().join(format!("ztop-hosts-{}", std::process::id()));
        save_host_token(&dir, "host-a:7100", "SHA256:00", "tok-a").expect("saves");
        assert_eq!(
            load_host_token(&dir, "host-a:7100"),
            Some(("SHA256:00".to_string(), "tok-a".to_string()))
        );
        // `h:o` and `h_o` sanitize to the same file name; the record
        // keeps the real host, so the other spelling gets nothing.
        save_host_token(&dir, "h:o", "SHA256:01", "tok-b").expect("saves");
        assert_eq!(load_host_token(&dir, "h_o"), None);
        assert_eq!(
            load_host_token(&dir, "h:o"),
            Some(("SHA256:01".to_string(), "tok-b".to_string()))
        );
        std::fs::remove_dir_all(&dir).ok();
    }

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

    #[test]
    fn control_replies_map_back_onto_the_plan() {
        let pids = [10, 20, 30];
        let reply =
            r#"{"results":[{"pid":10,"ok":true},{"pid":20,"ok":false,"error":"no such process"}]}"#;
        let results = parse_control_reply(reply, &pids);
        assert_eq!(results[0], (10, Ok(())));
        assert_eq!(results[1], (20, Err("no such process".to_string())));
        assert_eq!(
            results[2].1.as_ref().err().map(String::as_str),
            Some("the agent did not answer for this pid")
        );
        // A garbage body leaves every pid unanswered, never ok.
        let results = parse_control_reply("not json", &pids);
        assert!(results.iter().all(|(_, result)| result.is_err()));
    }
}
