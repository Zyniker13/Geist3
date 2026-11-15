// SPDX-License-Identifier: MIT OR Apache-2.0
//! Decision 0029 — per-process detail reads: environment and open files
//! (batch 7z), with the ptrace trace deferred.

## Context

docs/parity.md's htop-parity list has one line covering three per-process
detail views: "Show the environment (`e`), open files (`l`) and a strace
trace (`s`) of the selected process, where the OS allows it". The three
readings differ hugely in plumbing: environment and open files are
passive reads the OS already tracks, while a trace is an active
ptrace-attach session with a sampling thread. Batching all three would
hold the first two hostage to the third.

## Decision

Batch 7z ships `e` and `l`; the trace (`s`) ships as its own batch.

- `crates/core/src/detail.rs` reads live, never from a sample:
  - environment: Linux `/proc/<pid>/environ` (NUL-separated); macOS the
    kernel's `KERN_PROCARGS2` sysctl block (argc, exec path, argv, env),
    parsed by the standard recipe; non-Linux-non-macOS falls through to
    the Linux path (CI's other targets keep `/proc`).
  - open files: Linux `/proc/<pid>/fd` readlink per entry, sorted by fd;
    macOS `proc_pidinfo(PROC_PIDLISTFDS)` plus `proc_pidfdinfo`
    (PROC_PIDFDVNODEINFO) per fd, the path taken from the record's last
    MAXPATHLEN bytes; non-vnode fds report their type number.
  - Every failure is an `Err` with the OS error text: gone pid,
    permission refused — reported in the TUI status line, never a panic.
- The TUI gets a `Detail` overlay (`DetailKind::{Environment, OpenFiles}`,
  `Ui.detail`): opened by `e`/`l` for the first tagged row, else the
  cursor's row; a bordered popup like the menu's (Clear + bordered
  Paragraph, bold title inside), width min(100, cols), height min(20,
  rows), j/k scroll with a "… lines x–y of n" hint, `(none)` for an empty
  read, Esc/q closes (q closes rather than quitting). The read is
  passive, so read-only mode allows it — refusals come from the OS, not
  ztop. Mouse is inert while the overlay is open.
- Keys `e`/`l` were free (lowercase table keys). Hints `e: env · l:
  files`, F1 row "e, l — environment, open files of the cursor/tags".
- The trace line stays unchecked until the ptrace tracer exists; its
  parity item is split in the tick (env/files checked, trace noted as
  following).

## Consequences

- Both reads work unprivileged for the user's own processes on Linux and
  macOS; core tests exercise the own-pid reads plus gone-pid errors on
  every platform, so CI proves them without fixtures.
- No new dependencies (libc already a core dependency; libproc comes
  with libSystem on macOS).
- The `s` trace is the last large item before setup screens and meter
  columns; it will need its own decision for the ptrace design
  (Linux-only, macOS reports unavailable).
