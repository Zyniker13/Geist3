# 0020 — Highlighting new, dying processes and large numbers

## Context

htop highlights processes that appeared since the last frame, highlights
exited (zombie) processes, and colors large numbers in the CPU% and MEM%
columns. The parity item asks for the same here, in a way that survives
replays and the mono theme.

## Decision

- `Ui.seen` remembers the previous sample's pids. The event loop fills it
  every time a new sample is stored, so the next sample can tell which
  processes just arrived.
- A process whose pid is not in `seen` highlights as **new** (yellow row in
  the color theme); a process in state `Z` highlights as **dying** (red
  row). The first sample after startup highlights nothing — every process
  would look new, so the rule only applies once there is a previous
  generation. Replays of a single fixture sample likewise highlight
  nothing.
- The state letter is the dying signal: a gone process cannot be rendered,
  but a zombie is one that exited and still sits in the table waiting to
  be reaped, so "Z" is the visible part of "dying".
- Large numbers color their own cell in the color theme: CPU% >= 100 (one
  full core), MEM% >= 50, RES >= 1 GiB (red, red, yellow). Mono stays
  plain: no characters change, so recorded snapshots are identical in
  both themes.
- The cursor row keeps its reversed style; it overrides the highlight.

## Consequences

- Tests assert foreground colors through the test backend's buffer, a new
  `row_colors` helper: new pid yellow, zombie red, large numbers red/red/
  yellow, and plain text everywhere in mono.
- Highlighting is a color-theme feature only. A colorblind user still
  sees the underlying text unchanged; no state letter or marker is added.
- `seen` is one set of u32 pids per sample tick — no growth, no timers, no
  decay period (htop keeps its highlight for a fixed delay; here the
  highlight lasts exactly one sample, which is enough to catch the eye at
  the default one-second cadence).
