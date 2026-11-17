# 0057 — Making the fuzzing claim real

## Context

Decision 0056 said the `fuzz/` crate "is built and tested in CI (the
`cargo fuzz` command is run in the CI workflow)". Neither half was true
when 0.1.0 was about to be tagged:

- No CI workflow ran `cargo fuzz` at all (a search of
  `.github/workflows/` found zero references).
- The committed `fuzz/` crate could not build: its `ztop-core`
  dependency pointed at `../crates/core` from the wrong directory
  (`..`), and thirteen of the seventeen targets called parser
  functions that were not `pub` (`parse_proc_stat`, `parse_proc_meminfo`,
  `parse_proc_loadavg`, `parse_proc_loadavg_entities`,
  `parse_cpuinfo_frequencies`, `parse_proc_uptime`, `parse_pressure`,
  `parse_proc_mounts`, `parse_proc_diskstats`, `parse_proc_net_dev`,
  `parse_pid_status`, `parse_chip_topology`, `parse_pin`,
  `parse_control_reply` and their return types `ProcStat`, `ProcMem`,
  `PidStatus`, `ChipTopology`).

## Decision

- The parsers and their return types are `pub` in `ztop-core`. They
  parse data the agent serves over the network (or the client receives
  from it), so they are the right fuzzing surface, and the fuzz crate
  is the right place to exercise them.
- `fuzz/` stays outside the Cargo workspace (the workspace `Cargo.toml`
  `exclude`s it): `cargo fuzz` manages its own toolchain and target
  directory, and keeping it out of `--workspace` keeps `scripts/check.sh`
  and `cargo deny` scoped to the product.
- `scripts/fuzz-smoke.sh` runs every target in `fuzz/fuzz_targets/`
  with `cargo +nightly fuzz run <target> --sanitizer none -- -runs=1000
  -max_len=8192` (overridable via `ZTOP_FUZZ_RUNS` /
  `ZTOP_FUZZ_MAX_LEN`) and fails if any target fails. `--sanitizer none`
  keeps the smoke fast and portable; the sanitizers matter on long
  runs, which stay manual.
- A `fuzz` job was added to `.github/workflows/ci.yml` (macOS, nightly,
  `cargo-fuzz`, the smoke script). macOS is the host where all
  seventeen targets compile: `crates/core/src/macos_io` is macOS-gated,
  so a Linux host cannot build the `parse_iflist2` target.
- Decision 0056's "15 targets" is corrected to 17.

## Consequences

- Every push now runs a short fuzz smoke over all seventeen
  network-facing parsers; a panic or crash in any of them turns CI red.
- The parsers are now part of `ztop-core`'s public API surface;
  changing their signatures is a breaking change for the fuzz crate
  (and for any future out-of-tree consumers).
- Long fuzz runs (with ASan/UBSan, corpus retention) remain a manual
  step; the smoke is a regression gate, not a vulnerability sweep.
