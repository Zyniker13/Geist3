# 0033 — GPU utilization and thermal pressure (asitop parity)

Date: 2026-11-15
Status: Accepted
Scope: crates/core (macos_power), crates/tui (SoC screen), docs

## Context

The asitop parity line in docs/parity.md had two collector gaps left
after the per-core meters and power work: GPU utilization and thermal
pressure. Both had been provisionally assumed unavailable:

- The IOReport "GPU Stats" group subscribes unprivileged, but its
  channels are STATE-type: `IOReportSimpleGetIntegerValue` returns the
  i64::MAX sentinel for both of a delta pair, so every under-load probe
  read Δ 0. The real residency lives in a private `RawElements` CFData
  blob (64-byte records: bucket index + u64 counter, cumulative ns) and
  the state getters (`IOReportStateGetResidency`, `IOReportStateGetCount`,
  `IOReportMergeChannels` — found via dlsym; the dyld shared cache hides
  them from nm/strings) want an argument shape that is not documented
  anywhere reachable. `IOReportSimpleGetDoubleValue` and
  `IOReportStateGetValue` do not exist as symbols.
- Thermal pressure routes (`kern.thermalpressure` sysctl, SMC keys,
  IOReport thermal channels) either need root or expose no stable key.

## Decision

- GPU utilization comes from the IORegistry: read the IOGPU service
  (`IOServiceGetMatchingService` + `IOServiceMatching`; AGXAccelerator
  as a fallback name) with `IORegistryEntryCreateCFProperties`, then
  `CFNumberGetValue` on `PerformanceStatistics` → "Device Utilization %"
  — the same unprivileged estimate the system's own GPU-history graph
  reads. The value is instantaneous (no delta priming), clamped to
  0..=100, and zero is a legitimate idle reading (only negative values
  are rejected). Live-verified on the development machine: 0% idle,
  9–11% under a Metal compute load.
- Thermal pressure comes from `pmset -g therm` (unprivileged), mapped to
  none/light/moderate/severe. Only the no-warning shape ("No thermal
  warning level has been recorded") has been observed on the development
  machine; any other output stays unavailable rather than guessed. A
  level that somehow carries a value outside 0..=3 renders "unknown".
- The SoC screen renders the GPU row as `GPU  util N%  M.M W` (util +
  energy-delta watts together) and gains a `Thermal` row with the level
  word. The explicit unavailable gap line drops GPU busy and thermal
  pressure and keeps the rest (CPU/ANE power, cluster busy/frequency,
  GPU frequency).
- The model fields (`gpu_busy_percent`, `thermal_pressure`) predate this
  change and were simply never filled; no model change was needed.

## Consequences

- The asitop parity section is now fully checked except the recorded
  unavailable items, which are checked with their decisions cited.
- The GPU read costs a full registry-properties dictionary copy per
  sample on macOS; it is released every time and the service handle
  lives for the collector's lifetime. Thermal adds one `pmset` process
  spawn per sample; if that ever shows up in cost, it can be cached and
  refreshed on a slower cadence than the screen's own interval.
- The nonzero thermal shapes are still unverified live — the parser
  refuses them instead of inventing a level. If a machine ever reports
  one, the honest fix is extending the parser against the observed
  output, not ahead of it.
- Tests: `thermal_level_reads_the_no_warning_shape`,
  `thermal_level_stays_unavailable_on_unknown_shapes` (core);
  `thermal_pressure_renders_as_words_or_a_dash`, and the extended
  `the_silicon_screen_shows_chip_cores_and_power` (TUI).
