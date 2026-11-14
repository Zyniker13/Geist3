# Status

Updated after every working session.

- **Current milestone:** M3 (Full TUI Parity).
- **Last done:** M3 batch 6: per-process I/O — `Process.io` (`ProcessIo`: read/write byte totals and per-second rates) in the model; Linux reads `/proc/<pid>/io` for fixtures and live sampling with delta rates between samples; macOS reports none today; the TUI table gains conditional `RD/s`/`WR/s` columns shown only while a visible process moves data, so the recorded renders stay unchanged. Five new tests; gate green.
- **Next step:** M3 batch 7 — setup screens, mouse, Apple Silicon screen with charts, config file, disk/network/thermal panels; leftover parity items (`k` opens the signal menu, `-p` PID filter).
- **Blocked on:** nothing.

## Log

Newest first. One or two lines per session: what changed, what is next.

- 2026-11-14: M3 batch 6 (`a6aa908`): per-process I/O — `ProcessIo` (read/write byte totals and delta rates) joins `Process`; Linux captures `/proc/[0-9]*/io` for fixtures and reads it live with two-sample rates (a partially filled io file counts as unavailable); macOS reports none today; the TUI adds conditional `RD/s`/`WR/s` columns hidden without traffic, with compact `3.5Mi`-style cells. Five tests; gate green. Next: setup screens, mouse, Apple Silicon screen, config file.

- 2026-11-14: M3 batch 5 (`402a861`): signals and renice on the tag set — `ztop_core::control` owns the syscalls (`Control::Signal(n)` from `common_signals()`, `Control::Renice(delta)`; F7 raises priority, F8 lowers it), the TUI builds a `Plan` from the tags (or the cursor's process) and runs it in the event loop; F9 opens a centered signal menu (j/k wrap, Enter sends, Esc cancels), the outcome lands in the status line for one refresh, failures list the first error. Eight tests; gate green. Next: I/O columns.
|- 2026-11-14: M3 batch 4 (`a2683fa`): incremental search (F3 opens a live prompt — the cursor keeps its row while the pattern still matches, otherwise jumps forward; F3 again repeats; Esc/Enter close; follow re-pins) and tagging (Space tags/untags the cursor, `c` tags its visible descendants, `U` clears all; `*` row marker, `tagged:` in the status line). Four tests; gate green. Next: signals and renice on the tag set, then I/O columns.

|- 2026-11-14: M3 batch 2 (`8f2854a`): selection cursor (`j`/`k`, arrows) with highlight and scroll-into-view, follow (`F`) pinned by pid across samples, `follow:` shown in the status line. Five tests; gate green. Next: tree view, F3 search, tagging.

- 2026-11-14: M3 batch 3 (`7a0414b`): tree view (F5 toggle, Enter fold/unfold) — indented rows with tree characters (`└─`), hidden-descendant count on folded rows, collapse guarded to cursor pids with visible children. Four tests; gate green. Next: F3 search, tagging, signals, renice, I/O.

- 2026-11-14: M3 opened; batch 1 shipped (`79d52a4`): name filter (F4 live prompt, status shows the pattern), user filter (`u` cycles the sample's users, wrapping back to all) and a THR column; filter-aware key handling (typing goes to the prompt, Esc closes, Ctrl-C always quits). 11 TUI unit tests, gate green. Next: follow, tree view, search, tagging.

- 2026-11-14: m2-power collector shipped (`4ba8400`): `macos_power.rs` talks to AppleSMC (temps `Te*`/`TCMb`/`Tg01`/`Ta0P`, fans `F0Ac`/`F0Mx`, `PSTR`) and reads GPU watts from the IOReport `Energy Model` group with cumulative-counter deltas; the build script links the frameworks on macOS targets only (`CARGO_CFG_TARGET_OS`); Linux keeps GPU/system power unavailable. A live two-sample peek caught the SMC path returning nothing while 77 tests passed — the keyinfo response does not echo the key back, so the follow-up read asked for key 0 and got "not found"; the fix carries the key code in a local (probe21 first proved the identical C sequence works, isolating the bug to the Rust port). The live-host test now demands real sensors whenever IOKit reports an SMC device. Full gate plus both Linux cross-target clippies green. Next: the recorded powermetrics-style comparison, parity, close M2.

- 2026-11-14: m2-power probing done (decision 0011): per-core CPU state residency decodes from IOReport (idle = `ELDI`, mach ticks, interval deltas); GPU watts are real from the `GPU Energy` channel (8.7 W under a Metal burner); SMC temps, fan RPM and `PSTR` system watts read unprivileged through the AppleSMC user client; CPU energy and CPU MHz have no unprivileged source and are marked unavailable. CI green through `7dd4d1f`. Next: the Rust collector and the recorded powermetrics-style comparison.

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
