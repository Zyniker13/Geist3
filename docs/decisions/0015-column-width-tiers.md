# 0015 — Optional table columns tier by terminal width

## Context

M3 batches 7j and 7k add columns htop shows but an 80-column terminal cannot
hold: START (11), the last processor (3), VIRT (8), SHR (7) and PPID (7), plus
their separator cells — 47 columns of extras. Squeezing them all into the base
layout would leave NAME without room at the width every recorded fixture and
snapshot uses, and the I/O rate columns already appear conditionally. The
columns must also not shift between the header, the row cells and the click
map, which earlier batches kept in sync by hand (and 7h got wrong once).

## Decision

A single `Columns` plan is computed per draw from the terminal width and the
I/O visibility; the header labels, the column widths and the click map all read
that one plan, and each row emits a cell per planned column name. Columns tier
by width: the base set (PID, USER, STATE, CPU%, MEM%, THR, RES, NICE, TIME+,
NAME) at any width; START and CPU (last processor) from 100 columns; VIRT and
SHR from 120; PPID from 140. I/O rates join just before NAME whenever a visible
process moves data, as before.

## Consequences

- The 80-column layout and all recorded replay snapshots are unchanged by
  construction, so fixture snapshots do not need regeneration for these batches.
- At 120 columns with I/O rates showing, NAME gets about 18 cells; at 100 with
  I/O, about 13. Both stay readable; wider terminals keep more room.
- A click cannot land on a column the header does not show, because the click
  map derives from the same plan the draw used.
- macOS leaves SHR blank (no per-process shared-memory source; see decision
  0009's honesty rule) and PPID/START/CPU render blank where the collector has
  no value.

Licensed under either of MIT or Apache-2.0.
