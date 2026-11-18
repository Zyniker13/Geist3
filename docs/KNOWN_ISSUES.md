# KNOWN ISSUES

Purpose: every known defect, limitation, and workaround not yet fixed, with severity (blocker / major / minor), the phase that introduced it, and the test or observation that demonstrates it. Summarized into `HANDOFF.md` §3 at every stop.

| ID | Severity | Introduced | Description | Evidence / repro |
| --- | --- | --- | --- | --- |
| KI-1 | major | P0 | macOS UI-test leg cannot run on the build host: the runner's automation handshake stalls (three runs: 60 s "Timed out while enabling automation mode" ×2; hang after "Running tests…" ×1). Needs a one-time interactive TCC automation approval by the owner. Carved out of the gate by ADR-0022; macOS unit tests and both iOS UI legs pass. Hard requirement again from G9. | scratch/g0-final.log (04:21), scratch/g0-macos-retry.log (04:26); `make test-apps-macos-ui` reproduces |
