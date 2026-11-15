# 0019 — Pressure stall information as one header meter line

## Context

Linux exposes pressure stall information (PSI) per resource in
`/proc/pressure/{cpu,memory,io}`: the share of recent wall time during
which at least one task (`some`) or every non-idle task (`full`) stalled
waiting for the resource, averaged over 10 s, 1 min and 5 min. The cpu
file has no `full` line. PSI may be compiled out or disabled at boot, in
which case the files do not exist.

## Decision

- The model gains `Pressure { cpu, memory, io }` of `Psi { some, full }`
  with the three averages each, carried on `Sample.pressure` as
  `Option` (`#[serde(default)]`, so old captures still load).
- The Linux live collector reads all three files; if any is missing or
  unparseable the whole reading is `None` — one resource's numbers
  without the others is a half picture worth hiding. Capture records
  the three files when they exist (`proc-pressure-*` entries), and the
  fixture reader parses them the same way, so a re-captured fixture
  replays the line too. PSI-less fixtures keep replaying without it.
- The header shows one `psi` line in the same slot discipline as the
  I/O line (decision 0018): present only when the sample carries
  pressure, accounted by `header_height`, and reporting the 10-second
  averages — `psi  cpu s 12.3%  ·  mem s 0.1% f 0.0%  ·  io s 2.3% f 1.1%`
  (`s` some, `f` full; cpu has no `f` because the kernel has none).
  macOS and pressure-disabled kernels simply never show it.
- The parser is strict: unknown fields or unknown kind lines reject the
  whole file, so a kernel format change surfaces as "no pressure"
  instead of silently wrong numbers.

## Consequences

- A live Linux host with PSI gains one header row (the table loses one
  row at the same terminal size), same trade as the I/O line.
- Fixture replays stay byte-identical for the committed fixtures; a
  future re-capture on a PSI-enabled host will show the line in the
  replay snapshot, which is then the recorded check for this item.
