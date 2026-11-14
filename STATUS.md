# Status

Updated after every working session.

- **Current milestone:** M1 (Linux collectors and basic TUI).
- **Last done:** m1-fixtures: real fixtures from two Linux CI runners (x86_64 + aarch64, 60 entries each) recorded, scrubbed (`scripts/scrub-fixture.py`) and committed; decision 0007 amended after the job-summary transfer failed (`6a2956a`, `efe2314`).
- **Next step:** M1: Linux collectors (CPU per core, memory, swap, load, uptime, processes and threads, disks, network, temperatures, fans, battery) tested against the two fixtures, plus the first TUI (header meters, sortable process table) rendering at 80x24 and large.
- **Blocked on:** nothing.

## Log

Newest first. One or two lines per session: what changed, what is next.

- m1-fixtures done: the job-summary transfer failed (summaries are absent from the check-run API and the job HTML), so the record workflow now scrubs and commits fixtures directly (`scripts/scrub-fixture.py`); two rounds of scrub bugs (per-pid `stat` fell outside the trim, then its gate) were caught by auditing the committed bytes; fixtures from both runners are 60 entries, all process names faked, fixed files verbatim. Next: Linux collectors against these fixtures.
- M0 closed: CI green on both platforms after fixing a Linux-only compile error and a wrong expected string in a Linux-only test (found through the new CI annotations check.sh emits on failure). Next: M1.
- M0 built: stack decisions 0002–0006, the workspace skeleton (core, tui, agent, hub, ztop), architecture/threat-model/security/contributing docs, ZTopKit and the app skeleton, the fixture format and `ztop capture`.
- Project defined (DESIGN.md, ROADMAP.md, docs/parity.md, AGENTS.md; MIT OR Apache-2.0). Next: M0.
