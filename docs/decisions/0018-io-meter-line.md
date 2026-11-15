# 0018 — Disk and network I/O as one header meter line

## Context

The model already carries per-disk and per-interface rates (Linux live
collector: `counter_rate` over the `/proc/diskstats` and `/proc/net/dev`
byte counters), but the header shows none of it. htop shows disk and
network I/O as meters. The disk and network screens show per-device
detail; what is missing is the at-a-glance header meter.

## Decision

- One text line between the memory meters and the info line, rendered
  only when at least one disk or interface has a measured rate:
  `io  sda r 1.2 MiB/s w 512 KiB/s  ·  eth0 r 5.0 MiB/s t 120 KiB/s`.
  Entries join with `·`; a device whose rate is `None` (fixture replay,
  a collector's first sample) is skipped, and the whole line disappears
  when nothing has a rate — the header then keeps its previous height,
  so 80-column replays are unchanged.
- The header's row count lives in one `header_height` helper used by the
  layout splitter and the mouse handler alike; adding a conditional row
  cannot desynchronize the table area or hint-bar click row from the
  drawn header. (A `Constraint::Length(0)` placeholder row turned out to
  render a blank line instead of no line, so absent rows are omitted
  from the constraint list instead.)
- Rates format like the memory labels plus `/s` (`1.2 MiB/s`, `512 KiB/s`,
  `0 B/s`), a readable complement to the table's compact `3.5Mi` columns.
- macOS records no disks or interfaces yet (IOKit is future work); the
  line simply never appears there until its collector fills them.

## Consequences

- The header grows by one row on a live Linux host — one process-table
  row less at the same terminal size; acceptable for the information.
- Fixture replays stay byte-identical, so the feature is proven by unit
  tests with constructed samples, not by snapshots.
