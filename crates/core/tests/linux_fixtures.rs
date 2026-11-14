// SPDX-License-Identifier: MIT OR Apache-2.0

//! Per-field checks of the Linux parsers against the recorded fixtures.
//!
//! The fixtures under `tests/fixtures/` are verbatim captures of real
//! Linux hosts with per-process names scrubbed (decision 0007), so every
//! parsed field can be pinned to the recorded bytes. These tests run on
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

#[test]
fn both_fixtures_build_a_full_sample() {
    for name in ARCHES {
        let dir = fixture_dir(name);
        let sample = sample_from_fixture(&dir).unwrap_or_else(|err| panic!("{name}: {err}"));
        assert_eq!(sample.hostname, name, "hostname comes from the directory");
        assert_eq!(sample.cpu.cores.len(), 4, "{name}");
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
fn x86_64_fixture_fields_match_the_recording() {
    let sample = sample_from_fixture(&fixture_dir("linux-x86_64")).unwrap();

    assert_eq!(
        sample.cpu.cores[0],
        CpuTimes {
            user: 14.57,
            nice: 0.0,
            system: 6.65,
            idle: 38.11,
            io_wait: 0.98,
            irq: 0.0,
            soft_irq: 0.14,
            steal: 0.0,
            guest: 0.0,
        }
    );

    assert_eq!(
        sample.memory.total,
        Metric::available(16366640.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(
        sample.memory.used,
        Metric::available(1417932.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(
        sample.memory.free,
        Metric::available(12997176.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(
        sample.memory.swap_total,
        Metric::available(3145724.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(sample.memory.swap_used, Metric::available(0.0, Unit::Bytes));
    assert_eq!(
        sample.memory.compressed,
        Metric::unavailable(Unit::Bytes),
        "compressed memory is a macOS concept"
    );

    assert_eq!(sample.load_avg, [1.93, 0.57, 0.20]);
    assert_eq!(sample.uptime, Metric::available(61.77, Unit::Seconds));

    assert_eq!(sample.disks.len(), 13);
    let sda = sample.disks.iter().find(|disk| disk.name == "sda").unwrap();
    assert_eq!(sda.read_bytes, 1474182 * 512);
    assert_eq!(sda.write_bytes, 7098027 * 512);

    assert_eq!(sample.net.len(), 4);
    let eth0 = sample
        .net
        .iter()
        .find(|iface| iface.name == "eth0")
        .unwrap();
    assert_eq!(eth0.rx_bytes, 265744198);
    assert_eq!(eth0.rx_packets, 29836);
    assert_eq!(eth0.tx_bytes, 1193601);
    assert_eq!(eth0.tx_packets, 10693);

    let one = sample
        .processes
        .iter()
        .find(|process| process.pid == 1)
        .unwrap();
    assert_eq!(one.name, "proc-a-1");
    assert_eq!(one.state, "S");
    assert_eq!(one.parent, Some(0));
    assert_eq!(one.user, "0");
    assert_eq!(one.virtual_bytes, 25700 * 1024);
    assert_eq!(one.resident_bytes, 17044 * 1024);
    assert_eq!(one.threads, 1);
    assert_eq!(one.cpu_percent, 0.0);
    let expected_mem_percent = 17044.0 / 16366640.0 * 100.0;
    assert!((one.mem_percent - expected_mem_percent).abs() < 1e-9);
}

#[test]
fn aarch64_fixture_fields_match_the_recording() {
    let sample = sample_from_fixture(&fixture_dir("linux-aarch64")).unwrap();

    assert_eq!(
        sample.cpu.cores[0],
        CpuTimes {
            user: 17.38,
            nice: 0.0,
            system: 4.30,
            idle: 58.82,
            io_wait: 2.74,
            irq: 0.0,
            soft_irq: 0.07,
            steal: 0.0,
            guest: 0.0,
        }
    );

    assert_eq!(
        sample.memory.total,
        Metric::available(16324144.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(
        sample.memory.used,
        Metric::available(1735104.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(
        sample.memory.free,
        Metric::available(12304432.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(
        sample.memory.swap_total,
        Metric::available(3145724.0 * 1024.0, Unit::Bytes)
    );
    assert_eq!(sample.memory.swap_used, Metric::available(0.0, Unit::Bytes));

    assert_eq!(sample.load_avg, [1.01, 0.24, 0.08]);
    assert_eq!(sample.uptime, Metric::available(83.95, Unit::Seconds));

    assert_eq!(sample.disks.len(), 12);
    let sda = sample.disks.iter().find(|disk| disk.name == "sda").unwrap();
    assert_eq!(sda.read_bytes, 1454442 * 512);
    assert_eq!(sda.write_bytes, 7042179 * 512);

    assert_eq!(sample.net.len(), 4);
    let eth0 = sample
        .net
        .iter()
        .find(|iface| iface.name == "eth0")
        .unwrap();
    assert_eq!(eth0.rx_bytes, 243304026);
    assert_eq!(eth0.rx_packets, 13834);
    assert_eq!(eth0.tx_bytes, 1039944);
    assert_eq!(eth0.tx_packets, 8508);

    let one = sample
        .processes
        .iter()
        .find(|process| process.pid == 1)
        .unwrap();
    assert_eq!(one.name, "proc-a-1");
    assert_eq!(one.state, "S");
    assert_eq!(one.parent, Some(0));
    assert_eq!(one.user, "0");
    assert_eq!(one.virtual_bytes, 22860 * 1024);
    assert_eq!(one.resident_bytes, 13632 * 1024);
    assert_eq!(one.threads, 1);
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
