# 0035: The agent's versioned protocol, ring history and sampler

## Context

DESIGN.md gives the agent a versioned protocol (a WebSocket stream plus
HTTP endpoints for a snapshot, the process list and history), a sampling
interval of one second and a ring of recent history. Decision 0003
pinned tokio, axum and rustls. The M4 agent work starts with the HTTP
half; the WebSocket stream, TLS pairing and control actions follow.

## Decision

- The protocol version is 1 and every payload under `/v1` travels in an
  envelope `{"protocol": 1, ...}`; clients check `protocol` before
  trusting anything else.
- Routes: `GET /v1/snapshot` (the latest sample), `GET /v1/processes`
  (its process list with a count) and `GET /v1/history?seconds=N`
  (samples from the last N seconds, oldest first; no parameter means
  the whole ring). `/healthz` stays as the liveness check.
- History is one full-resolution ring of 3,600 samples (one hour at the
  one-second default), capped by count with the oldest dropped. The
  downsampled 24-hour tier arrives with the hub's SQLite persistence,
  where aggregation belongs.
- A dedicated OS thread owns the collector and samples on a fixed
  interval; the collector is constructed inside that thread and never
  moves, because the macOS collector holds IOKit/CF objects the
  compiler cannot prove `Send`. A failing tick is skipped, not fatal.
- Before the first sample lands, `/v1/*` answer 503 ("no sample yet")
  instead of an empty 200: an empty payload and "the sampler has not
  produced one" mean different things.
- The agent crate depends on `serde` (derive, already the workspace
  choice) and `ztop-core` by path; `Sample` serializes as-is, so the
  wire format is the fixture format the repo already tests.

## Consequences

- The same envelope and routes serve the hub later, so a client cannot
  tell them apart — the M4 requirement that hub and agent speak one
  protocol.
- The ring's memory cost scales with the process count; the DESIGN
  budget (under 30 MB resident) is measured in M8 and, if it misses,
  the ring depth or a downsampled tier is the lever, not the protocol.
- `ztop agent --port` keeps loopback-only binding; a non-loopback
  address waits for the TLS pairing work, when serving wide is safe.
