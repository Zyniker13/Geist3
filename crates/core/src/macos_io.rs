// SPDX-License-Identifier: MIT OR Apache-2.0
//! Disk and network interface collectors for the live macOS host.
//!
//! Sources, all readable without root (decision 0009):
//! - Mounts and capacity: `getmntinfo(3)`, the same `statfs` view the
//!   `df` tool shows. Total is `f_blocks * f_frsize`, used is the
//!   capacity not available to unprivileged users
//!   (`f_blocks - f_bavail`), matching the Linux collector's definition.
//! - Disk IO counters: the IOKit registry's `IOBlockStorageDriver`
//!   entries, whose `Statistics` dictionary carries the lifetime bytes
//!   read and written per BSD device. APFS mounts several slices of one
//!   container (`disk1s1`, `disk1s5`), and the kernel counts IO per
//!   container, so a mount's slice name (`disk1s5`) is folded onto its
//!   device (`disk1`): one [`Disk`] per device, the mount being the
//!   slice's shortest mount point (usually `/`).
//! - Network counters: the route-control-list sysctl
//!   (`NET_RT_IFLIST2`), one `if_msghdr2` per interface carrying the
//!   lifetime byte and packet counters of `if_data64`. Interface names
//!   come from `if_indextoname`, injected as a closure so the parser
//!   stays a pure, testable function.

use std::collections::HashMap;

use crate::model::{Disk, NetIf};

/// Reads every mounted filesystem as one [`Disk`] per BSD device.
///
/// Mounts whose device has no BSD name (network mounts, `localhost:/`)
/// are skipped: the IO counters would be unavailable and the TUI's I/O
/// line cannot rate them. Counters stay 0 when the IOKit registry offers
/// nothing for the device.
pub(crate) fn read_disks() -> Vec<Disk> {
    let counters = io_disk_counters();
    let mut disks = dedupe_by_device(statfs_mounts());
    for disk in &mut disks {
        if let Some(&(read, write)) = counters.get(&disk.name) {
            disk.read_bytes = read;
            disk.write_bytes = write;
        }
    }
    disks
}

/// Reads every interface the kernel reports as one [`NetIf`].
///
/// The list stays complete — loopback included — exactly like the Linux
/// collector's `/proc/net/dev` view; interfaces the kernel names are
/// resolved through `if_indextoname`.
pub(crate) fn read_net() -> Vec<NetIf> {
    let raw = iflist2_bytes();
    parse_iflist2(&raw, if_indextoname)
}

// ── statfs mounts ────────────────────────────────────────────────────

/// One `statfs` row reduced to the fields the model needs.
#[derive(Debug)]
struct MountRow {
    name: String,
    mount: String,
    total_bytes: u64,
    used_bytes: u64,
}

