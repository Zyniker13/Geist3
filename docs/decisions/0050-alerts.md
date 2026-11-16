# 0050 — Alerts: rules, the evaluation engine, and the app surface

Date: 2026-11-15
Milestone: M6 (12)

## Context

M6's alerts item (DESIGN.md): per-host or fleet-wide thresholds — for
example CPU above 90% for 5 minutes, disk above 90%, host unreachable —
shown in the app and as local notifications. The app has no test
target, so the evaluation logic needs the same home as the chart math
(decision 0049): ZTopKit, tested with fixed clocks.

## Decision

1. **Rules** (`AlertRule` in ZTopKit): a name, an optional host
   (`nil` = fleet-wide), a kind (`cpu`, `memory`, `load`, `disk`,
   `unreachable`), a threshold (percent for cpu/memory/disk, absolute
   for the 1-minute load average; none for `unreachable`), and a
   duration the condition must hold before the alert fires. Rules
   persist as plain JSON (`alerts.json` in Application Support) — no
   secrets, so unlike the host records nothing goes to the Keychain.
2. **Engine** (`AlertEngine` in ZTopKit): pure and deterministic; the
   caller feeds one host's current sample (nil when the host is not
   live) plus its unreachability each tick and gets `.fired`/`.cleared`
   events. A violation timer starts at the first violating sample and
   fires when it has held for the duration; a cleared or unavailable
   metric resets it, and a fired alert clears only when the condition
   ends (no re-fire spam). The engine's tracks are per (rule, host)
   and in-memory: after a relaunch timers start over. Rules deleted
   from the list leave no stale tracks.
3. **App surface**: `AlertCenter` (app target) persists the rules,
   subscribes to `HostStore.$live` (no polling changes — every poll
   tick is evaluated once per host; a `stale` host contributes no
   metrics), and posts local notifications through
   UNUserNotificationCenter **only when the user already allowed
   them** — authorization is requested from the add-alert sheet's
   confirm action, never silently at launch. The alerts screen lists
   rules with their condition text and a red `firing` badge; a toolbar
   bell (`bell` / `bell.badge`) opens it, and the recorded-run hook
   `ZTOP_ALERTS_SNAPSHOT` renders the screen (plain VStack, same
   ImageRenderer limits). `ZTOP_ALERTS` seeds rules by host name:
   `name|host or *|kind|threshold|duration;…`.
4. **Recorded proof**: two seeded rules against two live TLS agents —
   `cpu hot` (any host, CPU above 5% for 10 s) fired on both hosts and
   shows one badge with the header counting distinct rules, then
   `host-b gone` (unreachable for 5 s) fired after the agent was
   killed: `docs/screenshots/m6-mac-alert-firing.png` and
   `m6-mac-alerts-two-firing.png` (loopback + fake names only).

## Consequences

- Threshold kinds read live samples only: a stale host's last sample
  is never evaluated, which avoids alerting on old data.
- The firing count in the UI is per distinct rule; per-host firings
  remain separate for notifications and clear events.
- Durations are user-entered seconds; the demo uses short durations
  (10 s, 5 s) so a recorded run can observe a fire. Nothing prevents
  production-length durations.
- Local notifications are proven as far as the recorded environment
  allows: the posting path is exercised only for an authorized user,
  which a recorded run never is (no dialog can be answered); the
  in-app state is the recorded proof and the engine tests carry the
  timing semantics.
