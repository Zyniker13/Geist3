# 0023 — Command-line options (`-d`, `-u`, `-s`, `-t`)

## Context

The parity item asks for the usual `top`/`htop` command-line options.
`-p` (pid list) already existed; `--no-color` and `--readonly` were added
with their features.

## Decision

- **`-d <seconds>`** — seconds between samples, parsed as `f64` (fractional
  delays allowed, like htop), clamped by a floor, `ztop_tui::MIN_DELAY`
  (0.1 s): below it the event loop would spin and eat the machine it
  watches. The value becomes the event loop's poll timeout, so keys are
  still handled instantly; only the sampling cadence changes. A smaller
  value is an error, not a silent clamp.
- **`-u <user>`** — sets the starting user filter directly. Unlike the `u`
  key it does not validate against the sample's users: a name with no
  processes shows an empty list, which is what "only alice" means.
- **`-s <key>`** — starting sort key, parsed by `SortKey::FromStr` from
  lowercase names that match the sort cycle (`pid user cpu mem res virt
  shr pri nice time start core ppid name command`). Unknown names are an
  error listing the valid choices, so a typo never silently sorts
  differently than expected. The key starts descending, like a click on
  its header.
- **`-t`** — starts in tree view by setting `Config.start_in_tree` in
  memory. Unlike `--no-color` (an override that is never saved), `-t`
  flows through the same field the setup screen manages: if the user then
  saves setup, the choice persists. That matches htop, where F5 tree view
  is remembered.
- The four flags travel as `ztop_tui::RunFlags` (readonly, user, sort,
  delay) applied by `apply_flags` before the first frame; per-run command
  shaping stays separate from saved `Config` preferences.

## Consequences

- Tests: `sort_key_names_parse` (all 15 names parse; unknown names error),
  `run_flags_shape_the_first_frame` (readonly/user/sort applied, a
  starting sort begins descending, no flags change nothing).
- The delay floor is enforced in main so `ztop_tui::run` keeps trusting
  its caller (library callers pass any delay they like).
