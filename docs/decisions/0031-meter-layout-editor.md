# 0031 — The meter-layout editor and display options

Date: 2026-11-15
Batch: 7ab
Status: Accepted

## Context

`docs/parity.md` line "Configurable columns of meters (htop's
meter-layout editor)" was the last big F2 gap: the setup screen could
toggle the theme and tree view, but the header's memory/swap row, the
I/O line, the pressure line and the sensors line were all fixed. htop
lets the user pick which meters appear, on which side, and in which
order; the roadmap asks for the same.

Constraints the old rendering imposed:

- The memory/swap row was hardcoded (`draw_memory_row`) and always the
  first header row after the CPU bar.
- The I/O, pressure and sensors lines were whole-width automatic lines
  gated only by their sample data.
- The config file already carried `theme` and `start_in_tree` and
  round-trips through JSON; unknown fields are tolerated, so adding
  fields is safe for old configs.

## Decision

1. **Config shape.** `Config` gains `meter_style` (replacing the old
   boolean bar style), `meters: Vec<MeterChoice>` where
   `MeterChoice { kind: MeterKind, side: MeterSide }` with
   `MeterSide::{Left, Right}`, and three display toggles `show_io`,
   `show_psi`, `show_temps`. `MeterKind` covers memory, swap, load,
   battery, disk/network I/O, CPU pressure and temperatures/sensors;
   the per-core CPU bar always leads at full width and is not part of
   the list. `METER_KINDS` (the editor's menu) and serde renames keep
   the JSON stable and human-readable.

2. **Rendering.** The header lays the meters out in two columns: 60%
   left, 40% right, as many rows as the longer column needs. The
   default layout is exactly the old fixed row — memory left, swap
   right — so the default rendering stays byte-identical (checked
   against all three fixture snapshots).

3. **Replacing, never doubling.** Placing I/O, pressure or sensors as
   a meter replaces its automatic line (`meter_placed`); the automatic
   lines appear only when their toggle is on AND the meter is not
   placed. Removing the meter brings the line back. A meter and its
   line can therefore never show the same data twice.

4. **Graph meters.** Load (load average / core count) and battery
   (percent) render as graph-style meters like CPU, fed by new
   `Ui::load_history` / `Ui::battery_history` ring buffers (120
   samples, matching the existing history trim).

5. **Editor UX.** F2 opens the main pane (7 rows: theme, start in
   tree view, meter style, the three display toggles, "edit meter
   layout"). Enter on the last row opens the Meters pane, a list of
   every meter kind: Enter/space cycles off → left → right → off,
   `,`/`.` move a placed meter within its column, Esc returns to the
   main pane. Esc or F2 on the main pane saves the config and closes;
   the status line reports the saved path or the error.

6. **Hermetic tests.** `Config::save` writes the user's real config
   file, so tests never close setup that way: they call the
   `finish_setup(Ok(path))` seam or leave the screen directly. The
   config roundtrip test uses `save_to`/`load_from` on a test path.

## Consequences

- The old fixed memory/swap row (`draw_memory_row`) is gone; the
  default layout reproduces it.
- `header_height` = 4 fixed rows (title, CPU, info, status) + meter
  rows + the still-automatic I/O/pressure/sensors lines.
- A custom layout replaces the default wholesale: the config lists
  exactly the meters shown.
- Snapshot replays for all three architectures are byte-identical, so
  the change is invisible until the user edits the layout.
- Table columns (parity line "Setup screen (F2) for meters, display
  options, colors and columns") remain open and follow as their own
  batch.
