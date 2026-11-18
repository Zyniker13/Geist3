# 0059 — Install cargo-fuzz with the nightly toolchain

## Context

The Fuzz smoke job on `macos-latest` (an arm64 runner) failed on every
target with:

```
error[E0463]: can't find crate for `core`
  = note: the `x86_64-apple-darwin` target may not be installed
```

cargo-fuzz was building with `--target x86_64-apple-darwin`, but the
toolchain the build used (the `nightly` installed by
`dtolnay/rust-toolchain`) is `aarch64-apple-darwin` and has no
x86_64 std.

The cause is how cargo-fuzz was installed: `taiki-e/install-action`
built it with the runner's preinstalled rust, which is x86_64 (it runs
under Rosetta on the arm64 runners). cargo-fuzz determines its default
fuzz target from the architecture it was compiled for, so the x86_64
binary targets `x86_64-apple-darwin` even on an arm64 machine. The
build then runs under the arm64 nightly toolchain, which cannot
compile for x86_64 without the x86_64 std.

This was invisible for several runs: the job logs of failed runs are
not readable without admin rights, and the annotation path that would
have shown it died on a BSD-awk `printf "%0A"` bug (fixed in the same
round).

## Decision

- The fuzz job installs cargo-fuzz with the nightly toolchain
  (`cargo +nightly install cargo-fuzz`) instead of
  `taiki-e/install-action`. The binary is then arm64, targets the
  native `aarch64-apple-darwin`, and needs no extra target std.
- `scripts/fuzz-smoke.sh` and the packaging workflow emit their
  failure annotations with `awk 'NR>1{printf "%%0A"} …'`: in an awk
  `printf` format `%` starts a conversion specifier, so the literal
  `%0A` the annotation format wants must be written `%%0A`.

## Consequences

- The fuzz smoke runs natively on the arm64 runner; no Rosetta, no
  cross target.
- The install takes ~1–2 minutes per run (cargo-fuzz is built from
  source); the job timeout is 45 minutes, so this is fine.
- Any future tool that must match the fuzz build's architecture should
  be installed the same way (with the toolchain that builds the fuzz
  targets), not with the runner's preinstalled rust.
