# 0005: CLI, serialization and Rust edition

## Context

The single `ztop` binary has several modes (interactive TUI, `capture`, `agent`, `hub`, `connect`) that need argument parsing. Fixtures, config files and the protocol's HTTP payloads all need serialization. The workspace needs a pinned edition so macOS and Linux builds behave identically.

## Decision

- CLI: `clap` v4 with derive. `ztop --help` output is the base for the man page (M7).
- Serialization: `serde` + `serde_json`. The fixture manifest, agent and hub configs, and the protocol's HTTP/WS payloads are serde types; JSON is the protocol payload format.
- Rust edition 2024 across the workspace; crates start at version 0.1.0.

## Consequences

- One serialization stack everywhere; fixture files stay human-inspectable text where the underlying input was text.
- clap gives the man-page-friendly help that the parity checklist requires.
- Edition 2024 requires Rust 1.85+; CI uses current stable, which is newer.
