// SPDX-License-Identifier: MIT OR Apache-2.0

//! Per-field checks of the Linux parsers against the recorded fixtures.
//!
//! The fixtures under `tests/fixtures/` are verbatim captures of real
//! Linux hosts with per-process names scrubbed (decision 0007). Each
//! expected value is re-derived from the raw `/proc` text inside the
//! fixture itself, so the checks hold for any re-recorded capture while
//! still catching parser drift: a wrong column or unit shows up as a
//! mismatch against the test's independent parse. These tests run on
//! every machine, not just Linux.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use ztop_core::linux::{FixtureSampleError, sample_from_fixture};
use ztop_core::model::{CpuTimes, Metric, Unit};

const ARCHES: [&str; 2] = ["linux-x86_64", "linux-aarch64"];

fn fixture_dir(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

/// Reads one recorded `/proc` entry from the fixture's `data` directory.
fn data(dir: &Path, entry: &str) -> String {
    std::fs::read_to_string(dir.join("data").join(entry)).unwrap()
}

/// The tick columns of one `cpuN` line of `/proc/stat`, with its core
/// index. Returns `None` for the aggregate `cpu` line, which has no
/// digits after the prefix.
fn cpu_line_ticks(line: &str) -> Option<(usize, Vec<f64>)> {
    let rest = line.strip_prefix("cpu")?;
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    let index: usize = rest[..digits].parse().ok()?;
    let ticks = rest[digits..]
        .split_whitespace()
        .map(|tick| tick.parse::<f64>().ok())
        .collect::<Option<Vec<f64>>>()?;
    Some((index, ticks))
}

/// [`CpuTimes`] from the nine tick columns: the kernel's `USER_HZ` is a
/// fixed 100 ticks per second, so seconds are ticks divided by 100.
fn times_from_ticks(ticks: &[f64]) -> CpuTimes {
    let seconds = |column: usize| ticks[column] / 100.0;
    CpuTimes {
        user: seconds(0),
        nice: seconds(1),
        system: seconds(2),
        idle: seconds(3),
        io_wait: seconds(4),
        irq: seconds(5),
        soft_irq: seconds(6),
        steal: seconds(7),
        guest: seconds(8),
    }
}

/// One numeric `meminfo` value, in KiB as recorded.
fn meminfo_kib(meminfo: &str, key: &str) -> u64 {
    for line in meminfo.lines() {
        if let Some((field, value)) = line.split_once(':') {
            if field.trim() == key {
                let kib = value
                    .split_whitespace()
                    .next()
                    .unwrap_or_else(|| panic!("meminfo: {key} has no value"));
                return kib.parse().unwrap_or_else(|_| panic!("meminfo: {key}"));
            }
        }
    }
    panic!("meminfo is missing {key}");
}

/// The trimmed value of one `key:` line of a `status` file.
fn status_field<'a>(status: &'a str, key: &str) -> Option<&'a str> {
    status.lines().find_map(|line| {
        let (field, value) = line.split_once(':')?;
        (field.trim() == key).then_some(value.trim())
    })
}

/// A `status` memory value like `   25700 kB`, converted to bytes.
fn kib_field(value: &str) -> u64 {
    value
        .split_whitespace()
        .next()
        .unwrap_or_else(|| panic!("status memory value has no number"))
        .parse::<u64>()
        .unwrap_or_else(|_| panic!("status memory value is not a number"))
        * 1024
}

/// The first three fields of `/proc/loadavg`.
fn load_values(text: &str) -> [f64; 3] {
    let mut fields = text.split_whitespace();
    [
        fields.next().unwrap().parse().unwrap(),
        fields.next().unwrap().parse().unwrap(),
        fields.next().unwrap().parse().unwrap(),
    ]
}

/// One `diskstats` line as the documented layout defines it: the device
/// name in the third field and counters after it, of which the third
/// and seventh are the 512-byte sectors read and written. Lines that do
/// not follow the layout are skipped, exactly like the collector does.
fn disk_line(line: &str) -> Option<(String, u64, u64)> {
    let mut fields = line.split_whitespace();
    let name = fields.nth(2)?.to_string();
    let counters = fields
        .map(|field| field.parse::<u64>().ok())
        .collect::<Option<Vec<u64>>>()?;
    if counters.len() < 7 {
        return None;
    }
    Some((name, counters[2], counters[6]))
}

/// One `net/dev` data line (the two header lines must already be
/// removed): interface name, then receive bytes, receive packets, send
/// bytes and send packets. Malformed lines are skipped, like the
/// collector does.
fn net_line(line: &str) -> Option<(String, u64, u64, u64, u64)> {
    let (name, counters) = line.split_once(':')?;
    let counters: Vec<u64> = counters
        .split_whitespace()
        .map_while(|field| field.parse().ok())
        .collect();
    if counters.len() < 10 {
        return None;
    }
    Some((
        name.trim().to_string(),
        counters[0],
        counters[1],
        counters[8],
        counters[9],
    ))
}

