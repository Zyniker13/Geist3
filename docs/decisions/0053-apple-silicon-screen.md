# Decision 0053: the Apple Silicon (SoC) screen in the app

Date: 2026-11-15
Milestone: M6, batch 13c
Status: Accepted

## Context

The TUI's SoC screen already carries the asitop-parity readout
(chip, clusters, GPU, power, thermal — decision 0013), and the app's
detail page compresses the same data into a few rows under "Apple
Silicon". The parity item "Apple Silicon view for Macs" asks for a
real zoom-in, and the app is where a Mac or iPad operator would
watch a laptop's power story.

Two data realities shape what the screen can honestly show:

- Aggregate cluster busy and cluster/GPU frequencies stay
  unavailable unprivileged (decision 0011); per-core busy bars on
  the detail page remain the utilization zoom-in.
- Per-sample package watts have no unprivileged source, but the
  agent continuously collects whole-system power (`PSTR`) into
  `AppleSilicon.power_history`; the TUI draws its wattage chart from
  that history.

## Decision

- A dedicated `SocView` is pushed from the detail page via a toolbar
  gauge (`cpu`), shown only while the host reports a chip name — on
  Intel Macs' agents the entry point is hidden and there is no empty
  screen to reach.
- The screen shows: the chip name with a thermal-pressure badge
  (none/light/moderate/severe), a Clusters section (aggregate busy
  bars where the agent exposes them, otherwise the honest
  "unavailable unprivileged" note), an integrated-GPU utilization
  bar, and a Power section with now/average/peak rows plus the
  watts history chart.
- The watts chart is a new ZTopKit factory, `ChartSeries.socPower`,
  built from `AppleSilicon.powerHistory` rather than from the
  fetched history samples: the agent-side history is continuous and
  carries the PSTR readings, while per-sample package watts are
  unavailable (decision 0011) and would leave the detail page's
  `power` series empty on every Apple Silicon Mac.
- Everything availability-gated like the detail page: a field the
  host cannot expose keeps its row out instead of showing a dash.
- The screen keeps no fetch loop of its own: every value, including
  the power history, rides the poller's latest snapshot. A snapshot
  already carries the full history ring, so re-fetching would add
  requests without adding information.
- Recorded runs capture the screen with `ZTOP_SOC=<host>` (the twin
  of `ZTOP_DETAIL`): FleetView pushes the screen and re-renders
  `SocContent` offscreen every 5 s, in a fixed 820×400 frame — the
  content's natural height, so the committed capture carries no
  blank band and no crop step.

## Consequences

- The app now covers the TUI's SoC screen for Macs and iPads;
  the parity item is closed with a live capture
  (`docs/screenshots/m6-mac-soc.png`).
- `ChartSeries.socPower` is pure ZTopKit data and unit-testable;
  the detail page's existing `power` series is untouched.
- When an agent gains an unprivileged cluster-frequency or
  package-watts source, the screen grows the rows without layout
  changes — the same availability-gating rule as everywhere else.
