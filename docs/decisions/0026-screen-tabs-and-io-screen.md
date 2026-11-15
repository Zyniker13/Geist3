# 0026 — Screen tabs and the per-process I/O screen

## Context

docs/parity.md requires "screen tabs, including a dedicated I/O screen".
The screens (process table, Apple Silicon, disks, network, thermal) were
reachable only through the `a`/`d`/`n`/`t` keys and the function-bar
hints, with no visible indication of where you are; per-process disk I/O
existed in the model (Linux `/proc/<pid>/io`, rates and totals) but had
no screen of its own.

## Decision

- Every screen except the process table and setup renders a one-row tab
  strip above its panel: `main  silicon  disks  net  io  temps`, the
  active screen bracketed (`[disks]`). Clicking a label switches screens;
  clicking the active tab returns to the process table, matching the
  keys' toggle behavior. Setup stays a modal screen with no tab. The
  process table keeps the function bar as its navigator — adding a strip
  there would shift every recorded snapshot for little gain.
- A dedicated I/O screen (key `o`, hint `o: io`, tab `io`) lists the
  processes that carry per-process I/O — pid, user, read/s, write/s,
  read, write, name — busiest first (sum of the two rates). On macOS and
  in replays the sample carries no per-process I/O, so the panel shows
  the standard "No per-process I/O data" empty state instead of an empty
  table.
- The F1 help row and the man page list `o` with the other screen keys.

## Consequences

- The main screen's rendering is untouched: the replay snapshots stay
  byte-identical, verified for all three architectures.
- Sub-screen panels lose their first row to the strip; their content is
  unchanged and their tests still pass.
- The tab strip's click map (`tab_at`) mirrors the strip's text widths
  the same way the function bar's click map does.
- htop has no direct equivalent for the strip; this is ztop's own
  navigation layer built over the parity-required screens.
