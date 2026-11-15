# 0024 — Help screen (F1) and man page

## Context

The parity item asks for a help screen and a man page. Every other key
is discoverable only through the function bar, which shows a subset.

## Decision

- **F1** opens a centered help overlay listing every binding, modeled on
  `draw_menu` (same centered-rect and `Clear` pattern). It is matched in
  `handle_key` beside Ctrl-C/Ctrl-L, so it opens from anywhere — setup,
  prompts, the signal menu. While it is open, every other key only closes
  it: nothing underneath (quit, tags, prompts) reacts. F1 itself toggles.
- The overlay's text lives in `help_lines()` next to `handle_key`, and a
  test renders the overlay, so the list cannot silently drift from the
  real bindings. It is plain text: no colors, identical in both themes.
- The man page is `docs/ztop.1`, plain roff with no preprocessor
  requirements (a first version used a `.TS` table, which renders blank
  unless `groff` is run with `tbl`; `.TP` entries work everywhere). It
  mirrors the CLI options, the subcommands and the same key list.

## Consequences

- Test: `f1_opens_help_and_any_key_closes_it` (opens, renders, any key
  closes without acting underneath, Esc closes instead of quitting, opens
  over setup, F1 toggles).
- The replays never press F1, so recorded snapshots are unchanged.
- The man page is verified with `groff -man -Tascii` locally; CI does not
  install groff, so the render check stays a local/recorded check.
