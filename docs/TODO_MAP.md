# TODO MAP — Plan Task Ledger

Purpose: one line per plan task (`Pn.k`) with its state, so a fresh session can find the current position without rereading all of `docs/plan/ROADMAP.md`. Updated after every meaningful step.

| Task | Title | State | Notes |
| --- | --- | --- | --- |
| P0.1 | Repository bootstrap | done | package moved verbatim to `docs/plan/`; §3 skeleton + docs skeletons created (commit `29e82b4`) |
| P0.2 | XcodeGen project | done | `project.yml`, app targets, Info.plists, tests; `make gen && make build` clean on iOS Simulator + macOS (commit `bcb54ae`) |
| P0.3 | Packages | done | 13 SPM packages, placeholder types, Swift Testing tests; `swift test` green in each (commit `bcb54ae`) |
| P0.4 | Tooling | done | Makefile (15 targets), SwiftLint whitelist configs + banned-API rules, swift-format, `check-imports.sh` (bash 3.2, 3 violation classes proven), `rules-cli`/`net-fuzz` stubs |
| P0.5 | CI | done | `.github/workflows/ci.yml` per CONVENTIONS §7; `reports/` gitignored |
| P0.6 | ADRs | done | ADR-0001–0020 in `docs/DECISIONS.md`, all Accepted |
| P0.7 | Competitor test sheet | done | `docs/research/COMPETITORS.md`: 8 apps, blank columns + instructions |
| P0.Z | Gate run G0 | blocked (env) | A11yKit rename done; all non-simulator checks green (`g0-evidence.log`); iOS sim devices cannot boot on this host (5 repair attempts, `docs/STATUS.md`); needs Mac reboot → then `make gate PHASE=P0`, push, CI green, tag `gate-G0-pass` |
