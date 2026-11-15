# 0036: The agent's live stream — WebSocket fan-out

## Context

DESIGN.md's protocol has a WebSocket stream of samples next to the
HTTP routes of decision 0035. The stream must never slow the sampler:
sampling is the product, serving is best effort.

## Decision

- The WebSocket route is `/v1/stream`. On connect it sends the latest
  sample once, then one text message per new sample, each in the same
  `{"protocol": 1, ...}` envelope as the HTTP routes.
- Fan-out is a `tokio::sync::broadcast` channel with a queue of 16.
  The sampler thread pushes into the ring and into the channel; it
  never blocks on a client.
- A client that falls behind until the queue overflows is closed with
  a close frame. A slow viewer reconnects and resumes with the latest
  sample; it does not hold the sampler back. (The TUI/app client
  reconnects with backoff — the client side lands with `connect`.)
- The `ws` feature is enabled on the workspace's axum 0.8 dependency
  (one line in `[workspace.dependencies]`; the crates' dependency
  declarations stay `{ workspace = true }`).
- The full server-and-client round trip is exercised when `ztop
  connect` lands: the Rust client speaks the same protocol, and the
  integration test connects both halves in-process. Until then the
  stream's logic is tested at the `tick` level (ring plus channel).

## Consequences

- One producer, many consumers, no per-client backpressure: the agent
  cost budget (under 1% of a core) is independent of viewer count.
- axum's `ws` is mature and the only new surface; no new crate is
  involved beyond enabling the feature flag.
