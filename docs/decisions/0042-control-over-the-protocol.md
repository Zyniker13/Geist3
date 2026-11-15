# Decision 0042: Control over the protocol

## Context

The TUI can send signals and renice processes, but only through the
local collector: the event loop called `control::execute` directly, so
`ztop connect` (which drives the same TUI with a `RemoteCollector`)
either ran actions against the wrong machine or had to refuse them
outright. ROADMAP M4 promises "signals and renice over the protocol
only when the agent config allows it and the token has the right".
Watching is safe; acting on another machine's processes is not, so the
action path needs its own gate stack instead of riding on the read
token.

## Decision

- `Control` and `Plan` gain `serde::Serialize`/`Deserialize`; the wire
  body is exactly the plan the TUI already builds. One route,
  `POST /v1/control`, carries every action; per-action routes would
  multiply for no benefit.
- The `Collector` trait gains `execute_plan(plan)` whose default is
  `control::execute(plan)` — the local behavior, unchanged. The remote
  collector overrides it to POST the plan; collectors that do not hold
  this machine's live pids (replay sources) must override it to
  refuse; `ztop replay` renders one frame and never builds a
  collector, so fixtures cannot act.
- Three gates on the agent, in order: (1) the handler itself refuses
  unless the agent serves TLS — a plaintext agent never executes
  control, whatever its flags, because the channel is unauthenticated
  loopback-to-network; (2) `ztop agent --allow-control`, off by
  default, must be set; (3) the bearer token must carry the `control`
  right. Rights live on the token record (`rights: Vec<String>` with a
  serde default of `["read"]`, so tokens saved before this decision
  stay readable and read-only); a pairing code confers the rights the
  agent was started with, so a code from a control-allowing agent
  pairs a control token, and a later pairing from the same agent is
  the way a read-only token gains control.
- `Control::Signal(0)` is the permission probe: `kill(pid, 0)` sends
  nothing. The plan probe every UI keypress makes before opening a
  menu is therefore safe even against a refusing agent, and the agent
  answers it per-pid like any other action.
- The agent caps one request at 256 pids and answers every pid: ok or
  the OS's error text (e.g. ESRCH/EPERM), never silent. The client
  maps the reply back onto the plan's pids; a pid the agent did not
  answer for reads as a failure, so counts always add up.
- The remote client refuses control without TLS ("the action would
  cross an unauthenticated channel") and without a token; a 401 reads
  "pair with --code" like a read, and a 403 carries the agent's reason.

## Consequences

- `ztop connect` gains real control keys when the remote agent allows
  it; the status line reads identically for local and remote plans.
- Existing saved tokens keep working for reads and cannot control;
  re-pairing is required once per agent that wants control rights.
- The agent's control path runs `control::execute` synchronously in
  the request handler; the pid cap keeps a flood of signals from
  tying up the runtime for long.
- The Linux-only tweaks (mentioned in `Control`) inherit all of this
  when they arrive: one gate stack, one reply shape.
