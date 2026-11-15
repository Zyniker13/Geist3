# 0032 — Configurable table columns

Date: 2026-11-15
Status: Accepted
Scope: crates/tui (config, setup screen, table plan), docs

## Context

The setup screen was the last open item in docs/parity.md's htop line:
the meters, display options and colors are editable (decisions 0025,
0031) but the process table's optional columns were fixed by the width
tiering (decision 0015) — START and the last processor from 100
columns, VIRT and SHR from 120, PPID from 140, PRI and COMMAND from
160. htop's setup lets the user choose columns outright. The mandatory
columns (PID, USER, STATE, CPU%, MEM%, THR, RES, NICE, TIME+, NAME)
are not choices — the table cannot lose them and stay a process table
— and the per-process I/O rate columns follow the sample data, not a
preference: they appear only while a visible process moves data
(decision 0019), which is what keeps the 80-column table and the
recorded fixture renders stable.

## Decision

- `Config` gains `columns: Vec<ColumnChoice>` (serde default: empty).
  A `ColumnChoice` pairs a `ColumnKind` — start, processor, virtual,
  shared, parent, priority, command, the seven optional columns — with
  a `ColumnState`: auto (the kind absent from the list), shown, or
  hidden. Old configs load unchanged and an empty list is exactly the
  old behavior.
- The setup screen gains a third pane, `Columns`, opened from the main
  pane's "Table columns …" row. One row per optional column; Enter
  cycles auto → shown → hidden → auto; Esc returns to the main pane,
  and Esc/F2 on the main pane saves and closes as before.
- `Columns::plan` takes the choices: a forced-shown column appears at
  any width, a forced-hidden one disappears at any width, and a column
  left alone keeps its width tier. Column ORDER stays the tier ladder —
  a choice says whether a column shows, never where it sits.
- The I/O rate columns stay data-driven and are not in the editor; the
  mandatory columns are not in the editor either.

## Consequences

- The recorded fixture renders stay byte-identical: the default config
  has no column choices, so every column keeps its tier.
- A forced-shown column on a narrow terminal costs NAME width; NAME
  keeps Min(1) so it never vanishes, and COMMAND stays last with its
  fixed 32-column width.
- The setup screen now has three panes; the main pane has eight rows
  and its last one opens the column editor. Tests:
  `the_setup_screen_shows_the_columns_pane`,
  `the_column_editor_cycles_auto_shown_hidden`,
  `forced_columns_override_the_width_tiers`.
- With this, the htop setup-screen line in docs/parity.md is fully
  checked; M3's remaining open items are whatever parity still lists.
