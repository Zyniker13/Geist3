# 0048 — The hub: one process that polls the agents and serves the fleet

Date: 2026-11-15
Status: accepted

## Context

M6's first step is `ztop hub`: a background service that watches a set of
agents, keeps their samples so a client can look at the past, and answers
the same protocol the agents answer, so one client (the app, the TUI) can
watch many machines through one connection. Decisions 0003 (the hub is a
client of its agents and a server to its own clients) and 0004 (SQLite
over sqlx for the samples) already bound the big shape. The stub crate
existed but was empty; this decision records what the first real hub
implementation chose.

## Decision

**One crate, one process, two roles.** `ztop-hub` is both the poller and
the server. It holds the agent list, a `Store` (SQLite), and a status map
in `HubState`; one tokio task polls the agents, the axum router serves
clients, both through the same state.

**The hub is a client of its agents.** Polling builds a
`RemoteCollector` per agent — the same client code a `ztop` run uses —
one `spawn_blocking` task per agent so a slow or dead agent cannot stall
the others. The poll interval is the agent's own cadence (the constant
the agent serves and the collector uses); a failed poll is recorded, not
retried early.

**The hub is a server with one addition.** The routes are the agent's
(`/v1/health`, `/v1/pair`, `/v1/snapshot`, `/v1/history`, `/v1/tokens`)
with the agent's status codes, plus `/v1/hosts`, the fleet listing, and
one selector: every sample-taking route accepts `?host=NAME` to pick one
watched agent. A client talks to the hub exactly as to an agent, so
`AgentClient` and the TUI work unchanged; a fleet view is a new client
feature, not a new protocol.

**Pairing and tokens are the hub's own.** A client pairs with the hub,
not with every agent behind it: `/v1/pair` issues hub tokens from
`state_dir()/hub/tokens.json` via the agent's `auth` module verbatim,
and the hub's token routes manage only hub tokens. The hub's connection
to its agents is configured out of band in `agents.json`
(`{"agents":[{"name","target","pin"?,"token"?}]}`) — agent pins are
validated (the same 64-hex rule), agent tokens ride the config file.

**TLS and auth come from the agent verbatim.** The agent's
`serve_on_tls` was generalized into `serve_router_on_tls(listener,
config, router)`: the accept loop, handshake, and HTTP plumbing now
serve any router, and the agent's own `serve_on_tls` is a thin wrapper.
The hub's `serve` reuses it plus the agent's `enforce_auth` middleware,
so the handshake rules and the token check cannot drift between the two
services. The hub defaults to loopback; anything wider requires
`--tls`, and TLS implies token enforcement.

**Samples are stored verbatim.** One row per polled sample: `(host,
ts_ms, payload)` where payload is exactly the JSON the agent served.
Serving history is a copy of stored bytes, never a re-encode, so an
upstream schema change cannot corrupt old rows. Queries always go by
`(host, ts_ms)` — index `samples_host_ts`. A row whose payload no
longer parses is skipped on read, not fatal. `prune(ms)` deletes rows
older than the given age; the retention task runs on the poll loop.
In-memory stores (tests) cap the pool at one connection: separate
pooled connections each open their own empty in-memory database.

**The CLI.** `ztop hub --port 7101 --agents <json> --db <sqlite> --bind
127.0.0.1 [--pair] [--tls]`. Defaults live under `state_dir()/hub/`
(`agents.json`, `history.db`); a missing home directory is an error, not
a silent memory-only hub. `--pair` prints a pairing code (same shape as
the agent's). The agent's port is 7100; the hub's default is 7101 so a
hub and an agent can run on one machine.

## Consequences

- A client needs no new code to speak to a hub; the app and TUI gain a
  fleet view by pointing at one target.
- Old samples survive protocol evolution because payloads are never
  re-encoded.
- The TLS/auth code has one home; the hub cannot drift from the agent.
- The hub trusts `agents.json` for its agent credentials — tokens there
  are file-permission protected like the trust store, and `--tls` mode
  still keeps them out of the wire.
- Polling one bad agent marks just that agent unreachable in
  `/v1/hosts`; the rest of the fleet keeps flowing.