/// One mount per BSD device: the slice with the shortest mount point.
///
/// `disk1s1` and `disk1s5` both fold to device `disk1`, carrying the
/// shortest mount (the root slice's `/`) as the representative mount.
/// A mount whose device has no BSD name (network mounts) is skipped.
fn dedupe_by_device(mounts: Vec<MountRow>) -> Vec<Disk> {
    let mut best: HashMap<String, MountRow> = HashMap::new();
    for row in mounts {
        // A BSD device lives under /dev; anything else (a network mount
        // like `localhost:/export`) has no device to fold onto.
        let Some(device) = row.name.strip_prefix("/dev/").and_then(device_name) else {
            continue;
        };
        match best.get_mut(&device) {
            Some(entry) if row.mount.len() >= entry.mount.len() => {}
            Some(entry) => *entry = row,
            None => {
                best.insert(device, row);
            }
        }
    }
    let mut disks: Vec<Disk> = best
        .into_iter()
        .map(|(device, row)| Disk {
            name: device,
            read_bytes: 0,
            write_bytes: 0,
            mount: row.mount,
            total_bytes: row.total_bytes,
            used_bytes: row.used_bytes,
            usage_pct: if row.total_bytes > 0 {
                (row.used_bytes as f64 / row.total_bytes as f64 * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            },
            read_rate: None,
            write_rate: None,
        })
        .collect();
    disks.sort_by(|a, b| a.name.cmp(&b.name));
    disks
}

/// `disk1s5` folds to `disk1`; a device with no slice suffix stays whole.
///
/// The kernel names slices with an `sN` suffix after the device; a name
/// that ends in `s<digits>` with digits before the `s` loses the suffix
/// (`disk1s1s1` folds once). `disk5` (a whole device, no slice) keeps
/// its name.
fn device_name(from: &str) -> Option<String> {
    let base = from.rsplit('/').next()?;
    let mut stem = base;
    while let Some(pos) = stem.rfind('s') {
        let digits_after =
            pos + 1 < stem.len() && stem[pos + 1..].chars().all(|c| c.is_ascii_digit());
        if pos == 0 || !digits_after {
            break;
        }
        stem = &stem[..pos];
    }
    if stem.is_empty() {
        None
    } else {
        Some(stem.to_string())
    }
}

fn statfs_mounts() -> Vec<MountRow> {
    let mut rows = Vec::new();
    unsafe {
        // getmntinfo(3) fills its own buffer and reports it through the
        // out parameter; passing null would write through a null pointer.
        let mut buf: *mut libc::statfs = std::ptr::null_mut();
        let count = libc::getmntinfo(&mut buf, libc::MNT_WAIT);
        if count <= 0 || buf.is_null() {
            return rows;
        }
        for index in 0..count as isize {
            let st = &*buf.offset(index);
            let name = cstr(&st.f_mntfromname);
            let mount = cstr(&st.f_mntonname);
            if name.is_empty() {
                continue;
            }
            let frsize = st.f_bsize;
            rows.push(MountRow {
                name,
                mount,
                total_bytes: st.f_blocks * frsize as u64,
                used_bytes: st.f_blocks.saturating_sub(st.f_bavail) * frsize as u64,
            });
        }
    }
    rows
}

fn cstr(field: &[std::os::raw::c_char; 1024]) -> String {
    let bytes: Vec<u8> = field
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

// ── IOKit disk counters ──────────────────────────────────────────────

mod ffi {
    pub type CFTypeRef = *const std::os::raw::c_void;
    pub type CFStringRef = CFTypeRef;
    pub type CFAllocatorRef = CFTypeRef;
    pub type CFTypeID = u64;

    unsafe extern "C" {
        pub fn CFStringCreateWithCString(
            alloc: CFAllocatorRef,
            cstr: *const std::os::raw::c_char,
            encoding: u32,
        ) -> CFStringRef;
        pub fn CFDictionaryGetValue(dict: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        pub fn CFGetTypeID(obj: CFTypeRef) -> CFTypeID;
        pub fn CFStringGetTypeID() -> CFTypeID;
        pub fn CFNumberGetValue(
            number: CFTypeRef,
            the_type: i32,
            value_ptr: *mut std::os::raw::c_void,
        ) -> bool;
        pub fn CFStringGetCString(
            string: CFStringRef,
            buffer: *mut std::os::raw::c_char,
            size: isize,
            encoding: u32,
        ) -> u8;
        pub fn CFRelease(obj: CFTypeRef);

        pub fn IOServiceGetMatchingServices(
            main_port: u32,
            matching: CFTypeRef,
            iterator: *mut u32,
        ) -> i32;
        pub fn IOIteratorNext(iterator: u32) -> u32;
        pub fn IOObjectRelease(object: u32) -> i32;
        pub fn IORegistryEntryGetParentEntry(
            entry: u32,
            plane: *const std::os::raw::c_char,
            parent: *mut u32,
        ) -> i32;
        pub fn IORegistryEntryCreateCFProperty(
            entry: u32,
            key: CFStringRef,
            allocator: CFAllocatorRef,
            options: u32,
        ) -> CFTypeRef;
    }

    pub const K_CF_NUMBER_SINT64: i32 = 4;
    pub const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    pub const K_IO_SERVICE_PLANE: &[u8] = c"IOService".to_bytes_with_nul();
}

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const std::os::raw::c_char) -> *mut std::os::raw::c_void;
}

/// A `CFString` built for a key lookup; released on drop.
struct Key(ffi::CFStringRef);

impl Key {
    fn new(text: &str) -> Key {
        let c = std::ffi::CString::new(text).unwrap_or_default();
        Key(unsafe {
            ffi::CFStringCreateWithCString(
                std::ptr::null(),
                c.as_ptr(),
                ffi::K_CF_STRING_ENCODING_UTF8,
            )
        })
    }
}

impl Drop for Key {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { ffi::CFRelease(self.0) };
        }
    }
}

