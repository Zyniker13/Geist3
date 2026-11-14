// SPDX-License-Identifier: MIT OR Apache-2.0

//! Per-field checks of the macOS parsers against the recorded fixture.
//!
//! The macOS fixture is a scrubbed capture of a real host (decision
//! 0007): process names faked, no hostnames, usernames, serials or
//! addresses. Every expected value is re-derived from the raw captured
//! text, so a wrong column or unit shows up as a mismatch against an
//! independent parse. These tests run on every machine, not just macOS.

use std::path::{Path, PathBuf};

use ztop_core::fixture::Fixture;
use ztop_core::linux::FixtureSampleError;
use ztop_core::macos::{parse_processes, sample_from_fixture};
use ztop_core::model::Unit;
use ztop_core::sample_from_fixture as sample_for_platform;

const ARCH: &str = "macos-aarch64";

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(ARCH)
}

/// Reads one recorded entry from the fixture's `data` directory.
fn data(entry: &str) -> String {
    std::fs::read_to_string(fixture_dir().join("data").join(entry)).unwrap()
}

/// The `ticks` lines of the hostinfo entry as
/// `(core, user, system, idle, nice)`.
fn recorded_ticks() -> Vec<(u64, u64, u64, u64, u64)> {
    data("hostinfo")
        .lines()
        .filter_map(|line| line.strip_prefix("ticks "))
        .map(|rest| {
            let fields: Vec<u64> = rest
                .split_whitespace()
                .map(|value| value.parse().unwrap())
                .collect();
            (fields[0], fields[1], fields[2], fields[3], fields[4])
        })
        .collect()
}

/// The one `loadavg` line, as three fixed-point values scaled by 1000.
fn recorded_loadavg() -> [u64; 3] {
    let text = data("hostinfo");
    let line = text
        .lines()
        .find(|line| line.starts_with("loadavg "))
        .unwrap();
    let values: Vec<u64> = line["loadavg ".len()..]
        .split_whitespace()
        .map(|value| value.parse().unwrap())
        .collect();
    [values[0], values[1], values[2]]
}

/// One `key value` pair from the `vm` or `swap` line of hostinfo.
fn recorded_pair(line_prefix: &str, key: &str) -> u64 {
    let text = data("hostinfo");
    let line = text
        .lines()
        .find(|line| line.starts_with(line_prefix))
        .unwrap();
    let fields: Vec<&str> = line[line_prefix.len()..].split_whitespace().collect();
    let index = fields.iter().position(|field| *field == key).unwrap();
    fields[index + 1].parse().unwrap()
}

/// The recorded `boottime` line as `(seconds, microseconds)`.
fn recorded_boottime() -> (u64, u64) {
    let text = data("hostinfo");
    let line = text
        .lines()
        .find(|line| line.starts_with("boottime "))
        .unwrap();
    let values: Vec<u64> = line["boottime ".len()..]
        .split_whitespace()
        .map(|value| value.parse().unwrap())
        .collect();
    (values[0], values[1])
}

/// The recorded process lines, already split into the eight leading
/// fields and the quoted name: `(pid, ppid, status, uid, task-or-None,
/// name)`.
type RecordedProcess = (u32, u32, u32, u32, Option<(u64, u64, u64, u32)>, String);

fn recorded_processes() -> Vec<RecordedProcess> {
    data("processes")
        .lines()
        .map(|line| {
            let (prefix, quoted) = line.split_once(" \"").unwrap();
            let name = quoted.strip_suffix('"').unwrap();
            let fields: Vec<&str> = prefix.split_whitespace().collect();
            let number = |index: usize| -> u64 { fields[index].parse().unwrap() };
            let task = if fields[4] == "-" {
                None
            } else {
                Some((number(4), number(5), number(6), fields[7].parse().unwrap()))
            };
            (
                fields[0].parse().unwrap(),
                fields[1].parse().unwrap(),
                fields[2].parse().unwrap(),
                fields[3].parse().unwrap(),
                task,
                name.to_string(),
            )
        })
        .collect()
}

fn sample() -> ztop_core::model::Sample {
    sample_from_fixture(&fixture_dir()).unwrap()
}

