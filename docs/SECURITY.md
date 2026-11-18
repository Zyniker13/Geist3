# SECURITY

Purpose: security posture of the build — redaction-test results (0 leaks across ≥ 2,000 simulated games per game), the hidden-information boundary (no full `GameState` leaves the host), the secrets policy (none in the repository), and network attack-surface notes from P8 onward.

## Redaction Tests

| Gate | Games | Simulated games | Checks | Leaks | Commit |
| --- | --- | --- | --- | --- | --- |
| G1 | toy game | 2,000 | byte-scan of encoded observation for every hidden face ID | **0** | `01f5d5c`+ |
