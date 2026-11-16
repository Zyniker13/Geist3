# Decision 0052: the process list in the app

Date: 2026-11-15
Milestone: M6, batch 13b
Status: Accepted

## Context

The agents already serve `/v1/processes` (the latest sample's process
rows) and `POST /v1/control` (a plan of pids plus one action), and the
TUI already drives the same Rust `control` module. The app showed
neither: a fleet monitor that cannot look at or act on a process list
misses a core piece of `htop` parity (`docs/parity.md`, "Process list:
search, sort and, where allowed, signals").

Three constraints shaped the design:

- Control is dangerous and off by default (decision 0042): an agent
  started without `--allow-control` refuses plans, and a token paired
  from such an agent may only read. The client cannot ask "may I
  control?" — there is no capability endpoint — so the UI must learn
  about a refusal from the refusal itself.
- macOS and Linux number several signals differently (STOP 17 vs 19,
  CONT 19 vs 18, TSTP 18 vs 20). A client that sends numbers from its
  own platform's table would stop a process when it meant to continue
  one. The agent therefore answers `GET /v1/control` with its own
  platform's catalog, and the client must use those numbers.
- Everything committed from this machine is scrubbed or synthetic:
  a real process list (names, usernames) must never appear in a
  screenshot.

## Decision

- The detail page gains a Processes section fed by a dedicated 5 s
  loop (`HostDetailView.processLoop`), separate from the 10 s history
  loop: the table changes faster than the charts care about, and a
  failed process fetch only blanks the table when nothing has ever
  arrived.
- The pure rules live in ZTopKit (`ProcessTable`): the search matches
  a case-insensitive substring of name or user plus a pid whose
  decimal digits start with the query (`42` finds pid 4242); sorting
  offers cpu/memory/pid/name/user and is stable with a pid-ascending
  tie-break that holds in BOTH directions, so equal-key rows never
  jump when the sort flips.
- Signals are sent only by the target's catalog (`GET /v1/control`),
  read once per screen and reused. Without a catalog — an agent older
  than the endpoint, or a read failure — the menu offers only TERM
  (15) and KILL (9), the two numbers identical on every platform the
  app serves; guessing a numbered STOP/CONT would not be safe.
- Renice is sent as the TUI's delta (`+10` nicer, `−5` more CPU), not
  an absolute nice.
- SIGKILL asks for confirmation (it is uncatchable); every other
  action runs straight from the row menu. Refusals and per-pid
  failures surface as an alert carrying the agent's own wording
  (`AgentError.refused`), matching the protocol's 403 body.
- The recorded-run snapshot renders the search box as a drawn field
  (`staticSearch`): ImageRenderer cannot draw `TextField` and paints
  the unsupported-view banner instead (the same ImageRenderer limit
  decision 0046 recorded for `List` and `ProgressView`). Menus hide
  their indicator chevrons so the static rows read cleanly.
- Screenshots use `ZTOP_PROCESSES_DEMO=1`: the snapshot hook swaps
  the live rows for synthetic ones (`builder`/`renderer`/… owned by
  `alice`/`bob`/`carol`), so the committed capture never carries this
  machine's real process list.
- `GET /v1/control` answers to any known token (read rights are
  enough): a read-only client can still learn the numbering, which
  the refusal flow then names in its message.

## Consequences

- The app can watch and, where the operator allowed it, act on
  processes on any paired host, with the target's own signal
  numbering — closing the parity item "Process list: search, sort
  and, where allowed, signals".
- The end-to-end control path (pair → catalog → plan → real signal)
  is exercised over pinned TLS in a ZTopKit live test that stops,
  resumes and terminates a process the test owns.
- The `Process`/`ProcessIo` models gained public inits and the kit's
  version namespace was renamed `ZTopKitVersion`: a type named like
  its module shadows the module name in Swift and made every
  Foundation-`Process` collision worse.
- Older agents (before this endpoint) degrade to TERM/KILL only,
  which is honest rather than wrong.
