# Decision 0054: the hub runs from the Mac app

Date: 2026-11-15
Status: accepted (part of batch 14a; the iPad-through-hub half of the
parity item is still open)

## Context

M6's parity item couples two halves: the Mac app installing and
running the hub as a login item, and the iPad working through the
hub. The hub already exists as a CLI (`ztop hub`, decision 0048) with
its own state under `state_dir()/hub/` — default `agents.json`,
`history.db`, tokens, TLS material — but until now only the shell
could start it.

Constraints that shaped this batch:

- The app already holds everything the hub needs to poll: saved hosts
  (name, host, port, pin) and the agents' bearer tokens (Keychain,
  decision 0047).
- A login item needs a launchd agent description; SMAppService (macOS
  13+) requires that plist to live inside the app bundle, in
  `Contents/Library/LaunchAgents/`, and a plist must name its
  executable by absolute path.
- The operating rules for recorded checks on this machine forbid
  installing launchd services, so the registration call cannot be
  exercised in a recorded check even though the feature ships.
- ImageRenderer cannot draw `Form` or a real `Toggle` (the same
  limitation that moved the process table to a plain `VStack`,
  decision 0052).

## Decision

1. **The `ztop` binary is embedded in the app bundle.** A build phase
   in `app/project.yml` copies `target/release/ztop` (falling back to
   `target/debug/ztop`) into `Contents/MacOS/ztop-embedded` on macOS
   builds; the phase exits early on iOS, where there is no bundle
   layout to copy into. The app therefore ships the hub it promises
   to run, with no Homebrew dependency for the hub path.
2. **One argument list, two runners.** `HubPlan.arguments(port:)` in
   ZTopKit is the single source: `hub --port <port> --bind 127.0.0.1
   --tls --pair`. The app's Run-now button spawns the embedded binary
   with it; the login-item plist embeds the same list. The hub binds
   loopback only: 0.1.0 deliberately puts nothing on the network (the
   recorded iPad check runs on this same Mac), and the hub CLI still
   accepts a wider bind by hand for anyone who wants one.
3. **The agent list is the app's saved hosts.** `HubPaths.writeAgentsFile`
   writes the hub's default `state_dir()/hub/agents.json` from the
   host records, omitting empty pins/tokens (the hub validates a
   present pin against `SHA256:<64 hex>`). The file carries the
   agents' bearer tokens — the hub reads with the user's authority —
   so it is written with mode 0600. The Keychain remains the only
   place tokens live between runs; this file is the hub's working
   copy, regenerated from the Keychain-backed records every time the
   hub starts or the screen opens.
4. **The app is its own first hub client.** `HubRunner` reads the
   hub's stdout, lifts the printed `Pairing code:` and
   `TLS fingerprint:`, and pairs with them (decision 0041's pin
   first, then pair). The hub token lands in the Keychain under the
   fixed name `hub` — same store, different "host" key — and every
   read of `/v1/hosts` goes through a client pinned to the hub's own
   fingerprint. What the recorded run does automatically is exactly
   what the screen teaches a human to do for another client.
5. **The login item writes its plist into the app bundle.** Because
   the bundle is unsigned today (`CODE_SIGNING_ALLOWED=NO`), the app
   can write `dev.ztop.hub.plist` into its own
   `Contents/Library/LaunchAgents/` at install time — which is also
   what resolves the absolute-path requirement without a build-time
   template. `HubPlan.plistXML` produces the XML (KeepAlive so a
   crash restarts the hub, logs under the hub's state directory);
   `HubInstaller` wraps SMAppService register/unregister/status.
   When the app ships signed (packaging, M7), an in-place plist write
   would break the seal — that batch must switch to the helper-app-in-
   `Library/LoginItems` shape or pre-bake the plist. Recorded here so
   it is not rediscovered under time pressure.
6. **The hub screen is a plain `VStack`.** `Form` and real switches
   do not render under ImageRenderer; the login toggle gets a drawn
   capsule replica (`staticToggle`) in the recorded-run path only, the
   interactive screen keeps the real control. Same trade as the
   process table's search field (decision 0052).

## What is checked, and how

- ZTopKit `HubKitTests` (3 tests): the agents file omits empty
  pin/token and round-trips; the plist embeds exactly the shared
  argument list with KeepAlive/RunAtLoad and state-dir logs; the
  plist is well-formed XML even with an `&` in the binary path.
- Recorded live (`docs/screenshots/m6-mac-hub.png`): two TLS agents
  on loopback, the app pairs with both, writes agents.json, starts
  the embedded hub, pairs with the hub, and the watched-agents list
  reads both back **Live** from the hub's own `/v1/hosts` over pinned
  TLS. The file on disk was verified 0600 with both agents present.
- NOT exercised on this machine: the SMAppService register/unregister
  calls (the launchd-services rule). The screen's toggle honestly
  shows its unregistered state in the capture. CI cannot exercise
  them either (no stable GUI/login session on the runner); the calls
  stay a thin skin over the unit-tested data layer.

## Consequences

- The hub the app runs and the hub a shell runs are one binary with
  one state directory, so a hub started either way is inspectable and
  restartable by the other.
- Port conflicts surface as "Not running" with no error text yet
  (the hub's bind failure goes to its stderr pipe); a follow-up can
  surface the wording. Recorded here because the first re-capture
  hit exactly this — a stale hub from the previous run held 7101.
- The iPad-through-hub half (`?host=` in the app, three-agent
  recorded check) is the next batch and closes the parity item.
