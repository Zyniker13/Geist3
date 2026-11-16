# Decision 0047: Keychain tokens and reconnection in the app

## Context

The M5 client keeps a paired token per host. The first app shell
stored tokens in the same JSON file as the host records, in plain
text inside Application Support; the ROADMAP's M5 item lists Keychain
storage and reconnection as ZTopKit responsibilities.

## Decision

- ZTopKit gains `TokenStore`: one Keychain generic password per host
  under the service `dev.ztop.token`, account `host:port`, accessible
  after first unlock. Save replaces, load returns nil when absent,
  delete is idempotent. The same Security calls cover iOS and macOS,
  so the single multiplatform target needs no platform split.
- `HostStore` writes its `hosts.json` with tokens blanked and stores
  every token through `TokenStore`; loading migrates any plain-text
  token it still finds into the Keychain on first run. Forgetting a
  host deletes its token. The `ZTOP_SNAPSHOT`/`ZTOP_PAIR` hooks and
  the overview behavior are unchanged.
- Reconnection is the poller's own loop plus the agent's persistent
  token store: `HostStore` retries every host every 2 seconds, and a
  restarted agent keeps the paired token valid because `tokens.json`
  (hashed tokens, decision 0038) survives the restart. Proven live in
  a new ZTopKit test: pair against a real agent, kill it (reads
  fail), restart it on the same port without re-pairing, and read
  again with the same token.

## Consequences

- A lost Keychain entry reads as an unpaired host: the card offers
  pairing again, and no token is ever stored unencrypted.
- The restart test runs its agent with a per-test temporary `HOME`
  (the agent's state dir follows `$HOME`), so concurrent Swift
  Testing suites never share a token store and nothing lands in the
  user's real state dir. Proven necessary: two live agents sharing
  the real state dir clobbered each other's `tokens.json` on pair,
  which broke a restart test before the isolation.
- macOS's data-protection keychain can answer a fresh `SecItemAdd`
  with `errSecDuplicateItem` right after its own lookup said the item
  was absent; `save` falls back to `SecItemUpdate` in that case, and
  the token tests run serialized to keep their keychain use orderly.
- Keychain errors surface only as a missing token — the app never
  writes tokens to disk as a fallback.