/// Lifetime `(read, write)` bytes per BSD device from the IOKit registry.
///
/// The counters live in the `Statistics` dictionary of an
/// `IOBlockStorageDriver` entry, but the BSD name lives on `IOMedia`
/// nodes, so the walk starts at the medias and climbs the IOService
/// plane to the first ancestor carrying `Statistics`. Every media of a
/// driver reports the same driver-level counters, so each name folds
/// through `device_name` onto its container and identical entries
/// overwrite each other.
fn io_disk_counters() -> HashMap<String, (u64, u64)> {
    let mut out = HashMap::new();
    unsafe {
        let matching = IOServiceMatching(c"IOMedia".as_ptr());
        if matching.is_null() {
            return out;
        }
        let mut iterator: u32 = 0;
        if ffi::IOServiceGetMatchingServices(0, matching, &mut iterator) != 0 {
            return out;
        }
        loop {
            let media = ffi::IOIteratorNext(iterator);
            if media == 0 {
                break;
            }
            let name = ffi::IORegistryEntryCreateCFProperty(
                media,
                Key::new("BSD Name").0,
                std::ptr::null(),
                0,
            );
            if !name.is_null() {
                if let Some(device) = string_of(name) {
                    if let Some((read, write)) = ancestor_statistics(media) {
                        out.insert(device_name(&device).unwrap_or(device), (read, write));
                    }
                }
                ffi::CFRelease(name);
            }
            ffi::IOObjectRelease(media);
        }
        ffi::IOObjectRelease(iterator);
    }
    out
}

/// Climbs at most eight parents to a `Statistics` dictionary and reads
/// its `(Bytes (Read), Bytes (Write))`; none found means no counters.
///
/// The caller owns the starting media; every climbed node is released
/// here before the function returns.
fn ancestor_statistics(media: u32) -> Option<(u64, u64)> {
    unsafe {
        let stats_key = Key::new("Statistics");
        let read_key = Key::new("Bytes (Read)");
        let write_key = Key::new("Bytes (Write)");
        let mut node = media;
        let mut found = None;
        for hop in 0..8 {
            let mut parent: u32 = 0;
            if ffi::IORegistryEntryGetParentEntry(
                node,
                ffi::K_IO_SERVICE_PLANE.as_ptr().cast(),
                &mut parent,
            ) != 0
            {
                break;
            }
            if hop > 0 {
                ffi::IOObjectRelease(node);
            }
            node = parent;
            let stats =
                ffi::IORegistryEntryCreateCFProperty(node, stats_key.0, std::ptr::null(), 0);
            if !stats.is_null() {
                let read = number_of(ffi::CFDictionaryGetValue(stats, read_key.0));
                let write = number_of(ffi::CFDictionaryGetValue(stats, write_key.0));
                ffi::CFRelease(stats);
                found = Some((read, write));
                break;
            }
        }
        if node != media {
            ffi::IOObjectRelease(node);
        }
        found
    }
}

/// Reads a `CFNumber` as a signed 64-bit value; anything else is 0.
fn number_of(value: ffi::CFTypeRef) -> u64 {
    if value.is_null() || unsafe { ffi::CFGetTypeID(value) == ffi::CFStringGetTypeID() } {
        return 0;
    }
    let mut out: i64 = 0;
    unsafe {
        if ffi::CFNumberGetValue(
            value,
            ffi::K_CF_NUMBER_SINT64,
            &mut out as *mut i64 as *mut std::os::raw::c_void,
        ) {
            return out.max(0) as u64;
        }
    }
    0
}

