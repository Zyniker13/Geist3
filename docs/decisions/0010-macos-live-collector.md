# 0010 — The macOS live collector reuses the capture text and the fixture parsers

## Context

M2 needs the macOS collector to serve live samples. The capture already
assembles the same values as text (`hostinfo`, `processes`), and
`ztop_core::macos` parses that text for fixture replay (decision 0008
records that replay shares the live parse path). Keeping a second,
independently written live path would let the two drift: a format change
in capture would silently leave live behind.

## Decision

The live collector (`ztop_core::macos_live`, gated to macOS because it
reads Mach, libproc and sysctl) assembles the *same text* the capture
records, by calling shared producers extracted from `capture_macos`
(`hostinfo_text`, `processes_text`), and parses it with the ungated
`ztop_core::macos` parsers. A shared `sample_from_parts` in `macos`
assembles the `Sample` for both the fixture replay and the live
collector, so both interpret the text identically. Per-core CPU rates
come from the same counter-delta math as Linux (`core_percents`, moved
to `model` because it is `CpuTimes` arithmetic, not Linux-specific);
per-process CPU rates come from the delta of cumulative CPU
nanoseconds between samples. The live collector's tests assert only
machine-independent properties, so they hold on any Mac, including CI
runners (decision from the `vm.swapusage` CI failure).

## Consequences

A change to a capture format automatically flows into live parsing, and
a capture-format bug shows up in live sampling too — shared risk, shared
fix. The collector marks a source it cannot read as `Unavailable` rather
than fabricating values (decision 0009). Duplicating the rate math
instead of sharing it was rejected: the helper is platform-neutral.
