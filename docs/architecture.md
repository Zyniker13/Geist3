# Architecture

zTop watches a mixed fleet of Macs and Linux machines. Three cooperating
parts share one data model and one wire protocol:

- **`ztop`** — one Rust binary. With no arguments it is an interactive
  terminal monitor. `ztop capture` records a host's raw inputs as a fixture.
  `ztop agent` serves one host's metrics over the protocol. `ztop hub`
  collects from many agents and serves them as one. `ztop connect` drives the
  TUI from a remote agent or hub.
- **zTop app** — a universal SwiftUI app for iPad and Mac: a fleet overview
  and a detail view for any one machine.
- **ZTopKit** — the Swift package with the protocol client, models and
  pairing, used by the app and its tests.

## The workspace

| Path | Contents |
| --- | --- |
| `crates/core` | The data model, the `Collector` trait, the fixture format and `capture` |
| `crates/tui` | The terminal monitor (ratatui + crossterm; decision 0002) |
| `crates/agent` | The agent: sampling, history, protocol serving (tokio + axum; decision 0003) |
| `crates/hub` | The hub: fleet collection and history (SQLite through sqlx from M6; decision 0004) |
| `crates/ztop` | The `ztop` binary: clap CLI and dispatch (decision 0005) |
| `swift/ZTopKit` | The Swift package (decision 0006) |
| `app/` | The SwiftUI app; `project.yml` is the source of truth, the `.xcodeproj` is generated and never committed |

## The data model

Everything measured flows through `ztop-core` as a `Sample`: one consistent
snapshot of one host at one instant — CPU per core, memory and swap, load
average, uptime, and the process table.

- Every metric is a `Metric`: a value, a `Unit`, and an explicit `available`
  flag. A metric the host does not provide (Apple Silicon power on Linux,
  other users' per-process I/O for an unprivileged agent) is
  `available: false`, not missing, so screens keep their layout and can say
  "not available" instead of showing a fake zero.
- Collectors implement one `Collector` trait, one per platform, pull-based:
  the TUI, the agent and the recorder each call `sample()` on their own
  cadence. M1 adds the Linux collector, M2 the macOS collector.
- Units are explicit (`bytes_per_second`, `celsius`, `watts`, ...) so charts,
  thresholds and formatting never guess.

## Fixtures

Collectors are tested against recorded fixtures, never against the machine a
test happens to run on. `ztop capture` records a host's raw inputs:

    manifest.json          # format, platform, arch, kernel, captured_at, source, entries
    data/<entry-name>      # one file per recorded input, verbatim

Entry names are restricted to `[A-Za-z0-9._-]`, every manifest path must be
`data/<name>`, and the format is versioned (`format: 1`) — opening a fixture
of an unknown format fails loudly. The capture allowlist contains no
host-identifying values (no serial numbers, no hostnames, no usernames); see
`docs/threat-model.md`.

## The protocol (sketch; built in M4)

A versioned protocol over HTTP + WebSocket, TLS 1.3 end to end:

- `GET /healthz` — liveness (exists from M0).
- `GET /api/v1/snapshot` — the newest sample.
- `GET /api/v1/processes` — the process table.
- `GET /api/v1/history?from=…&to=…` — ring-buffer history.
- `WS /api/v1/stream` — live samples.

The agent binds `127.0.0.1` unless configured otherwise. Before any remote
client is served: TLS 1.3 with a self-signed per-agent certificate, pairing
by a short code (and a QR code) that yields a long-lived token, and
client-side pinning of the agent's certificate. Tokens are listed and
revoked on the agent. The hub speaks the same protocol, so a client cannot
tell a hub from an agent by its surface. Signals and renice are refused
unless the agent's config enables them and the token carries that right.
There is no remote shell or command execution of any kind, ever.

## The app

ZTopKit owns speaking the protocol (client, models, pairing, certificate
pinning, Keychain storage, reconnection). The app layers two views on it:
a fleet overview (one compact card per host, stale hosts obvious) and a host
detail (Swift Charts for every metric, the Apple Silicon view, a sortable
process list, disks, network, temperatures and fans), plus alerts with local
notifications. Tokens live in the Keychain. No accounts, no cloud service,
no analytics.

## Testing

- Rust: `cargo test` with fixture-driven collector tests and `TestBackend`
  snapshot tests for the TUI (80x24 first).
- Swift: Swift Testing for ZTopKit and the app.
- `scripts/check.sh` runs exactly what CI runs — run it before every push.
- App milestones add screenshots under `docs/screenshots/`, checked by eye.
