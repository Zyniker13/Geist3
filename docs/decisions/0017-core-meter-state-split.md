# 0017 — Per-core CPU meters split by state

## Context

The header already draws one meter per core (an `Avg` gauge first), but the
bars show only the total busy percent, so there is no way to see whether a
busy core is spending its time in user code, the kernel, or i/o wait. The
model has carried per-core `CpuTimes` since M2, but only the collectors see
the previous sample needed to turn cumulative counters into rates; the TUI
has only the derived `busy_percent`.

## Decision

- `Cpu` gains `state_percent: Vec<CpuTimes>` (`#[serde(default)]`): for each
  core, each state's delta over the sample interval as a percent of that
  interval, so the states plus idle sum to about 100. The fields hold
  percentages here, not seconds — documented on the field.
- A shared `core_state_percents(current, previous, interval)` in `model.rs`
  mirrors `core_percents`: index pairing, all-zero shares for a missing
  previous reading, a non-positive interval, or a total that did not
  advance, and per-state clamping to 0..=100 so counter resets cannot go
  negative. Both the Linux and macOS live collectors call it where they
  already call `core_percents`; fixture replays and captures recorded
  before the field fill zeros.
- The TUI draws each core meter as text bands cut from cumulative shares:
  user `█`, nice `▓`, system `▒`, io-wait `░`, and the remaining states
  (irq, soft-irq, steal, guest) together as `·`. Cutting from cumulative
  sums keeps the bands within the busy fill and drops the narrow, rare
  bands first on small cells. All-zero shares (an older capture) fall back
  to one plain user band, so old renders keep their shape.
- The color theme styles the bands (user green, nice yellow, system red,
  io-wait cyan, rare states magenta); mono keeps the characters alone, so
  the split stays legible with `--no-color`. The meter label stays
  `{core} {percent}%`, drawn before the bands.

## Consequences

- A single `CpuTimes` type serves two units (seconds in `cores`, percent in
  `state_percent`); the field documentation carries the distinction.
- The 80-column replay snapshots change (labels anchor left instead of a
  gauge's centered label) and are regenerated with the batch.
- Samples remain compatible both ways: old captures deserialize with an
  empty `state_percent` (the plain-fill fallback covers them), and old
  readers ignore the new field.
