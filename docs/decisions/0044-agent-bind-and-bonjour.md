# Decision 0044: agent bind address and Bonjour advertisement

## Context

M4's last open item is Bonjour: the agent must advertise itself so the
app can find it. The agent binds `127.0.0.1` only (decision 0003:
localhost-only until configured), so discovery is useless across the
fleet until the bind can be widened — and a bind wider than loopback
with no TLS would publish unauthenticated metrics to the network,
which no default may do.

## Decision

- `ztop agent` gains `--bind <IP>` (default `127.0.0.1`). A
  non-loopback bind is refused without `--tls` (`bind_rules`, tested):
  the same rule as the protocol, "TLS is the trust boundary".
- With TLS on, the agent advertises `_ztop._tcp` over Bonjour via the
  `mdns-sd` crate (0.21, from crates.io — this is the recorded
  dependency addition). The instance name is `ztop on <hostname>`;
  the TXT record carries `protocol=<PROTOCOL_VERSION>` so a browser
  can skip incompatible services. `--no-advertise` opts out.
- Registration failure is a stderr note, never a crash: a machine
  without multicast routes still serves its agents.
- The discovery name comes from `ztop_core::host::hostname()`, read
  the same way the collectors read it (`kern.hostname` on macOS,
  `/proc/sys/kernel/hostname` elsewhere).

## Consequences

- A LAN-visible agent is `ztop agent --bind 0.0.0.0 --tls`; a loopback
  agent is still advertised, which is what the Mac app needs on the
  same machine. The iPad over the network requires the wider bind.
- The advertisement lasts as long as the daemon handle; dropping it
  unregisters, so the service disappears with the agent.
- The register-and-browse test is `#[ignore]`d: CI containers do not
  promise multicast. It is recorded instead: on the development Mac,
  `ztop agent --tls --port 7156` followed by `dns-sd -B _ztop._tcp
  local.` listed the instance `ztop on <hostname>` (value scrubbed
  here under the fixture rules). The ignored test reproduces the same
  round trip where multicast works.
- This closes M4: pairing (0038), TLS and pins (0039), control
  (0042), services (9b), discovery (this decision).
