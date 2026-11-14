# Status

Updated after every working session.

- **Current milestone:** M1 (Linux collectors and basic TUI).
- **Last done:** m1-collectors: Linux parsers for CPU per core, memory and swap, load, uptime, per-process stat/status, disks, network, hwmon temperatures/fans and battery, in a pure text module; the same parsers feed `sample_from_fixture`, so per-field tests against the two recorded fixtures run on any OS (`58cb5d1`).
- **Next step:** m1-tui: first TUI (header meters, sortable process table) rendering at 80x24 and large, with snapshots.
- **Blocked on:** nothing.

## Log

Newest first. One or two lines per session: what changed, what is next.

- m1-collectors done: parsers live in a pure text module so the identical code runs on every machine; fixture integration tests pin every parsed field against both recorded captures (hostnames, 4 cores, 12 processes, disk/net counters); synthetic unit tests cover sensors (absent from the recorded hosts); the cross-target clippy gate caught three compile bugs in the Linux-only live collector before push. Next: the first TUI.
- m1-fixtures done: the job-summary transfer failed (summaries are absent from the check-run API and the job HTML), so the record workflow now scrubs and commits fixtures directly (`scripts/scrub-fixture.py`); two rounds of scrub bugs (per-pid `stat` fell outside the trim, then its gate) were caught by auditing the committed bytes; fixtures from both runners are 60 entries, all process names faked, fixed files verbatim. Next: Linux collectors against these fixtures.
- M0 closed: CI green on both platforms after fixing a Linux-only compile error and a wrong expected string in a Linux-only test (found through the new CI annotations check.sh emits on failure). Next: M1.
- M0 built: stack decisions 0002–0006, the workspace skeleton (core, tui, agent, hub, ztop), architecture/threat-model/security/contributing docs, ZTopKit and the app skeleton, the fixture format and `ztop capture`.
- Project defined (DESIGN.md, ROADMAP.md, docs/parity.md, AGENTS.md; MIT OR Apache-2.0). Next: M0.
