# 0039: TLS on the agent — self-signed material and hash pins

## Context

Decision 0003 picked rustls and pinned certificates in principle.
The parity line bundles TLS, pairing, pinned certificates and token
management; pairing and tokens landed in 0038. This decision wires
the transport: `ztop agent --tls`.

## Decision

- New dependencies, all standard and maintained: `rustls` and
  `tokio-rustls` with the `ring` backend (chosen over the
  `aws-lc-rs` default so Linux cross-compilation stays C-light),
  `rcgen` (ring backend) to
  create the self-signed certificate, `time` for its validity dates,
  `rustls-pki-types` (its PemObject API reads the PEM material), and
  `hyper-util`'s connection auto-builder to serve TLS
  connections with WebSocket upgrades intact. `rustls-pemfile` was
  considered and rejected: it is deprecated/unmaintained.
- Cross-compilation note: `ring` ships C and assembly, so the
  Linux-target clippy for the agent and `ztop` bins cannot run on
  this Mac (no Linux C toolchain); those two crates' Linux checks
  ride on CI, and the ring-free crates (`core`, `tui`, `hub`) keep
  being clippy-checked for both Linux targets locally.
- On the first `--tls` start the agent creates
  `agent-cert.pem`/`agent-key.pem` (key 0600) in `state_dir()` with
  CN `ztop-agent`, SANs `localhost` and `127.0.0.1`, TLS 1.3, and a
  ten-year validity: the certificate is pinned by clients, so a
  short life would break every client's pin for no benefit. The
  fingerprint printed at startup is `SHA256:` + hex of the leaf
  certificate's DER; a client verifies exactly that.
- TLS flips `enforce_auth` on: plain loopback stays tokenless,
  anything encrypted requires a paired token (0038). This is the
  split trust boundary until a configurable non-loopback bind
  arrives with the agent config.
- The integration test serves TLS on an ephemeral loopback port and
  connects with a client whose only trust is the pin: right pin →
  `/healthz` 200 and `/v1/snapshot` 401 (no token yet); a one-byte
  wrong pin kills the handshake. A second load of the same material
  yields the identical fingerprint.

## Consequences

- Rotation = delete the two files and restart; every client must
  re-pin and re-pair, which is the correct blast radius for a lost
  key.
- Pinned certificates and tokens are now covered on the protocol;
  the QR code on the pairing screen is app-side and stays with the
  App milestones.
