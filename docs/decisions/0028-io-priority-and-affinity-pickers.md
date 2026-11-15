# 0028 — I/O priority and CPU affinity pickers

## Context

docs/parity.md requires "I/O priority (i, Linux) and CPU affinity
(a, Linux)". htop binds `i` to ionice and `a` to affinity, but ztop's
lowercase `i` flips the sort direction and `a` opens the Apple Silicon
screen (both shipped earlier), so the htop letters are taken.

## Decision

- The actions live in `Control`: `IoPriority(u32)` carries the value
  `ioprio_set` takes (`class << 13 | level`, classes none 0 / realtime
  1 / best-effort 2 / idle 3), and `Affinity(u64)` carries the
  `sched_setaffinity` mask, bit `i` = core `i`. Both syscalls are
  Linux-only; on any other platform `apply_one` returns an
  "is not available on this platform" error, which the status line
  reports like any failed action.
- The pickers reuse the signal menu's popup: `Ui` keeps `menu` (the
  selected row) and gains `menu_kind` (signals / io priority /
  affinity). `open_menu` (F9, K) is now `open_picker(Signals)`;
  `I` and `A` open the two new kinds. The row count, wrap-around,
  popup rendering and the Enter-applies / Esc-cancels flow are shared;
  the affinity picker's rows come from the last sample's core count
  (all cores first, then one row per core, capped at 64 by the `u64`
  mask).
- Key choice: uppercase `I` and `A`, following the uppercase-action
  convention (decision 0012) — the lowercase letters keep their
  existing meanings. The pickers accept the same target set rules as
  the signal menu: tagged rows, else the cursor; read-only mode
  refuses; with no target the picker stays closed.
- htop's dialogs differ (a class slider plus a level slider for
  ionice, a CPU matrix for affinity); the flat picker keeps one shared
  popup mechanism instead of three bespoke dialogs, at the cost of an
  18-row ionice list.

## Consequences

- The Linux CI job exercises both syscalls for real: the test writes
  the host's own affinity mask back (`sched_getaffinity` first) and
  sets best-effort 4 on its own pid, both permitted unprivileged.
  Realtime classes need root and are not exercised.
- The default rendering is unchanged: the pickers only appear when
  opened, and the status-line hint grew by two labels past the 80-column
  clip point, so the replay snapshots stay byte-identical.
- A mask is a coarse tool: a single-core pick pins a process hard, and
  cores past 63 cannot be addressed individually. The all-cores row
  restores the full mask, and the man page states the Linux-only scope.
