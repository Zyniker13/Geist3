# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-17

### Added

- **Terminal monitor** (`ztop`): a full-screen TUI with header meters (per-core CPU bars, memory and swap bars, load average, uptime, task and thread counts, and battery where present), a process table with every column, mode and action in the parity list (tree view, sorting by any column, filter, incremental search, follow a process, tag and act on several, send any signal, renice, user filter, thread display, I/O columns, and setup screens for meters, columns and colors, saved to a config file), and more than both `htop` and `asitop`: disk and network I/O panels, per-disk usage, temperatures and fans, GPU on Linux (NVIDIA through NVML loaded at runtime, AMD through sysfs), and container/cgroup awareness on Linux.
- **Apple Silicon view** (asitop parity): E-cluster and P-cluster frequency and utilization, per-core frequency, GPU frequency and utilization, ANE power, CPU, GPU and package power with history charts and peak values, memory and swap use, and thermal pressure.
- **Agent** (`ztop agent`): serves metrics to the app or a hub over a versioned protocol (a WebSocket stream of samples and an HTTP endpoint for a snapshot, the process list and history), with TLS 1.3, pairing, and token-based authentication.
- **Hub** (`ztop hub`): collects from many agents and serves them as one, with longer history in SQLite.
- **zTop app**: a universal SwiftUI app for iPad and Mac with a fleet overview, a detail view for any one machine, alerts, and the Apple Silicon view for Macs.
- **ZTopKit**: a Swift package with the protocol client, models and pairing, used by the app and its tests.
- **Packaging**: Homebrew formula, .deb packages for amd64 and arm64 with a systemd unit and a dedicated user, and a man page.
- **Fuzzing**: 15 fuzzing targets for all network-facing parsers.
- **Accessibility**: VoiceOver labels for cards, charts, and meters.

### Changed

- The agent's own cost is part of the product: at a 1-second interval, the agent uses under 1% of one core and under 30 MB resident memory on a typical host.

### Security

- The agent is read-only by default, listens only on localhost until configured, and needs pairing before any remote client can read from it.
- TLS 1.3 with a self-signed certificate per agent.
- Pairing shows a short code (and a QR code) on the agent; the client sends it once, receives a long-lived token, and pins the agent's certificate.
- Tokens can be listed and revoked on the agent.
- Sending signals or renicing from the app is off unless the agent's config turns it on, and then only for tokens granted that right.
- There is no remote shell or command execution, ever.
