# Decision 0011: macOS power, frequency and SMC sources

- Status: accepted
- Date: 2026-11-14
- Decides: which power/frequency/temperature/fan sources zTop uses on macOS,
  following the no-root policy of decision 0009.

## Context

M2 requires IOReport power/frequency plus SMC temperatures and fans, all
without root. Unprivileged probing (C probes 13–19, this decision's evidence)
established what IOReport and the AppleSMC user client expose without root.
IOReport has no supported header; every symbol is declared by hand, and the
argument orders below were verified by probes, not assumed.

## Findings (probes 13–19)

- CPU state residency: group "CPU Stats", per-core channels named
  `EACC_ECPU<n>` / `PACC0_PCPU<n>` / `PACC0_MCPU<n>` (+ cluster-level `EACC`,
  `PACC0`). Channel dicts carry binary `RawElements`: 64-byte records,
  state name at bytes 32:40 (ASCII, NUL-padded), transitions at 40:48,
  residency at 48:56 (i64 LE). Units are mach ticks (125/3 ns,
  `hw.tbfrequency` = 24 MHz), cumulative since boot; an interval value is
  s2 − s1. State names: idle state is `ELDI` on both clusters; E-cluster
  active states run `0P6V`..`3P3V`, P-cluster `91P0V`..`0P91V` (21 states).
  State names encode relative performance levels, NOT MHz.
- CPU energy: none unprivileged. A full enumeration of all 8,709 IOReport
  channels shows exactly 6 channels with an energy unit: GPU + 5 PCIe ports.
  The "CPU Stats" group contains only residency counters.
- GPU power: group "Energy Model", channel `GPU Energy` responds to real
  Metal load (34.77e9 units over a ~4 s burner window; ~1.1 W average since
  boot). Cooked samples only: `IOReportCreateSamples(r, sub, previous)`;
  `IOReportSimpleGetIntegerValue` works on samples created WITH a previous
  sample and raises on the first (previous = NULL). Unit is 1e-9 J;
  watts = delta / elapsed seconds. PCIe energy channels exist but read 0
  on a laptop without dGPU/TB traffic.
- ANE: groups "ANE Stats"/"ANE1" expose only a `status` counter — no ANE
  power unprivileged.
- CPU frequency: no unprivileged source. No frequency/perf sysctl exists
  (only `hw.tbfrequency`), state names carry no MHz, and `powermetrics`
  (which has the mapping) requires superuser.
- SMC: the `AppleSMC` user client opens unprivileged; the canonical
  80-byte `SMCKeyData` protocol (selector 2, `data8` = 9 read-keyinfo /
  5 read-bytes, key index enumeration via `#KEY` count + `data8` = 8 with
  `data32` = index) reads keys. `flt ` values are little-endian floats.
  On the probed host: CPU die temps `Te07..Te0i` and composite `TCMb`,
  ambient `Ta0P`, GPU `Tg01` (°C); one fan `F0Ac`/`F0Mn`/`F0Mx`/`F0Tg`
  (RPM); system power `PSTR` (W, responds to load). The key set is
  host-specific; many keys are absent per machine.

## Decision

The macOS collector reports, unprivileged:

- Per-core utilization from CPU-state residency: busy share =
  1 − (idle-state ticks / total ticks) over the interval, idle = `ELDI`
  (and any `IDLE`/`*LDI`/`OFF` state names). This complements the
  hostinfo tick source used for the process table.
- GPU watts from the `GPU Energy` channel delta; CPU package power is
  marked unavailable (no channel exists without root).
- SMC temperatures (CPU composite `TCMb` or first available `Te*`,
  GPU `Tg01` if present), fan RPM (`F0Ac` with `F0Mx` when present),
  and system power `PSTR` when present; each read by key with absence
  per key, never faked.
- CPU frequency in MHz is marked unavailable; where useful, the collector
  shows the relative state ladder (state names) instead. No conversion
  to MHz is ever attempted.

## Consequences

- zTop shows real GPU watts, system watts, temperatures and fans without
  root, where asitop obtains them through sudo'd `powermetrics`; the
  recorded comparison in docs must state this privilege difference.
- CPU power and MHz columns show `-` on macOS. This is the honest
  no-root answer, not a gap to paper over.
- First-sample semantics: a fresh subscription's first sample raises on
  value reads and has no interval; the first collector tick reports
  rates as unavailable/zero, matching the m2-live contract.
- Probe evidence lives in the session scratch, not the repository; this
  decision is the durable record. Regenerating fixtures for SMC/IOReport
  on other hosts must reuse the same key/channel names.
