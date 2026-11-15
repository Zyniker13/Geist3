# 0038: Pairing and tokens on the agent

## Context

DESIGN.md: "needs pairing before any remote client can read from it",
"a short code on the agent; the client sends it once, receives a
long-lived token", "tokens can be listed and revoked on the agent".
TLS still lands later; the token machinery is testable over plain
loopback now, and enforcement switches on wherever TLS is on.

## Decision

- `ztop_core::paths::state_dir()` is the shared home for ztop's own
  files (macOS `~/Library/Application Support/ztop`, XDG elsewhere);
  the TUI's config path builds on it, the agent's token file lives
  beside it (`tokens.json`), and tests pass explicit inputs instead of
  mutating the environment (which races between test threads).
- Tokens are 256-bit random values (getrandom 0.3), shown once; only
  the SHA-256 (sha2 0.10) is kept — in memory keyed by the full hash,
  on disk as `hash` + an 8-hex `id` + label + creation time, written
  0600 (unix). A stolen tokens file yields no reusable token.
- `POST /v1/pair {"code"}` trades the agent's six-character,
  unambiguous, single-use, five-minute code for the token. A new
  `--pair` starts one; the code lives in the serving process, so
  `ztop agent --pair` prints it from that process.
- `GET /v1/tokens` lists, `DELETE /v1/tokens/{id}` revokes; both are
  authed routes. A revoked token is refused immediately.
- A middleware enforces bearer tokens on every `/v1` route except
  `/healthz` and `/v1/pair` when the agent's `enforce_auth` is set.
  Plain loopback serving keeps it off until TLS arrives (decision
  0003), at which point enforcement is mandatory wherever the socket
  is not loopback.
- New dependencies: sha2 and getrandom, both small, standard,
  maintained; thiserror joins the agent (already a workspace dep).

## Consequences

- The token store survives agent restarts; tokens never expire until
  revoked (a fleet tool should not re-pair every reboot).
- Pairing is capped at one pending code; a second `--pair` replaces
  the first, so a leaked printed code can be invalidated by issuing
  another.
- The six-character code over loopback-only HTTP is acceptable while
  enforcement is off; with TLS, brute-force protection stays the TTL
  plus single-use semantics (an attacker needs the code within five
  minutes and network reach, which pairing exists to grant).
