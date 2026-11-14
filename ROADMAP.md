# Roadmap

The goal is version 0.1.0: a `ztop` utility for macOS and Linux with at least `htop` and `asitop` parity and an agent mode, and a universal iPad and Mac app that watches a whole fleet through it. 0.1.0 is done when every milestone below meets its "Done when" line.

Work runs milestone by milestone, in order. Each milestone ends with `scripts/check.sh` and CI green and an entry in [STATUS.md](STATUS.md). Iterating is expected: a later milestone may reopen an earlier one, and that change is recorded in `docs/decisions/`.

## Not in Scope for 0.1.0

Windows, remote command execution of any kind, a cloud service or accounts, and iPhone layouts (keep the code ready for them). Later candidates: iPhone, BSD, long-term metric export (Prometheus), and push notifications through a hub.

## Stack

| Part | Choice |
| --- | --- |
| `ztop` | Rust (stable), a Cargo workspace: `core` (data model, collectors, protocol), `tui`, `agent`, `hub`, and the `ztop` binary |
| TUI | `ratatui` + `crossterm` (confirm in a decision) |
| Agent and hub | `tokio`, `axum` (HTTP + WebSocket), `rustls`; SQLite through `sqlx` for the hub |
| macOS data | `libproc`, `sysctl`, `host_statistics64`, IOKit, IOReport, SMC, through small, audited FFI modules |
| App | Swift 6, SwiftUI, Swift Charts; one multiplatform target for iPad and Mac; `ZTopKit` Swift package; XcodeGen project file |
| Tests | `cargo test` with recorded fixtures and `ratatui` test-backend snapshots; Swift Testing for ZTopKit and the app; UI screenshots checked by eye at each app milestone |
| CI | GitHub Actions: Linux (Rust, packaging) and macOS (Rust, Swift, app build) on every push |

## M0: Foundations

- Cargo workspace, Swift package and XcodeGen app skeleton, all building clean; `scripts/check.sh` and an identical CI workflow on Linux and macOS.
- `docs/architecture.md` (crates, data model, protocol sketch), `docs/threat-model.md`, `SECURITY.md`, `CONTRIBUTING.md`, and decisions for the stack choices.
- A fixture format and a `ztop capture` command that records a host's raw inputs for tests.
- **Done when:** check.sh and CI are green on both platforms, and the docs above exist.

## M1: Linux Collectors and Basic TUI

- Linux collector for CPU (per core), memory, swap, load, uptime, processes and threads, disks, network, temperatures, fans and battery, each tested against fixtures from at least two different machines.
- A first TUI: header meters and a sortable process table, rendering correctly at 80x24 and at large sizes.
- **Done when:** `ztop` runs on Linux in CI against fixtures and on a real Linux host in a recorded smoke test, and every collector field has a fixture test.

## M2: macOS Collectors and Apple Silicon

- macOS collector for the same set, plus IOReport power and frequency (E and P clusters, per core, GPU, ANE, package) and SMC temperatures and fans, all without root.
- Values checked against `powermetrics` on this Mac in a recorded comparison (within a stated tolerance), and against fixtures in tests.
- Intel Macs and Linux degrade cleanly: unavailable metrics say so.
- **Done when:** the macOS collector passes its fixture tests and the recorded `powermetrics` comparison is in `docs/`.

## M3: Full TUI Parity

- Every `htop` and `asitop` item in [docs/parity.md](docs/parity.md): tree view, filter, search, follow, tag, signals, renice, user filter, threads, I/O columns, setup screens for meters, columns and colors, mouse, the Apple Silicon screen with charts, and a saved config file.
- The extra panels: disks, network, temperatures and fans, Linux GPUs and cgroups.
- **Done when:** every TUI item in docs/parity.md is checked with a test or a recorded check, and snapshot tests cover each screen.

## M4: Agent and Protocol

- `ztop agent`: sampling, ring-buffer history, the versioned protocol (WebSocket stream, HTTP snapshot, processes, history), TLS with pairing and pinned certificates, token listing and revocation, Bonjour, localhost-only until configured.
- Signals and renice over the protocol only when the agent config allows it and the token has the right.
- launchd and systemd service files.
- **Done when:** integration tests cover pairing, streaming, history, revocation and refused actions, and a CLI client (`ztop connect`) shows a remote host's live data.

## M5: ZTopKit and the App Core

- `ZTopKit`: protocol client, models, pairing, certificate pinning, Keychain storage, reconnection, tested against a real `ztop agent` started by the tests.
- The app: add a host (Bonjour or manual), pair, and see the fleet overview update live on iPad and Mac.
- **Done when:** the app pairs with two agents and shows both live in recorded screenshots on an iPad simulator and the Mac, and ZTopKit tests pass in CI.

## M6: Host Detail, Alerts and Hub

- Host detail with charts for every metric, the Apple Silicon view, the process list (and signals where allowed), disks, network, temperatures and fans.
- Alerts with thresholds and local notifications.
- `ztop hub` with SQLite history, and the Mac app able to install and run it as a login item; the iPad reaches the fleet through the hub.
- **Done when:** every app item in docs/parity.md is checked, and an iPad simulator watches three agents through a hub in a recorded check.

## M7: Packaging

- Homebrew formula with a `brew services` agent; `.deb` packages for amd64 and arm64 with a systemd unit and a dedicated user; a man page.
- Install, upgrade and uninstall each tested in CI (Linux container for the `.deb`, macOS runner for the formula).
- **Done when:** a clean macOS runner and a clean Debian or Ubuntu container each install `ztop`, start the agent, and pair with a test client in CI.

## M8: Hardening and 0.1.0

- Fuzz every network-facing parser; review the threat model item by item against tests and mitigations.
- Measure the agent's CPU and memory against the budget in DESIGN.md on macOS and Linux, and fix what misses.
- Accessibility pass on the app (VoiceOver, Dynamic Type, contrast), and a final look at every screen.
- CHANGELOG.md, version bumps, a clean-checkout build of everything following the docs.
- **Done when:** every item in docs/parity.md is checked, the budget is met and recorded, CI is green, and `v0.1.0` is tagged.
