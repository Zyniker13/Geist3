# 0008 — Fixture replay smoke test

Date: 2026-11-14. Status: accepted. Supersedes: none.

## Context

M1 closes with "ztop runs on Linux in CI against fixtures" and a recorded
real-host smoke test (ROADMAP). The TUI needs a live terminal, which CI
and test harnesses do not provide, so end-to-end evidence needs a render
path that runs without a pty. Decision 0007 already promises a runner-side
self-test that parses the just-recorded fixture.

## Decision

- **`ztop replay <fixture-dir>`** parses a recorded fixture with the same
  code path the live collector's tests use (`sample_from_fixture`), renders
  one TUI frame at 80x24 through the production `draw` path on a
  `TestBackend`, prints it, and exits non-zero on any failure. It runs on
  every OS because fixture replay never touches the live OS.
- **Three users of one command.** The local gate (`scripts/check.sh`) runs
  `replay` against both committed fixtures on every push; the record
  workflow runs it against the freshly scrubbed fixture before committing
  it, as decision 0007's runner self-test; a real-host smoke record is the
  same command run on a development machine, kept in the milestone log.
- **The TUI render is a pure function** of the sample plus view state
  (`draw(frame, &Ui)`), so tests render into `TestBackend` buffers and the
  same `draw` serves the live terminal and the replay dump. A
  `draw_lines` helper exposes the rendered frame as text for both tests
  and the replay command.

## Consequences

- The full render path — fixture parse to model to frame text — is
  exercised in every local gate and CI job, on Linux and macOS alike,
  with no terminal required.
- The replay command is a viewer, not an auditor: it proves the fixture
  parses and renders, and the workflow additionally greps the frame for a
  process count and scrubbed process names; per-field precision stays
  with the fixture integration tests.
- `draw_lines` duplicates no rendering logic; it walks the same buffer the
  terminal backend would receive.
