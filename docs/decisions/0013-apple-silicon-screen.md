# 0013 — The Apple Silicon screen shows only what an unprivileged collector can read

## Context

M3 batch 7b adds an Apple Silicon screen (the `a` key) so Mac users get the part of
`asitop` that does not need root. Probing IOReport as the unprivileged collector
established what is actually readable without entitlements: the Energy Model group
(GPU and PCIe power), SMC sensors, the PSTR system-power figure and Mach per-core
load. CPU power, CPU per-core energy, ANE power, cluster busy/frequency, GPU
busy/frequency and thermal pressure are denied or absent unprivileged. Virtualized
Macs also advertise `hw.perflevel*` names that do not follow the documented
"Performance"/"Efficiency" mapping, so cluster counts read from those names can be
wrong.

## Decision

The Apple Silicon screen shows: chip name (`machdep.cpu.brand_string`), P-core and
E-core counts — counted only from levels whose name literally says "Performance" or
"Efficiency" — per-core utilization from Mach, whole-system power (PSTR) as
current/average/peak plus a 60-point history chart, GPU power from the Energy Model
group, and memory/swap from the regular sample. Everything else renders as one
explicit "Unavailable unprivileged" note rather than as dashes, zeros or guesses
(the honesty rule of decision 0009). `package_watts` stays `None`; the PSTR figure
is whole-system and is labelled as the machine's power, not a package number.

## Consequences

- On this VM the perflevel names do not match the documented mapping, so E/P counts
  degrade to unavailable here; real hardware is expected to report them. The parser
  is tested against both shapes, so the degrade path is exercised on every run.
- `docs/parity.md` ticks only the chip-and-cluster-counts item of the asitop
  section for now; power arrives with this screen but the section's full wording
  (CPU/GPU/package split, ANE, cluster utilization) stays unticked because parts of
  it are unobtainable without privileges.
- The signal menu and other overlays keep working on this screen; table-only keys
  do nothing there.

Licensed under either of MIT or Apache-2.0.
