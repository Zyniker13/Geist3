# 0021 — Pause (Z) and forced redraw (Ctrl-L)

## Context

The parity item asks for pause updates (Z) and redraw (Ctrl-L), as top
and htop offer them.

## Decision

- `Z` (uppercase; lowercase keys are table and screen keys, decision 0012)
  toggles `Ui.paused`. While paused the event loop stops calling the
  collector — the picture is frozen — but everything else keeps working:
  scrolling, sorting, filtering, screens, setup, signals. The status line
  leads with a `paused` part while it lasts.
- The pause is global: it works on the extra screens too, where the table
  keys do nothing, because freezing the picture is not a table concern.
- While paused no new sample arrives, so `seen` (decision 0020) is not
  updated either — nothing can flash as "new" while frozen. When sampling
  resumes, the first sample computes its rates against the last sample
  before the pause, so one distorted rate row can appear after a long
  pause; that matches the delta-based behavior of htop and is accepted.
- Ctrl-L sets `Ui.redraw_requested`; the event loop then clears the
  terminal so the next frame repaints everything. It is handled first in
  the key match, so it works while a prompt, menu or setup screen is
  open — a repaint is never out of place.

## Consequences

- Tests: `z_toggles_pause_and_the_status_line_says_so` (toggle, status
  line, global scope) and `ctrl_l_requests_a_redraw_and_plain_l_does_not`
  (the flag; a plain `l` stays inert). The event-loop wiring itself is
  three lines around the existing loop and is covered by the integration
  path only.
- The idle redraw while paused costs nothing: ratatui diffs frames and
  writes nothing when nothing changed.
