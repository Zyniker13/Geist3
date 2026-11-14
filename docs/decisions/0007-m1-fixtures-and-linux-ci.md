# 0007 — M1 fixture sourcing and Linux CI layout

Date: 2026-11-13. Status: accepted. Supersedes: none.

## Context

M1 requires Linux collectors tested against fixtures "from at least two
different machines", and `ztop` running "on a real Linux host in a recorded
smoke test". Development happens on macOS; no local Linux environment
exists (no container runtime or VM manager is installed), so both the
fixtures and the real-host evidence must come from CI runners, whose logs
are not readable without admin credentials.

## Decision

- **Linux collectors are pure text parsers.** Every collector function
  takes recorded text (a `/proc` or `/sys` file's contents) and returns a
  value; a thin source layer reads live files and feeds the same parsers.
  Parser tests therefore run on every machine — including the macOS gate —
  because they consume committed fixture bytes, never the live OS. The
  live source path is exercised on Linux CI only.
- **Two Linux CI jobs on two genuinely different machines:** the existing
  `ubuntu-latest` (x86_64) job and a new `ubuntu-24.04-arm` job (free for
  public repositories). Each job builds the workspace, records a fresh
  fixture with `ztop capture --out`, and runs a self-test that parses the
  just-recorded fixture and asserts every collected field is sane. A green
  run is the real-Linux-host smoke evidence; the run URL is recorded in
  `docs/parity.md` when items are checked.
- **Committed fixtures come from real captures.** The capture output is
  carried out of the runner through the job summary (`$GITHUB_STEP_SUMMARY`
  holds the fixture, base64-chunked; the summary page of a public
  repository is readable without credentials), reconstructed locally,
  privacy-scrubbed, and committed under `tests/fixtures/`. If the summary
  path proves unusable, the fallback is chunked `::notice::` annotations;
  the last resort is a `workflow_dispatch` job that commits the fixture
  with the built-in token. Hand-written /proc text is not acceptable as a
  machine fixture.
- **Scrub policy for process data.** A committed fixture keeps the
  verbatim numeric files (`stat`, `statm`, `status`); per-process
  `cmdline` and `comm` values are replaced with obviously fake names
  (`proc-a`, `proc-b`) and the manifest `source` field gains a
  `-scrubbed` suffix noting it, because a runner's process list is not
  publishable data. The parsers must accept both real and scrubbed text,
  so the scrub never becomes parser load-bearing.

## Consequences

- All fixture-driven tests run in every local gate and on every CI job,
  regardless of OS; regressions surface before push, not in CI.
- The two committed fixtures come from different architectures and core
  counts, so field-count and format-difference handling (unavailable
  metrics) is exercised, not assumed.
- CI gains one more job; its cost is a standard Rust build per push.
- The summary/annotation transfer is a development-time channel only: the
  committed fixtures are ordinary files once landed, and no job output is
  load-bearing for tests after that.