/// Reads a `CFString` as UTF-8; anything else is absent.
fn string_of(value: ffi::CFTypeRef) -> Option<String> {
    if value.is_null() || unsafe { ffi::CFGetTypeID(value) != ffi::CFStringGetTypeID() } {
        return None;
    }
    let mut buf = [0 as std::os::raw::c_char; 256];
    unsafe {
        if ffi::CFStringGetCString(
            value,
            buf.as_mut_ptr(),
            buf.len() as isize,
            ffi::K_CF_STRING_ENCODING_UTF8,
        ) == 0
        {
            return None;
        }
    }
    let bytes: Vec<u8> = buf
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// ── network interfaces ───────────────────────────────────────────────

/// `NET_RT_IFLIST2` dump of the route control list, raw bytes.
fn iflist2_bytes() -> Vec<u8> {
    let mut mib: [libc::c_int; 6] = [libc::CTL_NET, libc::PF_ROUTE, 0, 0, libc::NET_RT_IFLIST2, 0];
    let mut size: libc::size_t = 0;
    unsafe {
        if libc::sysctl(
            mib.as_mut_ptr(),
            6,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return Vec::new();
        }
        let mut buf = vec![0u8; size];
        let mut len = size;
        if libc::sysctl(
            mib.as_mut_ptr(),
            6,
            buf.as_mut_ptr() as *mut libc::c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return Vec::new();
        }
        buf.truncate(len);
        buf
    }
}

/// One `if_msghdr2` message's counter set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IfCounters {
    pub index: u32,
    pub rx_bytes: u64,
    pub rx_packets: u64,
    pub tx_bytes: u64,
    pub tx_packets: u64,
}