#[test]
fn both_fixtures_build_a_full_sample() {
    for name in ARCHES {
        let dir = fixture_dir(name);
        let sample = sample_from_fixture(&dir).unwrap_or_else(|err| panic!("{name}: {err}"));
        assert_eq!(sample.hostname, name, "hostname comes from the directory");
        assert_eq!(sample.cpu.cores.len(), 4, "{name}");
        // A single capture has no interval to measure over.
        assert_eq!(sample.cpu.busy_percent, vec![0.0; 4], "{name}");
        assert_eq!(sample.processes.len(), 12, "{name}");
        assert!(
            sample.sensors.temps.is_empty(),
            "{name}: recorded runners have no hwmon"
        );
        assert!(sample.sensors.fans.is_empty(), "{name}");
        assert!(sample.sensors.battery.is_none(), "{name}");
    }
}

#[test]
fn samples_carry_the_recorded_time_and_host() {
    for name in ARCHES {
        let dir = fixture_dir(name);
        let sample = sample_from_fixture(&dir).unwrap();
        let manifest: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).unwrap())
                .unwrap();
        assert_eq!(sample.hostname, name);
        assert_eq!(
            sample.timestamp_ms,
            manifest["captured_at_unix"].as_u64().unwrap() * 1000
        );
    }
}

#[test]
fn core_times_fit_inside_the_machine_uptime() {
    // The aggregate `cpu` line does not necessarily equal the sum of the
    // per-core lines (kernel aggregate accounting differs), so the check
    // here is the physical one: no core can have accumulated more time
    // than the machine has been up.
    for name in ARCHES {
        let dir = fixture_dir(name);
        let sample = sample_from_fixture(&dir).unwrap();
        assert!(
            sample.uptime.available,
            "{name}: uptime should be available"
        );
        assert_eq!(sample.uptime.unit, Unit::Seconds);
        let uptime = sample.uptime.value;
        for (index, times) in sample.cpu.cores.iter().enumerate() {
            let total = times.busy() + times.idle;
            assert!(
                total <= uptime + 2.0,
                "{name}: core {index} shows {total} s but the machine has been up {uptime} s"
            );
        }
    }
}

