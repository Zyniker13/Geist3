# Decision 0045: the ZTopKit protocol client

## Context

M5 starts the app side: ZTopKit is the Swift package with the
protocol client, models and pairing (ROADMAP). The wire shapes are
fixed by the Rust side: `{"protocol": 1, "sample": {...}}` snapshots,
flattened history envelopes, `POST /v1/pair` with the code, bearer
tokens, and pins over TLS (decisions 0035–0041).

## Decision

- The model is mirrored struct-for-struct in
  `swift/ZTopKit/Sources/ZTopKit/Models.swift` with `Codable` structs.
  A shared `JSONDecoder` uses `.convertFromSnakeCase`, so Rust's
  snake_case keys map to Swift camelCase without per-field keys.
  Fields the agent always writes stay non-optional in Swift; only the
  genuine `Option` fields and the two optional groups (`pressure`,
  `apple_silicon`) decode as `Optional`, and unknown fields are
  ignored so an agent can add fields first.
- TLS pinning rides `URLSession` with a `PinTrustDelegate`: the leaf
  certificate's SHA-256 (CryptoKit) is compared to the pin's hex part,
  case-insensitively; on a match the trust is presented as its own
  credential (the pin is the trust anchor, as the Rust client pins),
  on a mismatch the challenge is cancelled. `parsePin` canonicalizes
  `SHA256:<64 hex>`.
- `AgentClient` is one endpoint's async client: `snapshot()`,
  `history(seconds:)` and static `pair(endpoint:code:)`; 401 maps to
  `needsPairing`, 403 to `badCode`, and a protocol-version field is
  checked against the kit's version where the envelope carries one.
- Tests prove it against a real agent the tests spawn
  (`target/debug/ztop agent --tls --pair --no-advertise` on a random
  port, binary located from the package path or `$ZTOP_BIN`): pair
  with the printed code, read a pinned snapshot and history, meet a
  wrong pin as a handshake failure, and map an unpaired 401 and a bad
  code honestly. Wire-shape decoding is additionally pinned by a
  hand-built JSON covering every struct (fake values only).

## Consequences

- check.sh's Rust stages build `target/debug/ztop` before the Swift
  stages run, so the live tests find the binary in CI and locally.
- The overview polls `snapshot()`; the WebSocket stream stays for the
  M6 detail views, so M5 needs no extra client state machine.
- Keychain storage, reconnection and discovery build on this client in
  the next M5 batches.
- Fixed on the way: the 8f e2e test's "wrong pin" was built by
  appending "00" to a 62-hex-char prefix, which reproduces the real
  pin whenever the fingerprint ends in "00" — a 1-in-256 flake that
  did fire in CI (437c45c). The wrong pin now flips the first hex
  character, which always differs.