/// Parses the raw `NET_RT_IFLIST2` dump into per-interface entries.
///
/// `name_of` resolves an interface index to its kernel name (`lo0`);
/// messages whose index resolves to nothing are skipped, as are the
/// non-interface messages and any bytes after a truncated final message.
/// The parser is pure so a fabricated byte dump tests it without
/// hardware.
pub fn parse_iflist2(data: &[u8], name_of: impl Fn(u32) -> Option<String>) -> Vec<NetIf> {
    let mut out = Vec::new();
    let mut rest = data;
    while rest.len() >= 4 {
        // Every route message starts with a u16 length in host order.
        let len = u16::from_ne_bytes([rest[0], rest[1]]) as usize;
        if len < 4 || len > rest.len() {
            break;
        }
        let (message, tail) = rest.split_at(len);
        rest = tail;
        // Byte 3 is the message type; RTM_IFINFO2 is 0x12.
        if message[3] != 0x12 {
            continue;
        }
        let Some(counters) = if_msghdr2_counters(message) else {
            continue;
        };
        let Some(name) = name_of(counters.index) else {
            continue;
        };
        out.push(NetIf {
            name,
            rx_bytes: counters.rx_bytes,
            rx_packets: counters.rx_packets,
            tx_bytes: counters.tx_bytes,
            tx_packets: counters.tx_packets,
            rx_rate: None,
            tx_rate: None,
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Extracts the `if_data64` counters of one `if_msghdr2` message.
///
/// Layout verified against the live sysctl with a C probe on arm64
/// macOS: `u16 msglen`, `u8 version`, `u8 type`, `u16 addrs`, pad,
/// `i32 flags`, `u16 index`, four `i32` send fields, then the
/// 128-byte `if_data64` at byte 32 — its packet counters at +24/+40
/// and byte counters at +64/+72, i.e. absolute 56/72/96/104. Explicit
/// byte offsets keep the parser pure and testable against a fabricated
/// dump; 112 bytes is the minimum a counter-bearing message can have.
fn if_msghdr2_counters(message: &[u8]) -> Option<IfCounters> {
    if message.len() < 112 {
        return None;
    }
    let index = u16::from_ne_bytes(message[12..14].try_into().ok()?) as u32;
    let word = |at: usize| -> Option<u64> {
        let bytes = message.get(at..at + 8)?;
        Some(u64::from_ne_bytes(bytes.try_into().ok()?))
    };
    Some(IfCounters {
        index,
        rx_bytes: word(96)?,
        rx_packets: word(56)?,
        tx_bytes: word(104)?,
        tx_packets: word(72)?,
    })
}

/// `if_indextoname(3)`, the parser's live name resolver.
fn if_indextoname(index: u32) -> Option<String> {
    let mut buf = [0 as std::os::raw::c_char; libc::IF_NAMESIZE];
    unsafe {
        if libc::if_indextoname(index, buf.as_mut_ptr()).is_null() {
            return None;
        }
    }
    let bytes: Vec<u8> = buf
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// ── rates ────────────────────────────────────────────────────────────

/// Per-name `(first, second)` byte rates over the interval.
///
/// A name the previous sample did not carry (a disk or interface that
/// appeared) has no interval to rate over and gets no rate. A counter
/// that went backwards (a device re-created) clamps to no rate, but
/// independently: one clamped direction does not hide the other.
pub fn byte_rates(
    prev: &HashMap<String, (u64, u64)>,
    current: &HashMap<String, (u64, u64)>,
    secs: f64,
) -> Vec<(String, Option<f64>, Option<f64>)> {
    let mut out = Vec::new();
    for (name, &(cur_first, cur_second)) in current {
        let Some(&(old_first, old_second)) = prev.get(name) else {
            continue;
        };
        let first = if secs > 0.0 && cur_first >= old_first {
            Some((cur_first - old_first) as f64 / secs)
        } else {
            None
        };
        let second = if secs > 0.0 && cur_second >= old_second {
            Some((cur_second - old_second) as f64 / secs)
        } else {
            None
        };
        out.push((name.clone(), first, second));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(index: u32) -> Option<String> {
        match index {
            1 => Some("lo0".into()),
            7 => Some("en0".into()),
            _ => None,
        }
    }

    /// An `RTM_IFINFO2` message in the layout the live sysctl produces:
    /// 160 bytes total, version 5, type 0x12, a u16 interface index at
    /// byte 12, and the `if_data64` u64 counters at 56/72/96/104.
    fn ifmsg(index: u32, rx: u64, rxp: u64, tx: u64, txp: u64) -> Vec<u8> {
        let mut m = vec![0u8; 160];
        m[0..2].copy_from_slice(&(160u16).to_ne_bytes());
        m[2] = 5; // route message version
        m[3] = 0x12; // RTM_IFINFO2
        m[12..14].copy_from_slice(&((index as u16).to_ne_bytes()));
        m[56..64].copy_from_slice(&rxp.to_ne_bytes()); // ifi_ipackets
        m[72..80].copy_from_slice(&txp.to_ne_bytes()); // ifi_opackets
        m[96..104].copy_from_slice(&rx.to_ne_bytes()); // ifi_ibytes
        m[104..112].copy_from_slice(&tx.to_ne_bytes()); // ifi_obytes
        m
    }

    #[test]
    fn iflist2_parses_interface_messages_and_skips_others() {
        let mut data = ifmsg(1, 100, 10, 200, 20);
        data.extend(ifmsg(7, 5_000, 500, 4_000, 400));
        // A route message (type 0x01) of the right length is skipped.
        let mut other = vec![0u8; 48];
        other[0..2].copy_from_slice(&(48u16).to_ne_bytes());
        other[3] = 0x01;
        data.extend(other);
        let parsed = parse_iflist2(&data, names);
        assert_eq!(parsed.len(), 2, "the route message is not an interface");
        assert_eq!(parsed[0].name, "en0");
        assert_eq!(parsed[0].rx_bytes, 5_000);
        assert_eq!(parsed[0].tx_packets, 400);
        assert_eq!(parsed[1].name, "lo0");
        assert_eq!(parsed[1].rx_bytes, 100);
        assert!(parsed[1].rx_rate.is_none(), "the parser fills no rates");
    }

    #[test]
    fn iflist2_truncated_and_unresolvable_are_skipped() {
        // A message whose index resolves to no name is skipped, and a
        // final message shorter than its declared length stops the walk.
        let mut data = ifmsg(99, 9, 9, 9, 9);
        let mut last = ifmsg(1, 1, 2, 3, 4);
        last.pop();
        data.extend(last);
        assert!(parse_iflist2(&data, names).is_empty());
    }

    #[test]
    fn device_name_folds_slices_and_keeps_whole_devices() {
        assert_eq!(device_name("/dev/disk1s5"), Some("disk1".into()));
        assert_eq!(device_name("/dev/disk5"), Some("disk5".into()));
        assert_eq!(device_name("/dev/disk3s1s1"), Some("disk3".into()));
        assert_eq!(device_name(""), None);
    }

    #[test]
    fn dedupe_keeps_the_shortest_mount_per_device() {
        let disks = dedupe_by_device(vec![
            MountRow {
                name: "/dev/disk1s1".into(),
                mount: "/System/Volumes/Preboot".into(),
                total_bytes: 100,
                used_bytes: 10,
            },
            MountRow {
                name: "/dev/disk1s5".into(),
                mount: "/".into(),
                total_bytes: 100,
                used_bytes: 60,
            },
            MountRow {
                name: "localhost:/export".into(),
                mount: "/net".into(),
                total_bytes: 1,
                used_bytes: 0,
            },
        ]);
        assert_eq!(disks.len(), 1, "one device; the network mount is skipped");
        assert_eq!(disks[0].name, "disk1");
        assert_eq!(disks[0].mount, "/");
        assert!((disks[0].usage_pct - 60.0).abs() < 1e-9);
    }

    #[test]
    fn byte_rates_rate_known_names_and_skip_new_or_rewound_ones() {
        let mut prev = HashMap::new();
        prev.insert("disk0".to_string(), (1_000u64, 2_000u64));
        prev.insert("disk1".to_string(), (10u64, 10u64));
        let mut current = HashMap::new();
        current.insert("disk0".to_string(), (3_000u64, 2_500u64));
        current.insert("disk1".to_string(), (5u64, 20u64)); // read rewound
        current.insert("disk2".to_string(), (7u64, 7u64)); // brand new
        let rates = byte_rates(&prev, &current, 2.0);
        assert_eq!(rates.len(), 2, "disk2 has no interval to rate over");
        let disk0 = rates.iter().find(|(name, ..)| name == "disk0").unwrap();
        assert_eq!(disk0.1, Some(1_000.0));
        assert_eq!(disk0.2, Some(250.0));
        let disk1 = rates.iter().find(|(name, ..)| name == "disk1").unwrap();
        assert_eq!(disk1.1, None, "a rewound counter has no rate");
        assert_eq!(disk1.2, Some(5.0));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn live_disks_carry_mounts_within_universal_bounds() {
        let disks = read_disks();
        assert!(!disks.is_empty(), "a booted macOS host mounts volumes");
        assert!(
            disks.iter().any(|d| d.mount == "/"),
            "the root mount folds to a device"
        );
        for disk in &disks {
            assert!(!disk.name.is_empty());
            assert!(disk.total_bytes > 0);
            assert!(disk.used_bytes <= disk.total_bytes);
            assert!((0.0..=100.0).contains(&disk.usage_pct));
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn live_net_lists_loopback_with_counters() {
        let interfaces = read_net();
        let loopback = interfaces
            .iter()
            .find(|n| n.name == "lo0")
            .expect("loopback exists on every macOS host");
        // The packet counter proves the fields really were parsed, not
        // left zeroed: loopback has always sent packets by now.
        assert!(loopback.tx_packets > 0, "loopback has sent packets");
    }
}
