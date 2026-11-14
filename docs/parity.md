# Parity Checklist

Check an item only when it works and a test or a recorded check shows it. Add the test or check's name after the item. Items marked (Linux) or (macOS) apply on that platform only.

## htop: Header and Meters

- [ ] Per-core CPU bars, split by user, system, nice, I/O wait, IRQ, steal and guest where reported
- [ ] Average CPU meter; CPU frequency and temperature in meters where available
- [ ] Memory meter (used, buffers, shared, cache, compressed on macOS) and swap meter
- [ ] Load average, uptime, task, thread, running and kernel-thread counts
- [ ] Battery, clock, hostname and system meters
- [ ] Pressure stall (PSI) meters (Linux); disk I/O and network I/O meters
- [ ] Meter styles: bar, text, graph and LED; configurable columns of meters
- [ ] Screen tabs, including a dedicated I/O screen

## htop: Process Table

- [ ] Every common column: PID, PPID, user, priority, nice, VIRT, RES, SHR, state, CPU%, MEM%, TIME+, command, threads, start time, processor
- [ ] I/O columns: read and write rates and totals (Linux; where permitted)
- [ ] Sort by any column, invert sort, and the M, P and T shortcuts
- [ ] Tree view with collapse and expand
- [ ] Incremental search (F3) and filter (F4)
- [ ] Follow a process (F)
- [ ] Tag processes (Space), tag children (c), untag all (U), and act on all tagged
- [ ] Send any signal through a signal menu (F9 / k)
- [ ] Renice up and down (F7 / F8)
- [ ] I/O priority (i, Linux) and CPU affinity (a, Linux)
- [ ] User filter (u) and PID filter (`-p`)
- [ ] Show or hide userland and kernel threads (H, K), and program path (p)
- [ ] Process environment (e), open files (l) and syscall trace (s) where the OS allows
- [ ] Highlight new and dying processes, and large numbers
- [ ] Pause updates (Z) and redraw (Ctrl-L)
- [ ] Read-only mode (`--readonly`)

## htop: Setup and Options

- [ ] Setup screen (F2) for meters, display options, colors and columns
- [ ] Config file saved and reloaded
- [ ] Color schemes, including monochrome; `--no-color`
- [ ] Mouse support: click to select, sort and use the function bar
- [ ] Command-line options: delay (`-d`), user (`-u`), PIDs (`-p`), sort key (`-s`), tree (`-t`)
- [ ] Help screen (F1) and a man page

## asitop: Apple Silicon (macOS)

- [ ] Chip name, and E-core and P-core counts
- [ ] E-cluster and P-cluster utilization and frequency
- [ ] Per-core utilization and frequency
- [ ] GPU utilization and frequency
- [ ] ANE power
- [ ] CPU, GPU and package power, with current, average and peak values
- [ ] Power history charts with a configurable averaging window
- [ ] Memory and swap use
- [ ] Thermal pressure
- [ ] Interval and color options
- [ ] All of the above without root

## Beyond Both

- [ ] Per-disk usage, and disk I/O panels
- [ ] Network interfaces with rates and totals
- [ ] Temperatures and fans
- [ ] Linux GPUs: NVIDIA through NVML, AMD through sysfs
- [ ] cgroup and container awareness (Linux)
- [ ] `ztop connect` shows a remote agent in the TUI

## Agent and Hub

- [ ] `ztop agent` with ring-buffer history
- [ ] TLS, pairing code and QR, pinned certificates, tokens with list and revoke
- [ ] Localhost-only until configured
- [ ] Bonjour discovery
- [ ] Signals and renice only when the config and the token allow
- [ ] `ztop hub` with SQLite history, serving the same protocol
- [ ] launchd and systemd services

## App

- [ ] Add a host by Bonjour or by hand, and pair
- [ ] Fleet overview with live cards; stale and unreachable hosts obvious
- [ ] Host detail with charts for every metric
- [ ] Apple Silicon view for Macs
- [ ] Process list: search, sort and, where allowed, signals
- [ ] Disks, network, temperatures and fans
- [ ] Alerts with thresholds and local notifications
- [ ] Mac app installs and runs the hub as a login item; iPad works through the hub
- [ ] iPad split view and Stage Manager sizes; Mac window sizes
- [ ] VoiceOver, Dynamic Type and contrast pass

## Packaging

- [ ] Homebrew formula with a `brew services` agent
- [ ] `.deb` for amd64 and arm64 with a systemd unit and a dedicated user
- [ ] Install, upgrade and uninstall tested in CI on both
