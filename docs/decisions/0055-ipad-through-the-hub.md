# Decision 0055: the iPad reads the fleet through one hub

Date: 2026-11-15
Status: accepted (part of batch 14b)

## Context

M6's hub parity item has two halves. 14a made the Mac app run the
hub (decision 0054); the other half is the iPad working through the
hub, and M6's "Done when" pins the shape of the proof: an iPad
simulator watches three agents through a hub in a recorded check.

The hub's protocol was built for this in 11a: it answers with the
agent's own shapes plus one addition, a `host` selector
(`?host=name`, the config's name for the agent) on `/v1/snapshot`
and `/v1/history`, and `/v1/hosts` lists what it watches with each
machine's state in the hub's own words. The hub archives whole
samples — it does not proxy the agent's `/v1/processes`.

## Decision

1. **A hub is a record, not a special mode.** `HostRecord` gains
   `isHub` (default false; old hosts.json files decode unchanged).
   Pairing a hub record is the agent flow verbatim — the hub's
   `/v1/pair` has the agent's reply shape — so `add`, `pair`,
   `remove` and the Keychain token storage need no hub branch. The
   Add sheet gains a "This is a hub" switch (port prompt flips to
   the hub's default 7101), and the recorded runs seed one with
   `ZTOP_HUB_PAIR=name=host:port=pin=code`, shaped exactly like
   `ZTOP_PAIR`.
2. **The poller fans out for a hub record.** `pollHub` reads the
   hub's `/v1/hosts` — the authority for each machine's state (the
   hub's own words: live, stale, unreachable) — and then fetches
   each machine's latest sample with `snapshot(host: name)`. The
   machines the hub lists appear under the hub's card; machines the
   hub stops listing disappear. When the hub itself is unreachable,
   every machine it kept goes unreachable with it. Hub records are
   not snapshot-polled themselves: their card is the section header,
   not a machine.
3. **The client learns one thing: the selector.** `AgentClient`
   gains `snapshot(host:)` and `history(seconds:host:)`, which
   append `?host=` (percent-encoded) — no separate hub client
   class, because the hub speaks the agent protocol. A live
   ZTopKit test spawns two real agents, writes the agents file
   from their paired tokens (the same file the app writes), starts
   a real hub, pairs with it, and reads both machines back through
   pinned TLS — snapshot, history, and the hub's 404 wording for an
   unknown name.
4. **A hub machine's detail is the same screen, fed differently.**
   `HubDetailView` reuses `HostDetailContent` with the hub's
   history (`history(seconds: 3600, host: name)`) and the machine's
   sample from the poller; the caption shows the machine's real
   agent address (the hub's config target), not the hub's address.
   The process table is absent there (`showsProcesses: false`): the
   hub archives samples, not process lists, and a table that would
   read "no processes" would be a lie. The SoC push is likewise
   absent — the detail's SoC button needs the direct endpoint the
   hub does not proxy.
5. **The proof is the recorded check M6 names.** Three real agents
   on loopback (scratch homes), a shell-run hub on 7102 watching
   all three by name with their tokens, and the app installed on
   the iPad simulator seeded with `ZTOP_HUB_PAIR` — the overview
   then shows all three machines with live samples read through
   the hub. Captured with `simctl io screenshot` into
   `docs/screenshots/m6-ipad-hub.png`.

## Consequences

- One endpoint governs a fleet: the iPad's hosts.json carries a
  single record for a whole machine room, and the machines it shows
  are whoever the hub says is in it.
- The hub's 2 s poll cadence bounds the fleet's freshness on the
  iPad (same order as the direct poller's 2 s); a machine's sample
  is at most two cadences old, and the hub's own state wording is
  what the card shows.
- Everything a hub machine's detail shows comes from archived
  samples; interactive surfaces that need the agent's other
  endpoints (processes, signals, the SoC screen) stay on the
  direct-connection path for now, and the screen says nothing that
  would pretend otherwise.
- The Xcode pre-build phase learned a second lesson: declaring the
  phase's output file makes Xcode pre-create its directory on every
  platform, so the iOS branch now removes the stray `Contents/` the
  declaration creates — a flat iOS bundle must not contain one
  (simctl refuses to install it: "Missing bundle ID").
