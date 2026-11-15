# 0014 — Shared bytes assume the 4 KiB page

## Context

M3 batch 7h reads per-process shared memory from the third field of Linux
`/proc/<pid>/statm` (shared pages). Turning pages into bytes needs a page size.
Every recorded Linux fixture and every GitHub CI runner this project builds on
uses 4 KiB pages, and the collector reads no kernel interface that reports the
running page size.

## Decision

`parse_pid_statm` multiplies the shared-page count by 4096 unconditionally. The
constant is documented at the function, and the assumption is recorded here
rather than hidden.

## Consequences

- On kernels with a larger page size the reported shared footprint is smaller
  than reality by the page-size ratio; no other column or sort is affected.
- If a deployment on such kernels ever matters, the collector can read
  `sysconf(_SC_PAGESIZE)` then; until there is a user, the extra call is not
  worth the plumbing.

Licensed under either of MIT or Apache-2.0.
