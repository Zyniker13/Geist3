# CONFORMANCE

Purpose: per-game rule-ID coverage (every numbered rule in `docs/rules/RULES-<game>.md` has at least one tagged test) and golden-replay results, per `docs/plan/CONVENTIONS.md` §6. Written by `make conformance`.

| Game | Rule IDs | Covered | Golden replays | Result | Commit |
| --- | --- | --- | --- | --- | --- |
| Hearts | 12 | 12 | 0 (pending P3.5) | pass | e58984f |
| Euchre | 14 | 14 | 0 (pending P3.5) | pass | e58984f |
| Bridge | 16 | 16 | 0 (pending P3.5) | pass | 8003645 |
| Cribbage | 12 | 12 | 0 (pending P3.5) | pass | 37b5040 |

Coverage counts rule ids in the suite sources (the tagged tests are the evidence; random-legal simulation cannot exercise structural rules). Golden replays (20 per game) land with P3.5; the column stays at 0 until the replay manifest exists.
