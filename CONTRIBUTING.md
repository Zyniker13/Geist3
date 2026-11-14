# Contributing

Thank you for looking at zTop. This file is the short version; `AGENTS.md`
and the decision records in `docs/decisions/` carry the details.

## Prerequisites

- Rust stable (edition 2024, so 1.85+).
- macOS only: Xcode with the Swift 6 toolchain and XcodeGen.
- Linux: nothing beyond Rust for the Rust parts.

## Build and check

- `cargo build && cargo test` builds and tests the workspace; collector tests
  run against recorded fixtures, never against the machine you are on.
- `xcodegen generate` in `app/` regenerates the Xcode project from
  `project.yml`; the generated `.xcodeproj` is never committed.
- `scripts/check.sh` runs exactly what CI runs. Run it before every push.

## Rules

1. Every behavior change comes with tests; every bug fix starts with a
   regression test.
2. Collectors are tested against recorded fixtures. Record one on your
   machine with `ztop capture --out <dir>`; the built-in allowlist records no
   host-identifying values. Never commit a fixture or screenshot containing
   a real hostname, username, IP address, serial number, or a process list
   from your own machine — use obviously fake values (`host-a`, `alice`).
3. Every source file carries `// SPDX-License-Identifier: MIT OR Apache-2.0`
   and every crate declares the same dual license. New dependencies need a
   decision record in `docs/decisions/` and must keep `cargo deny check`
   green.
4. Record significant decisions in `docs/decisions/` (Context, Decision,
   Consequences), numbered in order, before or with the code that relies on
   them.
5. Keep `docs/parity.md` honest: check an item only when a test or a
   recorded check shows it.
6. Nothing private in the repository: no secrets, tokens, keys, email
   addresses, hostnames, IP addresses or local paths outside the repository.
   Commit messages describe the code only.
7. Never force-push or rewrite pushed history.

## Style

- Rust: `rustfmt` defaults; clippy clean at `-D warnings`.
- Swift: match the existing style; tests use Swift Testing (`#expect`).
- TUI screens are snapshot-tested at 80x24 with `ratatui`'s `TestBackend`;
  a screen that looks wrong is a bug.

## Pull requests

- Small and focused; every commit green on `scripts/check.sh`.
- Commit messages describe what changed and why, and name the milestone
  (M0–M8) the work belongs to.

## License

MIT OR Apache-2.0, at your option. By contributing you agree your work is
released under both.
