# 0016 — The command line per platform

## Context

M3 parity calls for a COMMAND column where the full command line differs
from the truncated `comm` the kernel reports. The two platforms expose
it very differently:

- Linux records `/proc/<pid>/cmdline` for every process: the NUL-separated
  argv, readable by anyone who owns the process. The capture already wrote
  these files; the parser discarded them.
- macOS grants argv (`proc_pidargs`) only to the process owner with
  entitlements; an unprivileged monitor cannot read it. What any process
  can read is the executable path, via libproc's `proc_pidpath`.

## Decision

`Process.command` is `Option<String>`:

- Linux: the joined argv from `cmdline` (`parse_pid_cmdline`), with an
  empty file meaning *no* command line — kernel threads — not an empty
  one.
- macOS: the executable path from `proc_pidpath`, joined to the recorded
  `processes` text as a second quoted field (names and paths are scrubbed
  of quotes and backslashes by the capture, so each quoted tail stays one
  field, and the fixture scrubber replaces real paths with `/fake/path`).
  An unreadable or empty path leaves the command unavailable.
- The TUI NAME column shows the command when present and the short `comm`
  name otherwise; the name never disappears behind an unreadable command.

## Consequences

One column serves both platforms honestly: Linux shows the real argv,
macOS the real executable path, and both fall back to `comm`. The mac
NAME cell is therefore often wider than `comm` (paths are long); the
column keeps the base width and truncates, which decision 0015 already
handles. Real argv on macOS would need an entitlement — out of scope for
an unprivileged tool.
