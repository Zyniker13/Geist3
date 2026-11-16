# Decision 0046: the app shell and the recorded-run hooks

## Context

M5's "done when" asks for the app pairing with two agents and showing
both live, recorded in screenshots on an iPad simulator and the Mac.
The shell has no Screen Recording permission, so `screencapture`
cannot photograph the Mac window, and AppleScript UI scripting has no
Assistive access; a SwiftUI sheet also cannot be driven from a script
there. The iPad simulator has neither restriction (`simctl io
screenshot` works), but its forms cannot be typed into either.

## Decision

- The app is one multiplatform SwiftUI target (`app/project.yml`,
  destinations iOS + macOS) over the ZTopKit package. `HostStore`
  (`@MainActor` `ObservableObject`) keeps `HostRecord`s as JSON in
  Application Support (tokens move to the Keychain in their own M5
  batch), polls every host concurrently every 2 seconds, and marks a
  host live, stale (last good sample inside 10 s) or unreachable.
  The fleet overview (`FleetView` → `FleetContent`) shows one
  `HostCard` per host: state color, address:port, uptime, CPU and MEM
  meters; the empty state explains starting an agent. `AddHostSheet`
  adds by hand and optionally pairs immediately; `PairSheet` pairs an
  unpaired card later. Meter bars are drawn capsules, not
  `ProgressView`, which `ImageRenderer` renders as a placeholder.
- Recording happens through two documented hooks that drive the real
  flows rather than faking screens: `ZTOP_PAIR` (launch environment,
  `name=host:port=pin=code;…`) pairs through the same `add` call the
  form drives, idempotent per host:port; `ZTOP_SNAPSHOT` renders the
  live `HostCard`s offscreen with `ImageRenderer` after two poll
  ticks and writes a PNG.
- The recorded artifacts: `docs/screenshots/m5-mac-overview.png` (the
  app's own render of its live overview for two agents on this
  machine) and `docs/screenshots/m5-ipad-overview.png` (a real
  `simctl` screenshot of the iPad Pro simulator watching the same two
  agents). Both show fake names (`host-a`, `host-b`) and loopback
  addresses only.

## Consequences

- M5's pairing-and-overview core is demonstrable in CI-free recorded
  form; Bonjour-based adding, Keychain storage and reconnection
  remain open M5 items.
- The hooks read the environment only at launch, add nothing network
  facing, and ignore malformed entries, so they are inert in normal
  use.
- `screencapture`-based screenshots remain impossible from the shell;
  if a window photograph is ever needed, it has to come from the
  simulator path or a permission-granted session.