#[test]
fn fields_match_the_recording_for_each_arch() {
    for name in ARCHES {
        let dir = fixture_dir(name);
        let sample = sample_from_fixture(&dir).unwrap();

        // CPU: every core's times re-derived from the raw tick columns.
        let stat = data(&dir, "proc-stat");
        let core_times: Vec<CpuTimes> = stat
            .lines()
            .filter_map(|line| cpu_line_ticks(line).map(|(_, ticks)| times_from_ticks(&ticks)))
            .collect();
        assert_eq!(sample.cpu.cores, core_times, "{name}: cpu times");

        // Memory, straight from `meminfo` in its recorded KiB.
        let meminfo = data(&dir, "proc-meminfo");
        let bytes = |key: &str| meminfo_kib(&meminfo, key) as f64 * 1024.0;
        let total = bytes("MemTotal");
        assert_eq!(
            sample.memory.total,
            Metric::available(total, Unit::Bytes),
            "{name}"
        );
        assert_eq!(
            sample.memory.used,
            Metric::available(total - bytes("MemAvailable"), Unit::Bytes),
            "{name}: used is total minus available"
        );
        assert_eq!(
            sample.memory.free,
            Metric::available(bytes("MemFree"), Unit::Bytes),
            "{name}"
        );
        assert_eq!(
            sample.memory.swap_total,
            Metric::available(bytes("SwapTotal"), Unit::Bytes),
            "{name}"
        );
        assert_eq!(
            sample.memory.swap_used,
            Metric::available(bytes("SwapTotal") - bytes("SwapFree"), Unit::Bytes),
            "{name}"
        );
        assert_eq!(
            sample.memory.compressed,
            Metric::unavailable(Unit::Bytes),
            "{name}: compressed memory is a macOS concept"
        );

        // Load and uptime, as recorded.
        assert_eq!(
            sample.load_avg,
            load_values(&data(&dir, "proc-loadavg")),
            "{name}"
        );
        let uptime: f64 = data(&dir, "proc-uptime")
            .split_whitespace()
            .next()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(
            sample.uptime,
            Metric::available(uptime, Unit::Seconds),
            "{name}"
        );

        // Disks: every well-formed `diskstats` line, sector counts in
        // 512-byte units.
        let diskstats = data(&dir, "proc-diskstats");
        let disks: Vec<(String, u64, u64)> = diskstats.lines().filter_map(disk_line).collect();
        assert_eq!(
            sample.disks.len(),
            disks.len(),
            "{name}: every well-formed diskstats line is a disk"
        );
        for (disk_name, read_sectors, write_sectors) in &disks {
            let disk = sample
                .disks
                .iter()
                .find(|disk| &disk.name == disk_name)
                .unwrap_or_else(|| panic!("{name}: disk {disk_name} missing"));
            assert_eq!(
                disk.read_bytes,
                read_sectors * 512,
                "{name}: {disk_name} reads"
            );
            assert_eq!(
                disk.write_bytes,
                write_sectors * 512,
                "{name}: {disk_name} writes"
            );
        }

        // Network: every well-formed `net/dev` line.
        let netdev = data(&dir, "proc-net-dev");
        let ifaces: Vec<(String, u64, u64, u64, u64)> =
            netdev.lines().skip(2).filter_map(net_line).collect();
        assert_eq!(
            sample.net.len(),
            ifaces.len(),
            "{name}: every well-formed net/dev line is an interface"
        );
        for (iface_name, rx_bytes, rx_packets, tx_bytes, tx_packets) in &ifaces {
            let iface = sample
                .net
                .iter()
                .find(|iface| &iface.name == iface_name)
                .unwrap_or_else(|| panic!("{name}: interface {iface_name} missing"));
            assert_eq!(iface.rx_bytes, *rx_bytes, "{name}: {iface_name}");
            assert_eq!(iface.rx_packets, *rx_packets, "{name}: {iface_name}");
            assert_eq!(iface.tx_bytes, *tx_bytes, "{name}: {iface_name}");
            assert_eq!(iface.tx_packets, *tx_packets, "{name}: {iface_name}");
        }

        // Process 1: the full row, re-derived from the recorded `status`.
        let status = data(&dir, "proc-1-status");
        let one = sample
            .processes
            .iter()
            .find(|process| process.pid == 1)
            .unwrap();
        // The scrubber names processes by their rank in pid order, so
        // pid 1's letter comes from where it sits among the recorded
        // pids (decision 0007).
        let mut pids: Vec<u32> = sample.processes.iter().map(|p| p.pid).collect();
        pids.sort_unstable();
        let rank = pids.iter().position(|pid| *pid == 1).unwrap();
        assert_eq!(
            one.name,
            format!("proc-{}-1", (b'a' + rank as u8) as char),
            "{name}: pid 1 carries its scrubbed name"
        );
        assert_eq!(
            one.state,
            status_field(&status, "State")
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap(),
            "{name}"
        );
        assert_eq!(
            one.parent,
            status_field(&status, "PPid").unwrap().parse::<u32>().ok(),
            "{name}"
        );
        assert_eq!(
            one.user,
            status_field(&status, "Uid")
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap(),
            "{name}: the user is the numeric uid"
        );
        assert_eq!(
            one.virtual_bytes,
            kib_field(status_field(&status, "VmSize").unwrap()),
            "{name}"
        );
        assert_eq!(
            one.resident_bytes,
            kib_field(status_field(&status, "VmRSS").unwrap()),
            "{name}"
        );
        assert_eq!(
            one.threads,
            status_field(&status, "Threads")
                .unwrap()
                .parse::<u32>()
                .unwrap(),
            "{name}"
        );
        assert_eq!(one.cpu_percent, 0.0, "{name}: no interval to measure");
        let expected_mem_percent = one.resident_bytes as f64 / total * 100.0;
        assert!(
            (one.mem_percent - expected_mem_percent).abs() < 1e-9,
            "{name}: memory percent is resident over total"
        );
    }
}

#[test]
fn scrubbed_process_names_are_unique_and_refer_to_their_pid() {
    for name in ARCHES {
        let sample = sample_from_fixture(&fixture_dir(name)).unwrap();
        let names: HashSet<&str> = sample.processes.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names.len(), sample.processes.len(), "{name}");
        for process in &sample.processes {
            assert!(
                process.name.starts_with("proc-"),
                "{name}: {} is not scrubbed",
                process.name
            );
            assert!(
                process.name.ends_with(&format!("-{}", process.pid)),
                "{name}: {} does not name pid {}",
                process.name,
                process.pid
            );
        }
    }
}

#[test]
fn fixture_samples_report_zero_process_cpu() {
    for name in ARCHES {
        let sample = sample_from_fixture(&fixture_dir(name)).unwrap();
        for process in &sample.processes {
            assert_eq!(
                process.cpu_percent, 0.0,
                "{name}: pid {} has no interval to measure",
                process.pid
            );
        }
    }
}

#[test]
fn a_missing_required_source_is_an_error() {
    let dir = std::env::temp_dir().join(format!("ztop-fixture-missing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("data")).unwrap();
    std::fs::write(
        dir.join("manifest.json"),
        r#"{"format":1,"platform":"linux","arch":"x86_64","kernel":"k","captured_at_unix":0,"source":"s","entries":[]}"#,
    )
    .unwrap();
    let err = sample_from_fixture(&dir).unwrap_err();
    assert!(matches!(
        err,
        FixtureSampleError::MissingSource { ref name } if name == "proc-stat"
    ));
    let _ = std::fs::remove_dir_all(&dir);
}
