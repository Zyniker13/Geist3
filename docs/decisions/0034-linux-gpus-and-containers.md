# Decision 0034: Linux GPUs and container awareness

Date: 2026-11-15
Status: Accepted
Milestone: M3 (7ae)

## Context

DESIGN.md requires "GPU on Linux (NVIDIA through NVML **loaded at runtime**,
AMD through sysfs), and container/cgroup awareness on Linux". The Linux CI
runner has no GPU, and the macOS host cannot run the Linux collector, so the
collector code must be verifiable by tests against recorded sysfs shapes plus
CI compilation, and must never guess a value it could not read.

## Decision

**GPU data model.** `Sample.gpus: Vec<Gpu>` (serde default, so recorded
captures replay without it). `Gpu` carries `name: String` and six `Metric`
fields — utilization, memory_used, memory_total, watts, temperature,
fan_percent — so every value the driver does not report renders as `-`
instead of a fake zero.

**NVIDIA through NVML, dlopen'd at runtime.** No NVML build dependency or
SDK include: the collector `dlopen`s the first library it finds among the
usual names (`libnvidia-ml.so.1`, `.so`, …) with `RTLD_NOW`, resolves all
symbols it needs in one pass, and treats the library as absent if any symbol
is missing (all-or-nothing, no half-working GPU rows). A failed load is
remembered in a `OnceLock`, so a machine without the driver does not retry
`dlopen` on every refresh. All NVML calls are per-call-site pointer-checked
Option fn pointers. Fan speed uses the two-argument `nvmlDeviceGetFanSpeed`
form and is clamped to 0..=100 percent.

**AMD through sysfs.** `/sys/class/drm/card*/device` supplies
`gpu_busy_percent`, VRAM usage via `mem_info_vram_used` /
`mem_info_vram_total`, power via the first hwmon `power1_average`
(microwatts), temperature via `temp1_input` (millidegrees), fan via
`pwm1` (0..=255 mapped to percent, unavailable when the card has no pwm).
Absent files leave that metric unavailable. The AMD half compiles
on all platforms so its tests run on the macOS host; only the NVML half is
`#[cfg(target_os = "linux")]`.

**Replays stay GPU-free.** Recorded captures construct `gpus: Vec::new()`:
the capture allowlist does not read sysfs GPU files, and fabricating GPU rows
from a capture would be dishonest. macOS keeps its integrated GPU on the SoC
screen (decision 0033) and reports no discrete cards.

**TUI.** A `GPUs` screen on `g` (tab strip: main, silicon, gpus, disks, net,
io, temps). Columns: GPU (name, truncated at 16), util %, memory used/total,
power W, temp °C, fan %; `-` where a metric is unavailable; the screen
explains an empty list instead of drawing an empty table.

**Container awareness.** The Linux collector reads `/proc/<pid>/cgroup` once
per process (thread rows inherit their group's value, no re-read per task).
`detect_container` takes the path after the last colon (cgroup paths cannot
contain colons) and recognizes exactly six layouts: docker
(`/docker/<hex>` or `docker-<hex>.scope`), podman (`libpod-<hex>.scope` or
`/podman/<id>`), containerd (`cri-containerd-<hex>.scope`), cri-o
(`crio-<hex>.scope`), LXC (`/lxc/<name>`), systemd-nspawn
(`machine-<name>.scope`). Everything else — systemd service scopes, user
sessions, the root cgroup — yields `None`: a process that is not in a
container stays blank rather than guessed. The id is the first 12 hex
characters (the `docker ps` short id); LXC and nspawn keep their name as the
id. `Process.container: Option<Container>` (serde default) carries
`{ id, runtime }`; the optional `CTR` table column (140+ columns, F2
toggle, part of the 0032 columns machinery) shows `runtime id`. The capture
allowlist gains `/proc/[0-9]*/cgroup`.

## Consequences

- A Linux machine without NVIDIA drivers or AMD cards shows the empty-GPU
  explanation; nothing degrades or guesses.
- The NVML ABI is pinned to the symbols resolved at load: new NVML
  functions are opt-in additions, and an all-or-nothing mismatch just hides
  NVIDIA cards rather than crashing a refresh.
- CI cannot exercise a real GPU or container; the sysfs half is verified by
  tests against recorded directory shapes on any host, the NVML half only by
  compilation plus the live-manual path. Recorded captures continue to show
  no GPU rows.
- Threads of a containerized process are labeled without extra reads.
