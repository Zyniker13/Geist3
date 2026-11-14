# 0003: Agent and hub runtime — tokio, axum, rustls

## Context

The agent and the hub serve a versioned protocol over HTTP and WebSocket (DESIGN.md). Both must run unprivileged on macOS and Linux, and from M4 they need TLS 1.3 with per-agent self-signed certificates and client-side pinning. No hand-written cryptography, ever.

## Decision

- Async runtime: `tokio` (multi-thread).
- HTTP and WebSocket: `axum` (0.8 line).
- TLS (from M4): `rustls`, with material loaded through `rustls-pemfile`; certificates are self-signed per agent and pinned by the client. Nothing about TLS is written by hand.
- Both bind to `127.0.0.1` by default; a non-loopback listen address only becomes configurable through the agent config in M4.

## Consequences

- rustls keeps the TLS story pure-Rust and auditable, and avoids OpenSSL linkage, which keeps cross-compiling to Linux targets simple.
- axum's extractor model fits the protocol's shape: HTTP endpoints for snapshot, processes and history plus one WebSocket upgrade route for the live stream.
- Dependencies are added when first used: M0 ships the skeleton on tokio + axum; rustls arrives with M4's pairing work under this decision.
