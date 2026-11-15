# 0030 — Syscall trace (`s`)

## Context

`docs/parity.md`'s detail line kept one unchecked item after batch 7z:
the syscall trace (`s`), htop's strace equivalent. Decision 0029 split
it out of the e/l/s line because an active attach is a different class
of read than the passive environment and open-files reads, and macOS has
no user-space equivalent without special entitlements. This batch ships
it as the last remaining detail-line item.

## Decision

**Core (`crates/core/src/trace.rs`).** Linux only, everywhere else the
call refuses with "syscall tracing is not available on this platform"
(macOS's user-space ptrace tracing needs special entitlements; pretending
otherwise would be dishonest). The tracer:

- attaches with `PTRACE_SEIZE` (non-stopping attach);
- runs on its own thread named `ztop-trace-<pid>`, waiting on the
  tracee's pid specifically — never `waitpid(-1)`, so it can never reap
  another part of the process tree (a hard rule once the test harness
  also has children);
- reads one `PTRACE_GET_SYSCALL_INFO` record per stop, so no
  per-architecture register layouts are needed; the record's byte
  offsets are identical on every 64-bit target;
- records one line per completed (exit) syscall: `name = -errno` on
  error, `name = 0x…` on success;
- names syscalls from curated per-architecture tables (x86_64 and the
  generic aarch64 table) covering the hot path; anything else reports
  `syscall N` rather than a guessed name — a wrong name is worse than
  a number;
- keeps the newest 512 lines in a shared ring the TUI drains;
- passes real signals through: a stop that is not a syscall stop is a
  signal-delivery-stop, and resuming it with 0 would swallow the
  signal — `SIGTRAP`/`SIGSTOP` are the tracer/stop machinery's own and
  resume with 0, everything else resumes unchanged. A group-stopped
  tracee continues under the tracer, which is a documented consequence
  of attaching;
- stops and detaches on drop (`PTRACE_INTERRUPT` to wake the waiter,
  then `PTRACE_DETACH`); every failure is an `Err` with the OS error
  text.

**TUI.** `s` opens the trace of the first tagged row (else the cursor's
row) like `e`/`l` do; a failed start reports on the status line and
leaves the overlay closed. The overlay mirrors the detail popup: bordered,
centered, title `trace of NAME (pid N) — Esc closes`, `(no syscalls
yet)` when empty, j/k scroll with a `… lines x–y of n` hint. Scrolling
is tail-following: `back` counts lines from the newest, 0 follows the
tail, scrolling back to the newest resumes following, and while scrolled
back new lines do not move the window. The overlay caps at 10,000 lines.
Closing (Esc or q) drops the tracer, stopping its thread and detaching.
The event loop wakes in 150 ms slices while a trace is open so lines
reach the screen promptly; samples still land on their normal cadence
(the non-trace loop path is untouched). Tracing is observation, so
read-only mode allows it; the mouse is inert while the overlay is open.

**Tests.** Core: a child is traced and a nanosleep line appears, a gone
pid refuses, the name tables spot-check both architectures plus the
numeric fallback (Linux-cfg'd — they run on CI Linux, which ptraces its
own children unprivileged). TUI: overlay render/scroll/Esc, empty
overlay, failed start (gone pid on Linux, any pid on macOS) stays
closed, a live child trace records lines and Esc stops it (Linux-cfg'd),
and the status hints replay the trace key. CI Linux runs the live
ptrace tests; macOS runs the refusal path.

## Amendment 2026-11-15 — the attach kick

CI's first run of the live test failed with an empty ring: after
`PTRACE_SEIZE`, a tracee that is already running produces no stops on
its own, so waiting alone never sees a syscall. The tracer now sends
one `PTRACE_INTERRUPT` at attach; the group-stop that answers it is
where `PTRACE_SYSCALL` stepping begins, and the syscall the tracee was
interrupted in is reported as exiting — the first recorded line. The
live test polls with a 3 s deadline instead of a fixed sleep, and a
failed trace-thread spawn now detaches the tracee instead of leaving
it attached and stopped.

## Consequences

- The detail line of `docs/parity.md` is now fully checked once this
  lands; the remaining open M3 items are setup screens and configurable
  meter columns.
- ztop's tracer is honest about what it can and cannot see: the OS's
  permission rules decide, the status line carries the OS's error text,
  and macOS users get a clear refusal instead of a silent no-op.
- The curated name tables can lag new syscalls; the numeric fallback
  keeps those rows truthful. Extending a table is a data-only change.
