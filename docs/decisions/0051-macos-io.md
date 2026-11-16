# 0051 — macOS disk and network collectors

Date: 2026-11-15
Milestone: M6 (13a)

## Context

The macOS collector filled CPU, memory, load, battery, temperatures,
power and processes but reported no disks and no network interfaces,
so the TUI's `d`/`n` screens and the app's disk and network detail
sections had nothing to show on macOS. The Linux collector defines the
shape: lifetime counters per device/interface, rates as deltas between
two live samples, first sample without rates (decision 0018).

## Decision

1. **New module `macos_io`** in `ztop-core`, compiled only on macOS.
   `read_disks()` and `read_net()` fill the existing `Disk` and
   `NetIf` model rows; `macos_live`'s sample calls them after
   `sample_from_parts` and turns counter deltas into rates with the
   same per-name rules as Linux (a first sample or a counter that went
   backwards reports no rate, per counter, not per device).
2. **Mounts** come from `getmntinfo(3)` — the `statfs` view `df`
   shows. One mount per BSD device: slices fold onto their container
   (`disk1s5` → `disk1`, `disk1s1s1` folds once; a whole device keeps
   its name) with the shortest mount point as the representative
   mount. Used is the capacity not available to unprivileged users
   (`f_blocks − f_bavail`), matching the Linux collector's
   definition. Network mounts have no BSD device and are skipped.
3. **Disk IO counters** come from the IOKit registry. The counters
   live in an `IOBlockStorageDriver` entry's `Statistics` dictionary,
   but the BSD name lives on `IOMedia` nodes, so the walk starts at
   the medias and climbs at most eight parents in the IOService plane
   to the first ancestor carrying `Statistics`; every media of a
   driver sees the same driver-level counters, so folded names
   overwrite each other. `IORegistryEntryCreateCFProperties` did not
   surface `Statistics` on this system's entries — the targeted
   `IORegistryEntryCreateCFProperty` lookup is what works.
4. **Network counters** come from the route-control-list sysctl
   (`NET_RT_IFLIST2`), parsed from raw bytes with explicit offsets
   instead of an aligned struct so a fabricated dump tests the parser.
   The offsets were verified against the live sysctl with a C probe
   (`if_msghdr2` is 160 bytes: u16 length, u8 version 5, u8 type —
   `RTM_IFINFO2` is 0x12 —, u16 index at byte 12, `if_data64` at 32
   with packet counters at 56/72 and byte counters at 96/104); a
   first draft read the layout from memory and was wrong in every
   offset. Interface names come from `if_indextoname(3)`, injected as
   a closure; messages whose index resolves to nothing, and a
   truncated final message, are skipped.
5. **FFI discipline**: the module declares its own minimal externs and
   mirrors the exact signatures `macos_power` already declares for
   shared CoreFoundation functions — conflicting declarations of the
   same symbol link fine and segfault at call time with no output.
   `getmntinfo` takes the buffer pointer by address
   (`getmntinfo(&mut buf, …)`); passing a null pointer is a crash.

## Consequences

- The TUI's disk and network panels and the I/O meter line now have
  macOS data; the app's detail sections receive the same rows through
  the sample. First samples show no rates, exactly like Linux.
- Live tests cover the real paths unprivileged: mounts fold to one
  row per device with a plausible usage percent, every named device
  carries counters, loopback resolves with packet counters parsed
  from real bytes, and a two-sample interval yields non-negative
  byte rates. The pure parser and the fold rules are tested against
  fabricated data, so the Linux CI job exercises them too.
- Temperatures and fans remain the honest-unavailable set: the same
  `Sensors` source they came from before this change is untouched.