#[test]
fn cpu_times_come_from_the_recorded_ticks_at_100_hz() {
    let ticks = recorded_ticks();
    assert!(!ticks.is_empty());
    let sample = sample();
    assert_eq!(sample.cpu.cores.len(), ticks.len(), "one row per core");
    for (core, times) in ticks.iter().zip(&sample.cpu.cores) {
        let seconds = |value: u64| value as f64 / 100.0;
        assert_eq!(times.user, seconds(core.1), "core {} user", core.0);
        assert_eq!(times.system, seconds(core.2), "core {} system", core.0);
        assert_eq!(times.idle, seconds(core.3), "core {} idle", core.0);
        assert_eq!(times.nice, seconds(core.4), "core {} nice", core.0);
    }
    // One snapshot has no interval to average over.
    assert_eq!(sample.cpu.busy_percent, vec![0.0; ticks.len()]);
}

#[test]
fn load_avg_scales_by_1000() {
    let avg = recorded_loadavg();
    let sample = sample();
    assert_eq!(
        sample.load_avg,
        [
            avg[0] as f64 / 1000.0,
            avg[1] as f64 / 1000.0,
            avg[2] as f64 / 1000.0
        ]
    );
}

#[test]
fn memory_fields_derive_from_vm_and_hw_memsize() {
    let total: u64 = data("sysctl-hw_memsize").trim().parse().unwrap();
    let free = recorded_pair("vm ", "free");
    let active = recorded_pair("vm ", "active");
    let wired = recorded_pair("vm ", "wired");
    let compressed = recorded_pair("vm ", "compressed");
    let swap_total = recorded_pair("swap ", "total");
    let swap_used = recorded_pair("swap ", "used");

    let memory = &sample().memory;
    assert_eq!(memory.total.value, total as f64);
    // Wired plus active plus compressed is the memory holding data.
    assert_eq!(memory.used.value, (wired + active + compressed) as f64);
    assert_eq!(memory.free.value, free as f64);
    assert_eq!(memory.compressed.value, compressed as f64);
    assert_eq!(memory.swap_total.value, swap_total as f64);
    assert_eq!(memory.swap_used.value, swap_used as f64);
    for metric in [
        &memory.total,
        &memory.used,
        &memory.free,
        &memory.compressed,
        &memory.swap_total,
        &memory.swap_used,
    ] {
        assert!(metric.available);
        assert_eq!(metric.unit, Unit::Bytes);
    }
}

#[test]
fn uptime_comes_from_boottime_and_the_manifest_timestamp() {
    let (boot_sec, boot_usec) = recorded_boottime();
    let fixture = Fixture::open(fixture_dir()).unwrap();
    let expected = fixture.manifest().captured_at_unix as f64
        - boot_sec as f64
        - boot_usec as f64 / 1_000_000.0;
    let uptime = sample().uptime;
    assert!(uptime.available);
    assert_eq!(uptime.unit, Unit::Seconds);
    assert!(
        (uptime.value - expected).abs() < 0.001,
        "{} vs {expected}",
        uptime.value
    );
}

#[test]
fn processes_parse_the_recorded_lines() {
    let recorded = recorded_processes();
    assert!(!recorded.is_empty());
    let procs = parse_processes(&data("processes"));
    assert_eq!(procs.len(), recorded.len());
    for (mac, (pid, ppid, status, uid, task, name)) in procs.iter().zip(&recorded) {
        assert_eq!(mac.pid, *pid);
        assert_eq!(mac.ppid, *ppid);
        assert_eq!(mac.status, *status);
        assert_eq!(mac.uid, *uid);
        assert_eq!(mac.name, *name);
        match (*task, mac.task) {
            (None, None) => {}
            (Some((utime, stime, rss, threads)), Some(usage)) => {
                assert_eq!(usage.utime_ns, utime);
                assert_eq!(usage.stime_ns, stime);
                assert_eq!(usage.rss_bytes, rss);
                assert_eq!(usage.threads, threads);
            }
            (recorded_task, parsed_task) => {
                panic!("task mismatch: recorded {recorded_task:?}, parsed {parsed_task:?}");
            }
        }
    }
    // The fixture records both shapes: a denied task field set and at
    // least one real one.
    assert!(
        recorded.iter().any(|row| row.4.is_none()),
        "fixture must keep a `-` row"
    );
    assert!(
        recorded.iter().any(|row| row.4.is_some()),
        "fixture must keep a real-field row"
    );
}

