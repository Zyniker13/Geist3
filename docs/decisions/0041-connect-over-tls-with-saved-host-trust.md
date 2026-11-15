# 0041 — Connecting to a TLS agent: pin, pair, and remember the host

Date: 2026-11-15

## Context

Batch 8e gave the agent TLS (`ztop agent --tls`, decision 0039); batch
8f gives the client the matching side of `ztop connect`. The client
trusts nothing but the pin the operator read off the agent's startup
line — no system trust store, no CA, no TOFU on first connect. A
machine-in-the-middle without the agent's private key cannot forge the
certificate; a wrong pin must fail the handshake, not fall back.

## Decision

`ztop connect target --tls [--pin SHA256:...] [--code ...]`:

- **A pin is always required** — given on the command line, or loaded
  from the host's saved trust. Plain `connect target` without `--tls`
  stays unencrypted loopback/SSH-tunnel usage as before.
- **First connect pairs**: `--tls --pin ... --code ...` runs
  `pair_with` (a single `POST /v1/pair` inside a pinned TLS 1.3
  session, 3 s total), then saves `(pin, token)` for that host and
  enters the TUI already authenticated.
- **Later connects reuse**: `--tls --pin ...` (no code) loads the
  saved token; `--tls` alone loads the saved pin and token. The code
  is single-use and never stored.
- **Trust lives per host** in `state_dir()/hosts/<name>.json`, 0600.
  The name keeps only `[A-Za-z0-9._-]` of the target, so `10.0.0.1`
  and `10.0.0.2:9` cannot collide with each other or escape the
  directory; the file also stores the verbatim target and refuses a
  mismatch, so a colon-form and bare-form alias of the same host are
  separate entries rather than a silent swap.
- **401 while connecting** reads "a paired token (401): pair with
  --code" — the one hint the operator needs, since the token expired
  or the host was re-paired.
- A one-byte wrong pin produces a handshake failure naming the pin
  mismatch, tested end to end against a live TLS agent.

## Consequences

- Connect is still observation-only; acting on rows over the protocol
  comes later (decision 0003's rights work).
- The pin travels on the command line and lands in shell history; the
  saved-trust file exists precisely so the pin is typed once per host.
  Printing the QR pairing screen (app milestone) will remove even
  that.
- ztop-core now depends on rustls (ring), and `tui`/`hub` depend on
  core, so every crate reaches ring: all Linux-target clippies ride
  on CI (decision 0039's note updated), and the aarch64 Linux target
  is linted there with `cross` (decision 0043).
