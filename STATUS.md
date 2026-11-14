# Status

Updated after every working session.

- **Current milestone:** M1 (Linux collectors and basic TUI).
- **Last done:** M0 closed: workspace and Swift skeleton build, `ztop capture` records a fixture, check.sh green locally and CI green on both platforms (`7aca615`).
- **Next step:** M1: Linux collectors (CPU per core, memory, swap, load, uptime, processes and threads, disks, network, temperatures, fans, battery) tested against fixtures from two machines, plus the first TUI (header meters, sortable process table) rendering at 80x24 and large.
- **Blocked on:** nothing.

## Log

Newest first. One or two lines per session: what changed, what is next.

- M0 closed: CI green on both platforms after fixing a Linux-only compile error and a wrong expected string in a Linux-only test (found through the new CI annotations check.sh emits on failure). Next: M1.
- M0 built: stack decisions 0002–0006, the workspace skeleton (core, tui, agent, hub, ztop), architecture/threat-model/security/contributing docs, ZTopKit and the app skeleton, the fixture format and `ztop capture`.
- Project defined (DESIGN.md, ROADMAP.md, docs/parity.md, AGENTS.md; MIT OR Apache-2.0). Next: M0.
