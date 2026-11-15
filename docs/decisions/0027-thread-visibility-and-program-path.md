# 0027 — Thread visibility and the program-path toggle

## Context

docs/parity.md requires "Show or hide userland and kernel threads
(H, K), and program path (p)". htop binds H (show userland threads) and
K (hide kernel threads); ztop's `K` has opened the signal menu since the
menu existed, so the two htop toggles had to share a binding.

## Decision

- The Linux collector reads `/proc/<pid>/task/<tid>` (stat, status, comm)
  for every process and emits one extra row per task, keyed by tid. A
  task's `PPid` is the process's own parent rather than the group, so
  the thread group's pid travels with the entry and the row's `parent`
  is the group; tree mode nests threads under their process.
- `Process` gains two serde-default flags: `is_thread` (a task row) and
  `kernel_thread`. The kernel-thread rule is the one the `kthr` header
  metric already counts — parent 0 or 2 — so the flag and the metric
  agree; thread rows are never kernel rows. The fixture entry names grow
  a task form, `proc-<group>-task-<tid>-stat|status|comm`, and the
  fixture kernel-thread count skips thread entries.
- The TUI's `H` cycles visibility over three states: kernel threads
  shown and userland threads hidden (the default, matching the `kthr`
  metric), then userland threads shown too, then kernel threads hidden
  as well, then back. `K` stays with the signal menu; the cycle covers
  both htop toggles on one key.
- `p` toggles the program path in the name column. ztop shows the
  recorded command whenever the OS reports one (decision 0016, macOS
  `proc_pidpath`; Linux `/proc/<pid>/cmdline`), so the toggle turns the
  path off; htop's default is the other way around and ztop keeps its
  own, more informative default.

## Consequences

- The default rendering is unchanged: userland threads were never in the
  table before, and the recorded fixtures carry no task entries, so all
  three replay snapshots stay byte-identical.
- The recorded fixtures predate the feature: thread rows are proven by
  unit tests (`process_row_marks_thread_entries`,
  `pid_entry_names_split_into_pid_and_kind`) and TUI tests
  (`the_threads_cycle_shows_and_hides_rows`, `p_toggles_the_program_path`),
  not by fixture files. The live task walk itself is Linux-live-only,
  like the rest of the `/proc` walk.
- The fixture whitelist for per-pid entries still omits `statm`, so
  fixture-replay rows carry no shared bytes; a recording of a real host
  would replay with `-` there. Left as-is: allowing `statm` through would
  change the replay snapshots, which deserve their own batch.
- Kernel threads are identified by parent, not by an empty cmdline: the
  scrubber replaces recorded cmdlines with fake non-empty values, so a
  cmdline-based rule is not fixture-expressible. A parent of 0 also
  counts pid 1 as a kernel thread, which matches the shipped `kthr`
  metric and keeps the two consistent.