#[test]
fn sample_process_rows_derive_from_task_fields() {
    let total: u64 = data("sysctl-hw_memsize").trim().parse().unwrap();
    let recorded = recorded_processes();
    let sample = sample();
    assert_eq!(sample.processes.len(), recorded.len());
    for (process, (pid, ppid, _status, uid, task, name)) in sample.processes.iter().zip(&recorded) {
        assert_eq!(process.pid, *pid);
        assert_eq!(process.parent, Some(*ppid));
        assert_eq!(process.user, uid.to_string());
        // Every fixture row records status 2 (`SRUN`), which the ps-style
        // mapping renders as R.
        assert_eq!(process.state, "R");
        assert_eq!(process.name, *name);
        assert_eq!(process.cpu_percent, 0.0);
        match task {
            Some((_, _, rss, threads)) => {
                assert_eq!(process.resident_bytes, *rss);
                assert_eq!(process.threads, *threads);
                let expected = *rss as f64 / total as f64 * 100.0;
                assert!(
                    (process.mem_percent - expected).abs() < 1e-9,
                    "pid {}: {} vs {expected}",
                    process.pid,
                    process.mem_percent
                );
            }
            None => {
                // Denied fields are unavailable, never faked: the row
                // keeps its identity but carries no usage numbers.
                assert_eq!(process.resident_bytes, 0);
                assert_eq!(process.threads, 0);
                assert_eq!(process.mem_percent, 0.0);
            }
        }
    }
}

#[test]
fn a_missing_required_source_is_an_error() {
    let dir = std::env::temp_dir().join(format!("ztop-macos-missing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    write_fixture(&dir, "macos", &[]);
    let err = sample_from_fixture(&dir).unwrap_err();
    assert!(matches!(
        err,
        FixtureSampleError::MissingSource { ref name } if name == "hostinfo"
    ));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_hostinfo_without_cores_is_an_error() {
    let dir = std::env::temp_dir().join(format!("ztop-macos-empty-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    write_fixture(&dir, "macos", &[("hostinfo", "")]);
    let err = sample_from_fixture(&dir).unwrap_err();
    assert!(matches!(
        err,
        FixtureSampleError::BadSource { ref name } if name == "hostinfo"
    ));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unreadable_hw_memsize_is_an_error() {
    let dir = std::env::temp_dir().join(format!("ztop-macos-memsize-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    write_fixture(
        &dir,
        "macos",
        &[
            (MINIMAL_HOSTINFO.0, MINIMAL_HOSTINFO.1),
            ("sysctl-hw_memsize", "not-a-number\n"),
            ("processes", "0 0 2 0 - - - - \"kernel_task\"\n"),
        ],
    );
    let err = sample_from_fixture(&dir).unwrap_err();
    assert!(matches!(
        err,
        FixtureSampleError::BadSource { ref name } if name == "sysctl-hw_memsize"
    ));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unknown_platform_has_no_reader() {
    let dir = std::env::temp_dir().join(format!("ztop-macos-platform-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    write_fixture(&dir, "plan9", &[]);
    let err = sample_for_platform(&dir).unwrap_err();
    assert!(matches!(
        err,
        FixtureSampleError::UnknownPlatform { ref platform } if platform == "plan9"
    ));
    let _ = std::fs::remove_dir_all(&dir);
}

/// The smallest hostinfo entry the parser accepts, for error tests.
const MINIMAL_HOSTINFO: (&str, &str) = (
    "hostinfo",
    "ticks 0 1 2 3 4\n\
     loadavg 1 1 1\n\
     vm free 1 active 1 inactive 1 wired 1 compressed 1\n\
     swap total 1 avail 1 used 1\n\
     boottime 1 0\n",
);

/// Writes a fixture directory with the given platform and text entries.
fn write_fixture(dir: &Path, platform: &str, entries: &[(&str, &str)]) {
    std::fs::create_dir_all(dir.join("data")).unwrap();
    let entries_json = entries
        .iter()
        .map(|(name, _)| format!(r#"{{"name":"{name}","path":"data/{name}","kind":"text"}}"#))
        .collect::<Vec<_>>()
        .join(",");
    std::fs::write(
        dir.join("manifest.json"),
        format!(
            r#"{{"format":1,"platform":"{platform}","arch":"aarch64","kernel":"test","captured_at_unix":0,"source":"test","entries":[{entries_json}]}}"#
        ),
    )
    .unwrap();
    for (name, content) in entries {
        std::fs::write(dir.join("data").join(name), content).unwrap();
    }
}
