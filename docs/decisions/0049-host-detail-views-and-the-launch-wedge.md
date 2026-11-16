# 0049 — Host detail views, chart math, and the app-launch wedge

Date: 2026-11-15
Milestone: M6 (11b)

## Context

The fleet app's overview (decision 0046) shows one card per host. M6 11b adds
host detail views: navigate from a card to a per-host page with charts over the
agent's stored history (the agent serves `/v1/history?seconds=N` at a 1-second
cadence). The app has no test target, so chart math needs a testable home, and
the first recorded-run capture attempt hit an app-launch deadlock that consumed
most of the batch before its root cause surfaced.

## Decision

1. **Chart math lives in ZTopKit** (`swift/ZTopKit/Sources/ZTopKit/Charts.swift`),
   not in the app: `ChartSeries` is a pure, `Sendable` value type — a `Role`
   (cpu/memory/load/power/network), `points: [Double?]` where `nil` is a gap,
   and a `topValue` used for normalization. `normalized` clamps to 0…1 and
   keeps gaps; static builders (`.cpu/.memory/.load/.network/.power`) set
   `topValue = max × 1.1` so a pegged line stays readable. The app only draws;
   ZTopKitTests covers clamping, auto-scale, gaps and `range` (19/19 green).
2. **`HostDetailView`** (`app/Sources/ZTop/HostDetailView.swift`) fetches
   `AgentClient.history(seconds: 3600)` itself, merges live state for the
   header and per-core bars, and gates every section on data availability
   (`series.range != nil`): CPU (chart + per-core bars), memory (chart +
   used/swap/compressed rows), load (chart), network (when the collector
   provides it), power (Apple Silicon block). Recorded live against two TLS
   agents: `docs/screenshots/m6-mac-detail.png`.
3. **Recorded-run hooks**: `ZTOP_DETAIL=<host name>` makes FleetView push the
   detail view after the 7 s warm-up and re-render `HostDetailContent` via
   ImageRenderer every 5 s (`renderDetailLoop`), same pattern as the overview
   loop (decision 0046). ScrollView cannot render; the detail content is a
   plain VStack with a platform backdrop (`windowBackgroundColor` on macOS).
4. **The launch wedge, root cause and workaround.** Every launch of the app
   (direct exec, `open -n --fresh`, with `-ApplePersistenceIgnoreState`,
   `-NSDisablePersistence`, `.restorationBehavior(.disabled)`, after deleting
   the stale window-frame default, and with an NSAppleEventManager takeover of
   the open family) hung the main thread in window creation inside AppKit's
   launch-time reopen (`_reopenWindowsAsNecessaryIncludingRestorableState` →
   `NSPersistentUIManager restoreAllPersistentState`), waiting forever on a
   `mach_msg` reply. The stack pointed at state restoration, but the real
   trigger was **stale Keychain items**: tokens stored under the
   `dev.ztop.token` service by earlier ad-hoc-signed builds made startup
   Keychain access demand an ACL approval prompt that cannot display before
   any window exists, so window creation never completed. **Deleting the
   stale items (`security delete-generic-password -s dev.ztop.token` until
   none remain) fixed every launch instantly**; the same relaunch then paired
   two fresh agents and rendered live. Recorded runs must therefore wipe
   `dev.ztop.token` items and `~/Library/Application Support/ztop/` before
   launching, and restart the test agents first — pairing codes expire after
   5 minutes, which is why the first seeded run showed both hosts `needs
   pairing`.

## Consequences

- Chart math is unit-tested where tests exist; the app stays a renderer.
- The detail view is honest about gaps: sections for data the macOS collector
  does not provide (network interfaces, disks — `crates/core/src/macos.rs`
  still fills `net: Vec::new()`) simply do not render; that collector gap is
  tracked by the open parity item "Disks, network, temperatures and fans".
- The recorded-run recipe grows two steps (Keychain wipe, fresh agent codes).
  No app code change was needed for the wedge; the NSAppleEventManager
  takeover attempted along the way was reverted — it also swallowed the
  initial window open.
- The successful recorded runs are committed: `m6-mac-overview-live.png`
  (two live hosts, CPU/MEM meters) and `m6-mac-detail.png` (charts, per-core
  bars, sensors, power). Loopback addresses and fake host names only.
