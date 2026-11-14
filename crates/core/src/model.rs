// SPDX-License-Identifier: MIT OR Apache-2.0
//! The data model every part of zTop shares.
//!
//! Metrics carry their unit and their availability, because parity with
//! `htop` and `asitop` means several values exist only on one platform: an
//! absent source is modelled as an unavailable metric, not a missing field,
//! so layouts keep their place and the UI shows an explicit gap instead of
//! silently shifting rows.

use serde::{Deserialize, Serialize};

/// One measured value: the number, its unit, and whether the host provides it.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Metric {
    pub value: f64,
    pub unit: Unit,
    pub available: bool,
}

impl Metric {
    /// A value the host actually reported.
    pub fn available(value: f64, unit: Unit) -> Self {
        Self {
            value,
            unit,
            available: true,
        }
    }

    /// A value this platform does not provide; renders as a dash, keeps its slot.
    pub fn unavailable(unit: Unit) -> Self {
        Self {
            value: 0.0,
            unit,
            available: false,
        }
    }
}

/// Physical unit of a [`Metric`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Unit {
    Percent,
    Bytes,
    BytesPerSecond,
    Hertz,
    Celsius,
    Watts,
    RevolutionsPerMinute,
    Seconds,
    Count,
}

/// CPU time per state, in seconds, for one core or the whole package.
///
/// Linux-only states stay zero on macOS; macOS-only states would need their
/// own fields and are added with the macOS collector (M2).
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct CpuTimes {
    pub user: f64,
    pub system: f64,
    pub nice: f64,
    pub idle: f64,
    pub io_wait: f64,
    pub irq: f64,
    pub soft_irq: f64,
    pub steal: f64,
    pub guest: f64,
}

impl CpuTimes {
    /// Total busy time (everything but idle).
    ///
    /// `guest` is deliberately left out: the kernel already counts guest
    /// time inside `user`, so adding both would double-count it.
    pub fn busy(&self) -> f64 {
        self.user + self.system + self.nice + self.io_wait + self.irq + self.soft_irq + self.steal
    }

    /// Total observed time: [`CpuTimes::busy`] plus idle.
    pub fn total(&self) -> f64 {
        self.busy() + self.idle
    }
}

/// Per-core busy percentages between the previous and current core times.
///
/// Index `i` pairs `current[i]` with `previous[i]`; a core without a
/// previous reading reports 0.0, as does a non-positive interval. The
/// result is clamped to 0..=100 so counter resets cannot produce
/// negative values. Shared by the Linux and macOS collectors, whose
/// CPU counters are cumulative in the same way.
pub fn core_percents(current: &[CpuTimes], previous: &[CpuTimes], interval_secs: f64) -> Vec<f64> {
    if interval_secs <= 0.0 {
        return vec![0.0; current.len()];
    }
    current
        .iter()
        .enumerate()
        .map(|(index, now)| {
            let Some(old) = previous.get(index) else {
                return 0.0;
            };
            let busy = now.busy() - old.busy();
            let total = now.total() - old.total();
            if total <= 0.0 {
                0.0
            } else {
                (busy / total * 100.0).clamp(0.0, 100.0)
            }
        })
        .collect()
}

/// One sample of one host: a consistent snapshot at one instant.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    /// Milliseconds since the Unix epoch.
    pub timestamp_ms: u64,
    pub hostname: String,
    pub cpu: Cpu,
    pub memory: Memory,
    /// 1, 5 and 15 minute load averages.
    pub load_avg: [f64; 3],
    pub uptime: Metric,
    pub processes: Vec<Process>,
    /// Lifetime IO counters per block device.
    pub disks: Vec<Disk>,
    /// Lifetime counters per network interface.
    pub net: Vec<NetIf>,
    /// Temperatures, fans and battery, when the host provides them.
    pub sensors: Sensors,
}

/// Lifetime IO counters of one block device, in bytes.
///
/// `/proc/diskstats` counts sectors; collectors convert with the
/// traditional 512-byte sector the kernel counts in, regardless of the
/// device's real sector size.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Disk {
    /// Kernel device name, e.g. `sda` or `nvme0n1`.
    pub name: String,
    pub read_bytes: u64,
    pub write_bytes: u64,
}

/// Lifetime counters of one network interface.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetIf {
    /// Interface name as the kernel reports it, e.g. `eth0`.
    pub name: String,
    pub rx_bytes: u64,
    pub rx_packets: u64,
    pub tx_bytes: u64,
    pub tx_packets: u64,
}

/// One temperature reading.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TempSensor {
    /// Where the reading comes from, e.g. a chip or zone label.
    pub label: String,
    pub celsius: Metric,
}

/// One fan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fan {
    /// Where the reading comes from, e.g. a chip or sensor label.
    pub label: String,
    pub rpm: Metric,
}

/// Charge state of a battery, as the kernel reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BatteryState {
    Charging,
    Discharging,
    Full,
    Unknown,
}

/// One battery.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Battery {
    pub percent: Metric,
    /// Current power draw; often unavailable on desktops and servers.
    pub power_watts: Metric,
    pub state: BatteryState,
}

