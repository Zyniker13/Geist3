# Design

zTop watches a mixed fleet of Macs and Linux machines. It has three parts that share one data model and one wire protocol.

| Part | What it is | Where it runs |
| --- | --- | --- |
| `ztop` | One Rust binary. With no arguments it is an interactive terminal monitor. `ztop agent` serves metrics to the app or a hub. `ztop hub` collects from many agents and serves them as one. | macOS (Homebrew) and Linux (apt) |
| zTop app | A universal SwiftUI app: a fleet overview, and a detail view for any one machine. | iPad and Mac |
| ZTopKit | A Swift package with the protocol client, models and pairing, used by the app and its tests. | iPad and Mac |

## Goals

- **Parity, then more.** The terminal monitor does at least everything `htop` does for processes and everything `asitop` does for Apple Silicon. [docs/parity.md](docs/parity.md) lists every feature, and an item is checked only when it works and a test or recorded check shows it.
- **One place for the whole fleet.** The app shows every machine at once and makes problems obvious without hunting: a host that is hot, full, swapping, throttled or gone.
- **Light on the machine it watches.** The agent's own cost is part of the product. Budget, at a 1-second interval: under 1% of one core and under 30 MB resident memory on a typical host. Measure both in M8.
- **No root needed.** On macOS, Apple Silicon power, frequency and GPU data come from IOReport and temperatures and fans from the SMC, which need no `sudo`, unlike `asitop`'s use of `powermetrics`. On Linux the agent runs as an unprivileged user and shows what it can; data that needs more (other users' per-process I/O) is marked unavailable, never faked.
- **Safe by default.** The agent is read-only, listens only on localhost until configured, and needs pairing before any remote client can read from it.

## The Terminal Monitor

A full-screen TUI (Rust, `ratatui` with `crossterm` is the expected choice; record it in a decision).

- **Header meters**, htop-style and configurable: per-core CPU bars (split by user, system, nice, I/O wait, steal where the OS reports them), memory and swap bars, load average, uptime, task and thread counts, and battery where present.
- **Apple Silicon view** (asitop parity), on its own screen and as optional header meters: E-cluster and P-cluster frequency and utilization, per-core frequency, GPU frequency and utilization, ANE power, CPU, GPU and package power with history charts and peak values, memory and swap use, and thermal pressure. Show the chip name and core counts as `asitop` does.
- **Process table** with every column, mode and action in the parity list: tree view, sorting by any column, filter, incremental search, follow a process, tag and act on several, send any signal, renice, user filter, thread display, I/O columns, and setup screens for meters, columns and colors, saved to a config file.
- **More than both**: disk and network I/O panels, per-disk usage, temperatures and fans, GPU on Linux (NVIDIA through NVML loaded at runtime, AMD through sysfs), and container/cgroup awareness on Linux.
- Mouse support, a colorblind-safe default theme plus monochrome, and correct behavior in an 80x24 terminal.

## Collectors

One `Collector` trait in the core crate, with one implementation per platform, each tested against recorded fixtures.

- **Linux:** `/proc` and `/sys` (CPU times, memory, swap, load, processes and threads, disks, network, hwmon temperatures and fans, power supply, cgroups, pressure stall information).
- **macOS:** `host_statistics64`, `sysctl` and `libproc` for CPU, memory and processes; IOKit for disks, network and battery; IOReport for Apple Silicon power and frequency residency; the SMC for temperatures and fans. Intel Macs get everything except the Apple Silicon view.
- Every metric carries its unit and whether it is available on this host, so the TUI and the app can say "not available" instead of showing zero.

## Agent, Hub and Protocol

- `ztop agent` samples on an interval (default 1 s), keeps a ring buffer of recent history (default 1 hour at full resolution plus 24 hours downsampled to 1 minute), and serves a versioned protocol: a WebSocket stream of samples and an HTTP endpoint for a snapshot, the process list and history.
- **Transport and trust:** TLS 1.3 with a self-signed certificate per agent. Pairing shows a short code (and a QR code) on the agent; the client sends it once, receives a long-lived token, and pins the agent's certificate. Tokens can be listed and revoked on the agent. Works the same on a LAN and over a VPN.
- **Discovery:** Bonjour (`_ztop._tcp`) on the local network, plus manual host entry.
- **Read-only by default.** Sending signals or renicing from the app is off unless the agent's config turns it on, and then only for tokens granted that right. There is no remote shell or command execution, ever.
- `ztop hub` connects to many agents, keeps longer history in SQLite, and serves the same protocol, so a client talks to a hub exactly as it talks to an agent. On a Mac the app can install and run the hub as a login item, so an iPad on the road needs to reach one machine. Whether the hub is the Rust binary or part of the Mac app is an M6 decision; the Rust binary is the default because it runs on Linux too.
- Every parser of network input is fuzzed (M8).

## The App

- **Fleet overview:** a grid of hosts, each a compact card with CPU, memory, GPU, power and temperature at a glance, sorted or grouped as the user likes; stale or unreachable hosts are obvious.
- **Host detail:** live charts (Swift Charts) for every metric, the Apple Silicon view for Macs, a searchable, sortable process list, and disks, network, temperatures and fans.
- **Alerts:** per-host or fleet-wide thresholds (for example CPU above 90% for 5 minutes, disk above 90%, host unreachable), shown in the app and as local notifications.
- **Platforms:** iPad (including split view and Stage Manager sizes) and Mac, from one SwiftUI target. iPhone may come later; nothing should prevent it.
- Tokens live in the Keychain. No accounts, no cloud service, no analytics.

## Packaging

- **Homebrew:** a formula that builds or installs `ztop` and defines a `brew services` launchd service for the agent.
- **apt:** `.deb` packages for amd64 and arm64 (`cargo-deb` is the expected tool) with a systemd unit that runs the agent as a dedicated unprivileged `ztop` user.
- Publishing to a tap and an apt repository, and signing, are release steps for the maintainer; the repository holds everything needed to build and check the packages.
- A man page for `ztop`, and `ztop --help` that matches it.
