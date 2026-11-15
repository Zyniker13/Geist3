# zTop services

Both service files run the agent as a **read-only** long-lived service:
TLS with pairing, no `--allow-control`, so nothing paired through them
can signal or renice. To allow control, add `--allow-control` to
`ProgramArguments` (launchd) or `ExecStart` (systemd) and restart the
service; tokens paired before the change keep their read-only rights —
pair again afterwards to hold the `control` right (decision 0042).

Both point at `/usr/local/bin/ztop`; change it to wherever your
package manager installed the binary.

## macOS (launchd, per user)

    cp launchd/com.ztop.agent.plist ~/Library/LaunchAgents/
    launchctl load ~/Library/LaunchAgents/com.ztop.agent.plist

Stop: `launchctl unload ~/Library/LaunchAgents/com.ztop.agent.plist`.

## Linux (systemd, per user)

    mkdir -p ~/.config/systemd/user
    cp systemd/ztop-agent.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now ztop-agent

Stop: `systemctl --user stop ztop-agent`.

The agent binds 127.0.0.1 only; TLS + pairing is what lets a client on
another machine talk to it. First start prints the pairing code and the
TLS fingerprint to the service's log (`/tmp/ztop-agent.*` under
launchd, `journalctl --user -u ztop-agent` under systemd).
