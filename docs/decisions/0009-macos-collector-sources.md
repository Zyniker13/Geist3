# 0009 — macOS collector sources and the no-root Apple Silicon view

## Context

M2 adds the macOS collector: the same fields the Linux collector already provides
(CPU per core, memory, swap, load, uptime, processes with threads, disks, network,
sensors) plus the Apple Silicon view (power and frequency residency per E/P cluster,
per core, GPU, ANE, package). DESIGN.md pins the source libraries but not the exact
channel names, the delta method, or what to do when a source is denied to an
unprivileged process. Every ztop metric must work without `sudo`; data that needs
more is marked unavailable, never faked.

## Decision

**Sources, per subsystem (all unprivileged):**

- CPU ticks, load: `host_statistics64` / `host_loadavg_info` (Mach).
- Memory, swap: `sysctl` (`hw.memsize`, `vm.swapusage`) and `vm_statistics64` /
  `host_swapusage` for live values.
- Uptime: `sysctl kern.boottime`.
- Processes and threads: `libproc` (`proc_listallpids`, `proc_pidinfo`) — same
  process count and thread counts as Linux's `/proc`.
- Disks, network, battery: IOKit, as DESIGN.md already states. Network counters come
  from the IOKit network statistics; disks from IOMedia statistics; battery from the
  AppleSmartBattery registry properties.
- Apple Silicon power and frequency: IOReport, read unprivileged through
  `libIOReport` (the SDK ships `usr/lib/libIOReport.tbd`; the `IOReport.h` API
  surface is used by declaring its prototypes, since Apple does not ship the
  header). The flow is:
  `IOReportCopyChannelsInGroup` → `IOReportCreateSubscription` →
  `IOReportCreateSamples` (interval apart) → `IOReportCreateSamplesDelta`; each
  delta dictionary value is an array of per-channel samples; simple channels are
  read with `IOReportSimpleGetIntegerValue`, performance-state channels with
  `IOReportStateGetResidency` per state name.
  Groups used: `CPU Stats` (per-core and cluster performance-state residency, i.e.
  frequency residency for E and P cores), `GPU Stats` (GPU performance states and
  power), `Energy Model` (GPU and PCIe energy deltas). On the development host all
  three copy, subscribe and delta as an unprivileged user (probed 2026-11-14).
- Temperature and fans: SMC via the AppleSMC user client. On the development host
  the read call returns `kIOReturnNotPrivileged` to an unprivileged process, so the
  collector attempts the unprivileged read and marks the metric unavailable when the
  kernel denies it — never faked, and no `sudo` fallback.
- ANE power: the `ANE Stats` IOReport group does not subscribe unprivileged on the
  development host; the ANE metric is unavailable there. Where a host allows it, it
  appears.
- Intel Macs: everything except the IOReport groups (they are absent there) — the
  collector records per-source availability and the UI says "unavailable" for the
  rest.

**Fixture capture and tests:** `ztop capture` gains a macOS mode that records the
raw inputs as text entries in the same fixture format (format version 1):
sysctl outputs, Mach tick counters, a libproc snapshot, a full IOReport
subscribe/sample/sample/delta transcript (channel names, units, raw deltas), the
SMC call results, and battery properties. `sample_from_fixture` gains a macOS
parser over those entries, and the per-field fixture tests derive every expected
value from the raw recorded text, the same machine-state-proof approach M1 ended
with, so re-recorded captures keep tests green while column or unit drift fails.

**Comparison with powermetrics:** `powermetrics` itself requires `sudo`, so per the
project rule the recorded comparison in `docs/` covers only what no-sudo tools can
show (our own IOReport values, checked for sanity and consistency across repeated
runs, plus `sysctl`-checkable counters). Anything a powermetrics comparison would
need root for is recorded in the doc as unchecked, in one line, rather than
silently skipped.

**Perflevel enumeration:** cluster layout is discovered dynamically (iterate
`hw.perflevelN.*` until a level is missing; per-core identity from IOReport channel
names), never hardcoded for a particular chip.

## Consequences

- ztop on macOS needs no root for any metric it shows; unavailable sources are
  explicit. This is the design's headline differentiator against `asitop`.
- Fixture tests for macOS run on any machine (the fixtures are recorded text), so
  Linux CI keeps testing macOS parsers.
- The IOReport prototypes are declared in-tree because Apple ships no public
  header; the symbols come from `libIOReport.tbd`, which is part of every macOS
  SDK, so no vendored code and no third-party dependency is needed.
- If a future macOS denies IOReport reads unprivileged, the Apple Silicon view
  degrades to unavailable instead of breaking the collector.
