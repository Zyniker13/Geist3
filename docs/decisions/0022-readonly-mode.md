# 0022 — Read-only mode (`--readonly`)

## Context

The parity item asks for a read-only mode. Some hosts are shared or
production machines where an accidental F9 must never reach a process.

## Decision

- `ztop --readonly` starts the TUI with `Ui.readonly` set. The flag is a
  per-run switch on the command line, not a saved setting: the config
  file holds display preferences, and safety must never be turned off
  quietly by a stale file.
- Refusals live at the two places actions enter the system:
  `open_menu` refuses to open the signal menu, and `run_plan` refuses
  every plan before `control::execute`. The double guard is deliberate —
  future action keys (I/O priority, affinity) that call `run_plan`
  directly are covered without new code, and the mouse path (which
  replays keys through the same handler) is covered too.
- A refusal shows the status-line notice "read-only: signals and renice
  are disabled" for one refresh, the same channel action results use.
  Everything else keeps working: sampling, sorting, filtering, screens,
  setup, pause.

## Consequences

- Test: `readonly_refuses_the_signal_menu_and_every_plan` (menu stays
  closed with the notice; F7's renice plan is refused before execution —
  the notice is exactly the refusal, not an execution report; without the
  flag the menu opens as usual).
- The notice names both verbs because the guard is shared; when more
  actions arrive (I/O priority, affinity) the text stays true.
