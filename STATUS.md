# Status

Updated after every working session.

- **Current milestone:** M2 (macOS collectors and Apple Silicon).
- **Last done:** m2-live: the macOS live collector (`ztop_core::macos_live::MacOsCollector`, gated to macOS) — decision 0010: the capture producers and the fixture parsers are shared, so a recorded capture and a live sample are interpreted identically; per-core and per-process rates are deltas between samples through the shared `core_percents` math, every source unprivileged. A live-host test asserts universal bounds over two real samples; full gate green including both Linux cross-target clippy runs.
- **Next step:** m2-power: IOReport power/frequency and SMC temps/fans probing unprivileged (decision 0009), then the recorded powermetrics-style comparison in docs/ closes M2's Done-when.
- **Blocked on:** nothing.

## Log

Newest first. One or two lines per session: what changed, what is next.

- 2026-11-14: the TUI works live on macOS: the binary draws real samples in a pty (per-core, memory, swap, load, per-process rates) and quits cleanly; the scrubbed fixture-replay snapshot is committed in docs/screenshots/. Next: IOReport power/frequency and SMC unprivileged probing, then the recorded comparison.

- 2026-11-14: m2-live done: the macOS live collector shares the capture's text producers and the fixture parsers (decision 0010), rates come from the shared per-core/per-process delta math, and a live-host test pins universal bounds over two real samples; hostinfo-without-cores keeps reporting a bad `hostinfo` source. CI green on the push.

- 2026-11-14: macOS fixtures re-recorded with per-process task fields (decision 0009 amendment): TASKINFO is same-user-only unprivileged, CPU fields are mach ticks converted to ns, the taskinfo struct size is now compile-asserted, and the scrubber keeps `-` and real-value line shapes. Next: the macOS fixture parser.

- 2026-11-14: macOS capture mode works (`capture_macos.rs`, commit A of m2-fixtures): sysctls + Mach vm stats + loadavg/swap/boottime + libproc processes; full check gate green; live capture 16 entries. Next: scrubber for macOS names, record fixtures, fixture parser.

- M2 planned: decision 0009 — macOS sources per DESIGN.md (Mach/sysctl/libproc, IOKit, IOReport via `libIOReport`, SMC), everything unprivileged; SMC and ANE probed as denied unprivileged on the dev host and recorded as unavailable-when-denied rather than faked. Next: macOS capture mode and fixtures.
- M1 closed: CI smoke, real-host recorded smoke and per-field fixture tests all verified (the fixture tests now derive expectations from the raw capture text, so fresh recordings cannot break them). Next: M2, macOS collectors.
- m1-close: the fixture tests had pinned exact machine-state values (CPU ticks, memory sizes), so the record workflow's fresh captures broke them on pull. The per-field test now re-derives every expectation from the fixture's own raw `/proc` text — parser column/unit drift still fails, re-recorded captures do not. Next: confirm CI, close M1.
- m1-ci-smoke done: `ztop replay` renders a recorded fixture through the same `draw` the live TUI uses, so no terminal is needed — the local gate replays both fixtures on every push, the record workflow self-tests each freshly scrubbed fixture before committing it, and real-host frames are recorded in `docs/screenshots/`. Next: close M1.
- m1-tui done: header meters (title, per-core gauges, memory/swap gauges, load, uptime) over a sortable process table; the render path is a pure function of UI state, so snapshot tests at 80x24 and 200x50 run without a pty, and a `--ignored` dump test prints the frame for a human eye. Wired into `ztop` behind a Linux/macOS split (Linux live collector, otherwise an unavailable placeholder).
- m1-collectors done: parsers live in a pure text module so the identical code runs on every machine; fixture integration tests pin every parsed field against both recorded captures (hostnames, 4 cores, 12 processes, disk/net counters); synthetic unit tests cover sensors (absent from the recorded hosts); the cross-target clippy gate caught three compile bugs in the Linux-only live collector before push. Next: the first TUI.
- m1-fixtures done: the job-summary transfer failed (summaries are absent from the check-run API and the job HTML), so the record workflow now scrubs and commits fixtures directly (`scripts/scrub-fixture.py`); two rounds of scrub bugs (per-pid `stat` fell outside the trim, then its gate) were caught by auditing the committed bytes; fixtures from both runners are 60 entries, all process names faked, fixed files verbatim. Next: Linux collectors against these fixtures.
- M0 closed: CI green on both platforms after fixing a Linux-only compile error and a wrong expected string in a Linux-only test (found through the new CI annotations check.sh emits on failure). Next: M1.
- M0 built: stack decisions 0002–0006, the workspace skeleton (core, tui, agent, hub, ztop), architecture/threat-model/security/contributing docs, ZTopKit and the app skeleton, the fixture format and `ztop capture`.
- Project defined (DESIGN.md, ROADMAP.md, docs/parity.md, AGENTS.md; MIT OR Apache-2.0). Next: M0.
