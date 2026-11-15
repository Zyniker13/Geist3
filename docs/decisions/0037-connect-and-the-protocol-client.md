# 0037: `ztop connect` and the protocol client

## Context

M3's one open parity item was `ztop connect`: drive the TUI from a
remote agent. The protocol v1 server (decision 0035) and the live
stream (decision 0036) existed; nothing spoke to them from Rust yet.

## Decision

- The client lives in `ztop_core::client`, so the binary, the tests
  and (later) the hub share it. `RemoteCollector` implements
  `Collector` by fetching `/v1/snapshot` over plain HTTP/1.1 with a
  minimal, auditable request/response parser: one connection per
  fetch with `Connection: close`, `Content-Length` and `chunked`
  bodies supported, everything else an honest error.
- The client unwraps the envelope and checks `protocol` first (0035's
  rule); `PROTOCOL_VERSION` now lives in `ztop_core::client` and the
  agent re-exports it, so both halves share one number.
- `ztop connect <target>` runs the ordinary TUI loop with a
  `RemoteCollector`, so every key and screen works unchanged. Connect
  forces observation-only regardless of `--readonly`: until control
  actions exist over the protocol, a signal or renice would hit the
  local process table under the same pid — the worst kind of mistake.
- The round trip is tested in-process: the agent crate's tests serve
  the real router on an ephemeral port and read it with the client
  (`the_remote_collector_reads_a_live_agent`,
  `the_remote_collector_reports_a_warm_up_agent_as_unavailable`).

## Consequences

- No new dependency: the client is std TCP plus string parsing; TLS
  will wrap the same fetch when pairing lands (decision 0003).
- A connect TUI costs one HTTP handshake per tick (seconds apart);
  the live stream is for the app's continuous charts, not the TUI.
- Cross-compiling the client is trivial: std TCP only, no
  platform-specific code.
