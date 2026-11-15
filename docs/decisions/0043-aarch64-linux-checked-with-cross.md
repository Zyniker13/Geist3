# Decision 0043: aarch64 Linux checked in CI with cross

## Context

From batch 8e on, `ztop-core` depends on rustls with the ring backend,
and from 8f on every crate reaches it. ring builds C and assembly with
a C compiler for the *target*, so a Linux-target clippy on the macOS
host fails in ring's build script — there is no Linux sysroot or
cross gcc here (decision 0039's limitation). CI's Linux runner covers
x86_64 natively; `aarch64-unknown-linux-gnu` was checked nowhere, and
the platform matrix (Apple Silicon, and the Linux arm64 boxes people
run ztop on) is not a corner.

## Decision

The Linux CI job runs, after its normal `check.sh`:

    cross clippy --workspace --all-targets --target aarch64-unknown-linux-gnu -- -D warnings

`cross` (installed with the same taiki-e step as cargo-deny) executes
cargo in a container that ships the aarch64 toolchain and C compiler,
so ring's build script gets a real `cc` for the target. No local
machine work is duplicated: the macOS host stays out of Linux-target
lints, and the local gate remains `scripts/check.sh` + `cargo deny`.

## Consequences

- aarch64 Linux is linted (not unit-tested) on every push; runtime
  behavior on arm64 Linux still rides on the fixtures and the same
  collector code being target-independent.
- Each Linux CI run gains a container pull and a cross build (a few
  minutes, largely cached by rust-cache for the local target dir).
- `cross clippy` is checked for real on the first push; if a cross
  image quirk appears, the fallback is `cargo-zigbuild` + zig (lighter,
  no container) — noted here so the retry path is already chosen.
- Decision 0039's "aarch64 is checked nowhere" note is superseded by
  this; the local ring wall stays as documented there.