/// Temperatures, fans and battery.
///
/// An empty group means the host has none of them (or no driver exposes
/// them); lists are genuinely empty and an absent battery is `None`, not
/// unavailable placeholders.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Sensors {
    pub temps: Vec<TempSensor>,
    pub fans: Vec<Fan>,
    pub battery: Option<Battery>,
}

/// CPU state for one host: per-core times and, when reported, frequencies.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cpu {
    /// Per-core times; index matches the core number on both platforms.
    pub cores: Vec<CpuTimes>,
    /// Per-core CPU utilization in percent over the sample interval.
    ///
    /// Like [`Process::cpu_percent`], rates are measured from the previous
    /// sample: the first sample of a collector, and every fixture replay of
    /// a single capture, reports 0.0 because a lone snapshot has no
    /// interval to average over.
    pub busy_percent: Vec<f64>,
    /// Current frequency per core, when the platform reports it.
    pub frequency_mhz: Vec<Metric>,
}

/// Memory and swap in bytes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Memory {
    pub total: Metric,
    pub used: Metric,
    pub free: Metric,
    pub swap_total: Metric,
    pub swap_used: Metric,
    /// macOS compressed memory; unavailable elsewhere.
    pub compressed: Metric,
}

/// One process as the process table shows it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Process {
    pub pid: u32,
    /// Parent pid, when the platform reports it.
    pub parent: Option<u32>,
    pub user: String,
    pub state: String,
    pub name: String,
    /// CPU percent over the sample interval.
    pub cpu_percent: f64,
    pub mem_percent: f64,
    pub virtual_bytes: u64,
    pub resident_bytes: u64,
    pub threads: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metric_availability_is_explicit() {
        let have = Metric::available(42.0, Unit::Celsius);
        let missing = Metric::unavailable(Unit::Celsius);
        assert!(have.available);
        assert!(!missing.available);
        assert_eq!(have.unit, missing.unit);
    }

    #[test]
    fn sample_survives_a_roundtrip() {
        let sample = Sample {
            timestamp_ms: 1_700_000_000_000,
            hostname: "host-a".into(),
            cpu: Cpu {
                cores: vec![CpuTimes {
                    user: 1.5,
                    idle: 8.5,
                    ..CpuTimes::default()
                }],
                frequency_mhz: vec![Metric::unavailable(Unit::Hertz)],
                busy_percent: vec![0.0],
            },
            memory: Memory {
                total: Metric::available(16.0 * 1024.0 * 1024.0 * 1024.0, Unit::Bytes),
                used: Metric::available(8.0 * 1024.0 * 1024.0 * 1024.0, Unit::Bytes),
                free: Metric::available(8.0 * 1024.0 * 1024.0 * 1024.0, Unit::Bytes),
                swap_total: Metric::unavailable(Unit::Bytes),
                swap_used: Metric::unavailable(Unit::Bytes),
                compressed: Metric::unavailable(Unit::Bytes),
            },
            load_avg: [0.5, 0.4, 0.3],
            uptime: Metric::available(1234.0, Unit::Seconds),
            processes: vec![Process {
                pid: 42,
                parent: Some(1),
                user: "alice".into(),
                state: "running".into(),
                name: "kernel_task".into(),
                cpu_percent: 1.0,
                mem_percent: 0.5,
                virtual_bytes: 1 << 30,
                resident_bytes: 1 << 20,
                threads: 4,
            }],
            disks: vec![Disk {
                name: "sda".into(),
                read_bytes: 1_474_182 * 512,
                write_bytes: 7_098_027 * 512,
            }],
            net: vec![NetIf {
                name: "eth0".into(),
                rx_bytes: 265_744_198,
                rx_packets: 29_836,
                tx_bytes: 1_193_601,
                tx_packets: 10_693,
            }],
            sensors: Sensors {
                temps: vec![TempSensor {
                    label: "coretemp".into(),
                    celsius: Metric::available(45.5, Unit::Celsius),
                }],
                fans: vec![],
                battery: Some(Battery {
                    percent: Metric::available(80.0, Unit::Percent),
                    power_watts: Metric::unavailable(Unit::Watts),
                    state: BatteryState::Charging,
                }),
            },
        };
        let json = serde_json::to_string(&sample).expect("serialize");
        let back: Sample = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, sample);
    }

    #[test]
    fn units_serialize_as_snake_case() {
        assert_eq!(
            serde_json::to_string(&Unit::BytesPerSecond).unwrap(),
            r#""bytes_per_second""#
        );
        assert_eq!(
            serde_json::to_string(&Unit::RevolutionsPerMinute).unwrap(),
            r#""revolutions_per_minute""#
        );
    }

    #[test]
    fn busy_time_does_not_double_count_guest() {
        // The kernel accounts guest time inside `user`; adding `guest`
        // again would inflate busy time.
        let times = CpuTimes {
            user: 10.0,
            system: 2.0,
            nice: 1.0,
            idle: 7.0,
            io_wait: 1.0,
            irq: 0.5,
            soft_irq: 0.5,
            steal: 1.0,
            guest: 3.0,
        };
        assert_eq!(times.busy(), 16.0);
        assert_eq!(times.total(), 23.0);
    }
}
