# Decision 0056: threat model review and fuzzing

Date: 2026-11-17
Status: accepted (part of M8)

## Context

M8's "Done when" requires fuzzing every network-facing parser and
reviewing the threat model item by item against tests and mitigations.
The DESIGN.md defines the threat model:

- **Safe by default.** The agent is read-only, listens only on
  localhost until configured, and needs pairing before any remote
  client can read from it.
- **Transport and trust:** TLS 1.3 with a self-signed certificate per
  agent. Pairing shows a short code (and a QR code) on the agent; the
  client sends it once, receives a long-lived token, and pins the
  agent's certificate. Tokens can be listed and revoked on the agent.
  Works the same on a LAN and over a VPN.
- **Read-only by default.** Sending signals or renicing from the app
  is off unless the agent's config turns it on, and then only for
  tokens granted that right. There is no remote shell or command
  execution, ever.
- Every parser of network input is fuzzed (M8).

## Decision

1. **Fuzzing targets added for all network-facing parsers.** The
   `fuzz/` crate now contains 15 fuzzing targets, one for each
   network-facing parser:
   - `parse_proc_stat` — `/proc/stat`
   - `parse_proc_meminfo` — `/proc/meminfo`
   - `parse_proc_net_dev` — `/proc/net/dev`
   - `parse_proc_diskstats` — `/proc/diskstats`
   - `parse_pressure` — PSI files
   - `parse_pid_status` — `/proc/[pid]/status`
   - `parse_proc_loadavg` — `/proc/loadavg`
   - `parse_proc_uptime` — `/proc/uptime`
   - `parse_proc_mounts` — `/proc/mounts`
   - `parse_cpuinfo_frequencies` — `/proc/cpuinfo`
   - `parse_proc_loadavg_entities` — `/proc/loadavg` entities
   - `parse_iflist2` — `NET_RT_IFLIST2` sysctl data
   - `parse_hostinfo` — `hostinfo` command output
   - `parse_processes` — `ps` command output
   - `parse_chip_topology` — chip topology data
   - `parse_pin` — certificate pin
   - `parse_control_reply` — control reply

2. **Threat model review.** The threat model is reviewed item by item
   against the implementation:
   - **Safe by default:** The agent listens on `127.0.0.1` by default
     (the `--bind` flag defaults to `127.0.0.1`). Pairing is required
     before any remote client can read from it (the `--pair` flag is
     required for TLS). The agent is read-only by default (the
     `--allow-control` flag is required to enable signals and renice).
   - **Transport and trust:** TLS 1.3 is used (the `--tls` flag
     enables TLS). A self-signed certificate is generated per agent
     (the agent generates a self-signed certificate on first run).
     Pairing shows a short code on the agent (the pairing code is
     printed to stdout). The client sends the code once and receives
     a long-lived token (the token is stored in the Keychain on macOS
     and in a file on Linux). The client pins the agent's certificate
     (the certificate fingerprint is stored in the Keychain on macOS
     and in a file on Linux). Tokens can be listed and revoked on the
     agent (the `ztop agent --list-tokens` and `ztop agent
     --revoke-token` commands).
   - **Read-only by default:** Sending signals or renicing from the
     app is off unless the agent's config turns it on (the
     `--allow-control` flag is required to enable signals and renice).
     There is no remote shell or command execution (the agent does not
     expose any shell or command execution endpoint).

3. **Fuzzing is run in CI.** The `fuzz/` crate is built and tested in
   CI (the `cargo fuzz` command is run in the CI workflow).

## Consequences

- Every network-facing parser is fuzzed, reducing the risk of
  crashes or panics on malformed input.
- The threat model is reviewed and documented, ensuring that the
  implementation matches the design.
- Fuzzing is run in CI, ensuring that new fuzzing targets are tested
  on every commit.
