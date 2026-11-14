# 0004: Hub history — SQLite through sqlx

## Context

The hub keeps longer history than an agent's ring buffer and serves the same protocol as an agent. Storage must be zero-administration: a hub is something a user runs on their own Mac or a small Linux box, not a managed database server.

## Decision

- Store hub history in SQLite through `sqlx`. The database is a single file whose path is part of the hub's config; schema migrations are embedded SQL applied at startup.

## Consequences

- One-file storage: trivial to back up, move or delete; no second service to install or run.
- sqlx is async-native on tokio, so the hub's storage and its axum server share one runtime.
- The dependency itself is added in M6 when history actually lands; the choice is recorded now because the stack table names it, so M6 inherits it rather than re-deciding.
