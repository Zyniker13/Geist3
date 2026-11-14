# 0012 — `K`, not `k`, opens the signal menu

## Context

htop opens the signal (kill) menu with F9 and with `k`. Our M3 batch 2 gave `k` a
different job first: it moves the cursor up, alongside `j` down, because the process
table is the screen users touch most and vim-style motion keys are already muscle
memory there. The parity item "Open the signal menu with `k` as well" asks for the
htop binding literally.

## Decision

Capital `K` opens the signal menu, next to F9. Lower-case `k` stays cursor-up.

## Consequences

- The parity item is met in substance (a key opens the signal menu besides F9) with
  one deliberate divergence, listed here rather than hidden.
- `k`/`K` join the set of case-paired actions (`u`/`U` user filter cycle). The setup
  screen (M3 batch 7c) will document both.
- htop also binds `K` to showing or hiding kernel threads. That toggle moves to the
  setup screen's display options when that item lands (htop's own setup hides kernel
  threads there too); `H` stays userland threads and `p` stays program path.
- No conflict: F9 and `K` both call `Ui::open_menu`, which is covered by the batch-5
  menu tests; the binding itself is a one-line event-loop arm.

Licensed under either of MIT or Apache-2.0.
