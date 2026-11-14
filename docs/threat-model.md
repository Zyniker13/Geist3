# Threat model

zTop is a monitor. Its value depends on being trustworthy on the machines it
watches: it must not leak what it sees, and it must never become a foothold.

## Assets

- **Host data**: resource metrics and process tables. Process lists reveal
  user names and what runs on a machine; process command lines can contain
  secrets (this is accepted and documented below).
- **Credentials**: pairing tokens and the agent's TLS private key.
- **Integrity of the monitored host**: a monitor that can be turned into an
  execution channel is worse than no monitor.
- **Availability of the monitored host**: the agent's own cost is part of the
  product (budget in `DESIGN.md`, measured in M8).

## Trust boundaries

1. Network → agent (a LAN or VPN the agent listens on).
2. Network → hub.
3. Hub → agent (a hub is a client of its agents).
4. App (iPad or Mac) → agent or hub.
5. Local users on the monitored host → the agent process.

## Threats and mitigations

| Threat | Mitigation |
| --- | --- |
| A network observer reads metrics or tokens | TLS 1.3 for any non-loopback serving (M4). Until then the agent and hub bind to loopback only and refuse other addresses. Tokens travel in headers, never in URLs. |
| An impostor agent on the LAN collects clients | Clients pin the agent's self-signed certificate at pairing; hostnames are never trusted by themselves. |
| A stolen token reads a host indefinitely | Tokens are long-lived but listable and revocable on the agent; a token grants read only unless explicitly granted signal/renice rights. |
| A malicious client attacks the agent or uses it to run things | The agent is read-only by design — there is no command-execution endpoint to attack. All network parsers are typed serde payloads, fuzzed in M8; request and history-range limits are enforced. |
| Denial of service against the agent | Bounded ring-buffer history, no per-client threads, read paths served from memory. |
| A local unprivileged user misuses the agent | The agent runs as a normal user, reads only what that user may read, and marks the rest unavailable — never faked. Config and key files are owned by the agent user, mode 0600. |
| A malicious or vulnerable dependency | Dependencies only from crates.io and SPM, each with a decision record; `cargo deny` license and advisory checks in CI; GitHub Actions pinned to commit SHAs with read-only token permissions. |
| Private data leaks through the repository | Recorded fixtures use an allowlist of non-identifying inputs; screenshots and test data use fake values (`host-a`, `alice`); CI holds no credentials. |

## Explicit non-goals

- Defending against an attacker who already has root on the monitored host or
  the hub host, or physical access to them.
- Hiding metrics from someone who can already read the agent's local state.
- Hiding which machines run zTop: Bonjour advertises `_ztop._tcp` on the
  local network by design (M4), and can be left off.

## Residual risks accepted for 0.1.0

- The hub sees everything its agents see; whoever controls the hub is
  trusted with fleet data. Choose the hub host accordingly.
- Process command lines can contain secrets (`--password=…`). Showing them is
  part of `htop` parity and is available to local users and to paired
  tokens; it is not restricted further in 0.1.0.
- Until M4 the protocol ships without TLS, so loopback-only binding is the
  hard rule until then; the first non-loopback capability lands together
  with TLS and pairing, never before.
