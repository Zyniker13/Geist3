# Working in This Repository

This guide is for anyone, human or agent, changing this repository. Read `STATUS.md`, `ROADMAP.md` and `DESIGN.md` first: they say where the work stands, what comes next and how the pieces fit.

## Priorities

Correctness, then security, then low overhead, then features. A monitor that lies, leaks or eats the machine it watches is worse than none.

## Rules

- Run `scripts/check.sh` before every push. It runs exactly what CI runs (Rust format, lint and tests; Swift build and tests; packaging checks); keep the two identical.
- Every change that alters behavior comes with tests, and every bug fix starts with a regression test. Collectors are tested against recorded fixtures (`/proc` and `/sys` snapshots, captured macOS samples), so tests never depend on the machine they run on.
- Keep `docs/parity.md` honest: an item is checked only when it works and a test or a recorded check shows it.
- Record each significant decision in `docs/decisions/` (Context, Decision, Consequences), numbered in order.
- Keep `STATUS.md` current: current milestone, last done, next step, blocked on, and a log line.
- Work on `main` in small commits that keep CI green. Never force-push or rewrite pushed history.
- Add dependencies only from crates.io and Swift Package Manager sources with a decision record, prefer well-known maintained ones, and make sure `cargo deny check` passes.
- Every crate, package and source file header uses the project license, `MIT OR Apache-2.0`; check dependency licenses with `cargo deny` so none forces a different one.
- Pin GitHub Actions to full commit SHAs and keep workflow permissions read-only.
- Never commit secrets, signing certificates, provisioning profiles, email addresses, hostnames, IP addresses, or local paths outside the repository. Test data uses obviously fake values (`host-a`, `alice`, `example.com`). Commit messages describe the code only.
