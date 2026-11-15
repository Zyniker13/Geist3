# 0025 — Meter styles

## Context

docs/parity.md requires meter styles like htop's: bar, text, graph and LED.
The header meters (average CPU, memory, swap, the per-core meters) rendered
only as solid bars. The parity item also mentions "configurable columns of
meters" — that is htop's meter-layout editor and is a separate, larger
feature; the item is split and only the styles land here.

## Decision

A `MeterStyle` enum in the saved config (`bar`, `text`, `graph`, `led`,
serde-renamed, defaulting to `bar`) picks how every header meter draws:

- **bar** — the existing rendering, byte for byte: the ratatui `Gauge` and
  the per-core per-state bands.
- **text** — the label only (`Avg 42%`, `8.2 / 16 GiB …`), no fill.
- **graph** — the label plus a history sparkline. `Ui` keeps ring buffers
  (average, per-core, memory, swap; 120 samples, pushed once per sample in
  `apply`) and the meter draws the newest samples first as eighth-block
  glyphs `▁▂▃▄▅▆▇█`. This is ztop's honest reading of "graph": a strip of
  recent samples, not htop's scrolled line chart.
- **led** — the label plus an LED strip: `|` where the value has reached,
  `·` behind it, sized to the meter's remaining width.

The style is set on the setup screen's third row and is saved with the rest
of the config. Non-bar styles lead with the same label the bar carries, so
no meter loses its number. Color follows the meter's accent in the color
theme and stays plain in mono. Non-bar paths return early before the bar
drawing, so the recorded snapshots (bar) cannot change by accident.

## Consequences

- `Config` gains a field; older config files load unchanged via
  `#[serde(default)]`.
- `Ui` grows four small history vectors — bounded, pushed per sample,
  negligible cost.
- The replay snapshots stay byte-identical (verified: bar is the default).
- "Configurable columns of meters" remains an open parity item and will be
  implemented (or honestly re-scoped) later, not silently dropped.
