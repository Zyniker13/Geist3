// SPDX-License-Identifier: MIT OR Apache-2.0

//! Linux collectors: pure text parsers plus the live `/proc` reader.
//!
//! Decision 0007 splits Linux sourcing in two. The parsers in this module
//! are pure functions over the verbatim text of one source file, so they
//! run and are tested identically on every machine: the tests at the
//! bottom cover edge cases with short synthetic texts, and the
//! integration tests in `crates/core/tests/linux_fixtures.rs` pin every
//! parsed field against the recorded fixtures under `tests/fixtures/`.
//! The live collector is cfg-gated to Linux builds and feeds the same
//! parsers from `/proc` and `/sys`.
//!
//! Reading notes:
//! - CPU times arrive in jiffies and are converted with [`USER_HZ`], the
//!   fixed kernel/user ABI rate of 100 ticks per second.
//! - [`Memory::used`] is `MemTotal - MemAvailable`, the memory a running
//!   system cannot give back without swapping; [`Memory::free`] stays the
//!   literal `MemFree` value. Memory values are recorded in KiB by the
//!   kernel and converted to bytes here.
//! - The process user is the numeric uid from `status`; mapping uid to a
//!   name would need `/etc/passwd`, which the fixtures do not record.
//! - Per-core frequencies are not read: `/proc/cpuinfo` carries them only
//!   on some kernels, so `frequency_mhz` stays empty on Linux for now.
//! - The first sample of a live collector cannot know an interval, so
//!   process CPU percentages start at 0.0 and later samples report the
//!   share of wall time since the previous sample, like `htop`.

use std::collections::BTreeMap;
use std::path::Path;

use crate::fixture::{Fixture, FixtureError};
#[cfg(any(target_os = "linux", test))]
use crate::model::{Battery, BatteryState, Fan, TempSensor};
use crate::model::{Cpu, CpuTimes, Disk, Memory, Metric, NetIf, Process, Sample, Sensors, Unit};

/// Jiffies per second: the fixed `USER_HZ` of the kernel/user ABI.
const USER_HZ: f64 = 100.0;

/// Parsed `/proc/stat`: one [`CpuTimes`] per core, ordered by core number.
#[derive(Debug, Clone)]
pub(crate) struct ProcStat {
    pub(crate) cores: Vec<CpuTimes>,
}

/// Parses `/proc/stat` into per-core CPU times.
///
/// Returns `None` when the text has no core lines, when a core line does
/// not parse, or when core numbers have gaps or duplicates: a collector
/// must not silently drop part of a source. The aggregate `cpu` line and
/// every non-CPU line are ignored; the aggregate's kernel-side accounting
/// does not reliably equal the sum of the cores, so the collector only
/// reports per-core times.
fn parse_proc_stat(text: &str) -> Option<ProcStat> {
    let mut cores: Vec<(usize, CpuTimes)> = Vec::new();
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("cpu") else {
            continue;
        };
        if rest.starts_with([' ', '\t']) {
            continue; // the aggregate `cpu` line
        }
        let (index, fields) = rest.split_once(' ')?;
        if index.is_empty() || !index.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let index: usize = index.parse().ok()?;
        let times = parse_cpu_fields(fields)?;
        cores.push((index, times));
    }
    if cores.is_empty() {
        return None;
    }
    cores.sort_by_key(|(index, _)| *index);
    if cores
        .iter()
        .enumerate()
        .any(|(want, (got, _))| want != *got)
    {
        return None;
    }
    Some(ProcStat {
        cores: cores.into_iter().map(|(_, times)| times).collect(),
    })
}

/// Parses the nine tick fields of one `cpuN` line, converting to seconds.
fn parse_cpu_fields(fields: &str) -> Option<CpuTimes> {
    let mut next = fields.split_whitespace();
    let mut tick = || next.next()?.parse::<f64>().ok();
    let user = tick()? / USER_HZ;
    let nice = tick()? / USER_HZ;
    let system = tick()? / USER_HZ;
    let idle = tick()? / USER_HZ;
    let io_wait = tick()? / USER_HZ;
    let irq = tick()? / USER_HZ;
    let soft_irq = tick()? / USER_HZ;
    let steal = tick()? / USER_HZ;
    let guest = tick()? / USER_HZ;
    Some(CpuTimes {
        user,
        nice,
        system,
        idle,
        io_wait,
        irq,
        soft_irq,
        steal,
        guest,
    })
}

/// Parsed `/proc/meminfo`, in bytes.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct ProcMem {
    pub(crate) total: u64,
    pub(crate) available: u64,
    pub(crate) free: Option<u64>,
    pub(crate) swap_total: u64,
    pub(crate) swap_free: u64,
}

/// Parses `/proc/meminfo`.
///
/// `MemTotal` is required; `MemAvailable` falls back to `MemFree` on old
/// kernels that do not report it.
fn parse_proc_meminfo(text: &str) -> Option<ProcMem> {
    let mut mem = ProcMem::default();
    let mut seen_total = false;
    let mut seen_available = false;
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let Some(number) = value.split_whitespace().next() else {
            continue;
        };
        let Ok(kib) = number.parse::<u64>() else {
            continue;
        };
        match key.trim() {
            "MemTotal" => {
                mem.total = kib * 1024;
                seen_total = true;
            }
            "MemAvailable" => {
                mem.available = kib * 1024;
                seen_available = true;
            }
            "MemFree" => mem.free = Some(kib * 1024),
            "SwapTotal" => mem.swap_total = kib * 1024,
            "SwapFree" => mem.swap_free = kib * 1024,
            _ => {}
        }
    }
    if !seen_total {
        return None;
    }
    if !seen_available {
        mem.available = mem.free.unwrap_or(0);
    }
    Some(mem)
}

/// Parses the first three fields of `/proc/loadavg`.
fn parse_proc_loadavg(text: &str) -> Option<[f64; 3]> {
    let mut fields = text.split_whitespace();
    let one: f64 = fields.next()?.parse().ok()?;
    let five: f64 = fields.next()?.parse().ok()?;
    let fifteen: f64 = fields.next()?.parse().ok()?;
    Some([one, five, fifteen])
}

/// Parses the first field of `/proc/uptime`, in seconds.
fn parse_proc_uptime(text: &str) -> Option<f64> {
    text.split_whitespace().next()?.parse().ok()
}

/// Parses `/proc/diskstats`.
///
/// The kernel counts 512-byte sectors regardless of the device's real
/// sector size, so both byte totals are sector counts times 512.
/// Lines that do not follow the field layout are skipped: device sets
/// legitimately differ between hosts.
fn parse_proc_diskstats(text: &str) -> Vec<Disk> {
    let mut disks = Vec::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let Some(name) = fields.nth(2) else {
            continue;
        };
        let Ok(counters) = fields
            .map(|field| field.parse::<u64>())
            .collect::<Result<Vec<u64>, _>>()
        else {
            continue;
        };
        if counters.len() < 7 {
            continue;
        }
        disks.push(Disk {
            name: name.to_string(),
            read_bytes: counters[2] * 512,
            write_bytes: counters[6] * 512,
        });
    }
    disks
}

/// Parses `/proc/net/dev`, skipping the two header lines.
///
/// Lines that do not follow the field layout are skipped.
fn parse_proc_net_dev(text: &str) -> Vec<NetIf> {
    let mut interfaces = Vec::new();
    for line in text.lines().skip(2) {
        let Some((name, counters)) = line.split_once(':') else {
            continue;
        };
        let counters: Vec<u64> = counters
            .split_whitespace()
            .map_while(|field| field.parse().ok())
            .collect();
        if counters.len() < 10 {
            continue;
        }
        interfaces.push(NetIf {
            name: name.trim().to_string(),
            rx_bytes: counters[0],
            rx_packets: counters[1],
            tx_bytes: counters[8],
            tx_packets: counters[9],
        });
    }
    interfaces
}

/// Parsed fields of one process's `status` file.
#[derive(Debug, Default)]
pub(crate) struct PidStatus {
    pub(crate) name: String,
    pub(crate) state: Option<String>,
    pub(crate) parent: Option<u32>,
    pub(crate) uid: Option<u64>,
    pub(crate) vm_size: u64,
    pub(crate) vm_rss: u64,
    pub(crate) threads: u32,
}

/// Parses the `status` fields the collectors use; missing lines stay at
/// their defaults.
fn parse_pid_status(text: &str) -> PidStatus {
    let mut status = PidStatus::default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        match key.trim() {
            "Name" => status.name = value.trim().to_string(),
            "State" => {
                status.state = value.split_whitespace().next().map(str::to_string);
            }
            "PPid" => status.parent = value.trim().parse().ok(),
            "Uid" => {
                status.uid = value
                    .split_whitespace()
                    .next()
                    .and_then(|uid| uid.parse().ok());
            }
            "VmSize" => status.vm_size = kib_bytes(value),
            "VmRSS" => status.vm_rss = kib_bytes(value),
            "Threads" => status.threads = value.trim().parse().unwrap_or(0),
            _ => {}
        }
    }
    status
}

/// Converts a `status` memory value like `   25700 kB` to bytes.
fn kib_bytes(value: &str) -> u64 {
    value
        .split_whitespace()
        .next()
        .and_then(|number| number.parse::<u64>().ok())
        .map(|kib| kib * 1024)
        .unwrap_or(0)
}

/// Parsed CPU jiffies from one process's `stat` file.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PidStat {
    // Read only by the live collector's CPU-percentage deltas, which do
    // not compile on non-Linux hosts.
    #[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
    pub(crate) utime_jiffies: u64,
    #[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
    pub(crate) stime_jiffies: u64,
}

/// Parses the `utime` and `stime` fields of `stat`, which sit after the
/// parenthesised command and must therefore not be split naively.
fn parse_pid_stat(text: &str) -> Option<PidStat> {
    let open = text.find('(')?;
    let close = text.rfind(')')?;
    if close <= open {
        return None;
    }
    let mut fields = text[close + 1..].split_whitespace();
    let utime_jiffies: u64 = fields.nth(11)?.parse().ok()?;
    let stime_jiffies: u64 = fields.next()?.parse().ok()?;
    Some(PidStat {
        utime_jiffies,
        stime_jiffies,
    })
}

/// Everything recorded for one process, keyed by pid.
#[derive(Debug, Default)]
pub(crate) struct PidData {
    pub(crate) status: Option<PidStatus>,
    pub(crate) stat: Option<PidStat>,
    pub(crate) comm: Option<String>,
}

/// Builds one [`Process`] row.
///
/// The user is the numeric uid; the name falls back from `status` to
/// `comm` to `pid-<pid>`. Memory percentages use the recorded `MemTotal`.
fn process_row(pid: u32, data: &PidData, total_mem_bytes: u64, cpu_percent: f64) -> Process {
    let status = data.status.as_ref();
    let comm = data.comm.as_deref().map(str::trim_end);
    let name = match (status.map(|status| status.name.as_str()), comm) {
        (Some(name), _) if !name.is_empty() => name.to_string(),
        (_, Some(comm)) if !comm.is_empty() => comm.to_string(),
        _ => format!("pid-{pid}"),
    };
    let state = status
        .and_then(|status| status.state.as_deref())
        .unwrap_or("?")
        .to_string();
    let user = status
        .and_then(|status| status.uid)
        .map(|uid| uid.to_string())
        .unwrap_or_else(|| "?".to_string());
    let (virtual_bytes, resident_bytes, threads) = match status {
        Some(status) => (status.vm_size, status.vm_rss, status.threads),
        None => (0, 0, 0),
    };
    let mem_percent = if total_mem_bytes > 0 {
        resident_bytes as f64 / total_mem_bytes as f64 * 100.0
    } else {
        0.0
    };
    Process {
        pid,
        parent: status.and_then(|status| status.parent),
        user,
        state,
        name,
        cpu_percent,
        mem_percent,
        virtual_bytes,
        resident_bytes,
        threads,
    }
}

/// Builds the process table from the recorded per-pid entries.
///
/// Only pids with a `status` or a `comm` produce a row; a `stat`-only
/// entry carries no usable name.
fn process_table(pids: &BTreeMap<u32, PidData>, total_mem_bytes: u64) -> Vec<Process> {
    let mut rows = Vec::new();
    for (pid, data) in pids {
        if data.status.is_none() && data.comm.is_none() {
            continue;
        }
        rows.push(process_row(*pid, data, total_mem_bytes, 0.0));
    }
    rows
}

/// Builds the [`Memory`] metrics from parsed `meminfo` values.
///
/// `used` is `MemTotal - MemAvailable`: the memory a running system
/// cannot give back without swapping.
fn memory_from(mem: ProcMem) -> Memory {
    Memory {
        total: Metric::available(mem.total as f64, Unit::Bytes),
        used: Metric::available(mem.total.saturating_sub(mem.available) as f64, Unit::Bytes),
        free: match mem.free {
            Some(free) => Metric::available(free as f64, Unit::Bytes),
            None => Metric::unavailable(Unit::Bytes),
        },
        swap_total: Metric::available(mem.swap_total as f64, Unit::Bytes),
        swap_used: Metric::available(
            mem.swap_total.saturating_sub(mem.swap_free) as f64,
            Unit::Bytes,
        ),
        compressed: Metric::unavailable(Unit::Bytes),
    }
}

/// Labels one hwmon chip: the `name` file when present, else the
/// directory name (`hwmon0`).
#[cfg(any(target_os = "linux", test))]
fn hwmon_label(dir_name: &str, files: &[(String, String)]) -> String {
    files
        .iter()
        .find(|(name, _)| name == "name")
        .map(|(_, text)| text.trim().to_string())
        .filter(|label| !label.is_empty())
        .unwrap_or_else(|| dir_name.to_string())
}

/// Label for the `index`-th temperature input: its `tempN_label` file
/// when present, else the chip label.
#[cfg(any(target_os = "linux", test))]
fn temp_label(chip: &str, files: &[(String, String)], index: usize) -> String {
    let wanted = format!("temp{}_label", index + 1);
    files
        .iter()
        .find(|(name, _)| name == &wanted)
        .map(|(_, text)| text.trim().to_string())
        .filter(|label| !label.is_empty())
        .unwrap_or_else(|| chip.to_string())
}

/// Parses one hwmon directory's `tempN_input`/`fanN_input` files.
///
/// Files arrive as `(file name, contents)` pairs; a `tempN_label` file
/// overrides the chip label for that sensor. The kernel reports
/// temperatures in millidegrees, which are converted to degrees.
#[cfg(any(target_os = "linux", test))]
fn parse_hwmon(dir_name: &str, files: &[(String, String)]) -> (Vec<TempSensor>, Vec<Fan>) {
    let chip = hwmon_label(dir_name, files);
    let mut temps: Vec<(&str, Metric)> = Vec::new();
    let mut fans: Vec<(&str, Metric)> = Vec::new();
    for (name, text) in files {
        let value = text.trim();
        let temp_index = name
            .strip_prefix("temp")
            .and_then(|rest| rest.strip_suffix("_input"));
        let fan_index = name
            .strip_prefix("fan")
            .and_then(|rest| rest.strip_suffix("_input"));
        if let Some(index) = temp_index {
            if index.is_empty() || !index.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            let Ok(millidegrees) = value.parse::<f64>() else {
                continue;
            };
            temps.push((
                name,
                Metric::available(millidegrees / 1000.0, Unit::Celsius),
            ));
        } else if let Some(index) = fan_index {
            if index.is_empty() || !index.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            let Ok(rpm) = value.parse::<f64>() else {
                continue;
            };
            fans.push((name, Metric::available(rpm, Unit::RevolutionsPerMinute)));
        }
    }
    temps.sort_by_key(|(name, _)| *name);
    let temps = temps
        .into_iter()
        .enumerate()
        .map(|(index, (_, celsius))| TempSensor {
            label: temp_label(chip.as_str(), files, index),
            celsius,
        })
        .collect();
    fans.sort_by_key(|(name, _)| *name);
    let fans = fans
        .into_iter()
        .map(|(_, rpm)| Fan {
            label: chip.clone(),
            rpm,
        })
        .collect();
    (temps, fans)
}

/// Parses one `/sys/class/power_supply/<supply>` directory.
///
/// Returns `None` when the supply reports no `capacity`, which is how
/// mains adapters look; a battery always reports its charge percentage.
#[cfg(any(target_os = "linux", test))]
fn parse_power_supply(files: &[(String, String)]) -> Option<Battery> {
    let capacity = files
        .iter()
        .find(|(name, _)| name == "capacity")
        .and_then(|(_, text)| text.trim().parse::<u64>().ok())?;
    let state = files
        .iter()
        .find(|(name, _)| name == "status")
        .map(|(_, text)| battery_state(text))
        .unwrap_or(BatteryState::Unknown);
    Some(Battery {
        percent: Metric::available(capacity as f64, Unit::Percent),
        power_watts: power_watts(files),
        state,
    })
}

/// Battery power in watts: `power_now` in microwatts, or `current_now`
/// times `voltage_now` (microamps times microvolts) when the driver
/// reports those instead.
#[cfg(any(target_os = "linux", test))]
fn power_watts(files: &[(String, String)]) -> Metric {
    let read = |file: &str| -> Option<u64> {
        files
            .iter()
            .find(|(name, _)| name == file)
            .and_then(|(_, text)| text.trim().parse::<u64>().ok())
    };
    if let Some(microwatts) = read("power_now") {
        return Metric::available(microwatts as f64 / 1_000_000.0, Unit::Watts);
    }
    if let (Some(microamps), Some(microvolts)) = (read("current_now"), read("voltage_now")) {
        return Metric::available(
            microamps as f64 * microvolts as f64 / 1_000_000_000_000.0,
            Unit::Watts,
        );
    }
    Metric::unavailable(Unit::Watts)
}

/// Parses the `status` file of a power supply into a [`BatteryState`].
#[cfg(any(target_os = "linux", test))]
fn battery_state(text: &str) -> BatteryState {
    match text.trim() {
        "Charging" => BatteryState::Charging,
        "Discharging" => BatteryState::Discharging,
        "Full" => BatteryState::Full,
        _ => BatteryState::Unknown,
    }
}

/// Splits a per-pid entry name like `proc-42-status` into pid and kind.
fn split_pid_entry(name: &str) -> Option<(u32, &str)> {
    let rest = name.strip_prefix("proc-")?;
    let (pid, kind) = rest.split_once('-')?;
    if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let pid: u32 = pid.parse().ok()?;
    if !matches!(kind, "stat" | "status" | "comm" | "cmdline") {
        return None;
    }
    Some((pid, kind))
}

/// Building a [`Sample`] from a fixture directory failed.
#[derive(Debug, thiserror::Error)]
pub enum FixtureSampleError {
    /// Reading the fixture directory failed.
    #[error("reading the fixture failed: {0}")]
    Fixture(#[from] FixtureError),
    /// A required source is missing from the fixture.
    #[error("the fixture is missing `{name}`")]
    MissingSource {
        /// Name of the missing entry, e.g. `proc-stat`.
        name: String,
    },
    /// A required source is present but did not parse.
    #[error("`{name}` did not parse")]
    BadSource {
        /// Name of the unparseable entry.
        name: String,
    },
}

fn missing_source(name: &'static str) -> FixtureSampleError {
    FixtureSampleError::MissingSource {
        name: name.to_string(),
    }
}

fn bad_source(name: &str) -> FixtureSampleError {
    FixtureSampleError::BadSource {
        name: name.to_string(),
    }
}

/// Builds a [`Sample`] from a recorded fixture directory.
///
/// The directory is one [`Fixture`] capture (see `ztop capture`): a
/// `manifest.json` plus the verbatim text of each recorded source under
/// `data/`. The hostname comes from the directory name, the timestamp
/// from the manifest, and per-process CPU percentages are 0.0 because a
/// fixture has no interval to measure against. This is the path the test
/// suite and the Linux CI smoke test use.
///
/// # Errors
///
/// Returns [`FixtureSampleError`] when reading the fixture fails, a
/// required source is missing, or a required source does not parse.
pub fn sample_from_fixture(dir: &Path) -> Result<Sample, FixtureSampleError> {
    let fixture = Fixture::open(dir)?;
    let mut stat = None;
    let mut meminfo = None;
    let mut loadavg = None;
    let mut uptime = None;
    let mut disks = None;
    let mut net = None;
    let mut pids: BTreeMap<u32, PidData> = BTreeMap::new();

    for name in fixture.entry_names() {
        if let Some((pid, kind)) = split_pid_entry(name) {
            let text = fixture.entry_text(name)?;
            let data = pids.entry(pid).or_default();
            match kind {
                "stat" => data.stat = parse_pid_stat(&text),
                "status" => data.status = Some(parse_pid_status(&text)),
                "comm" => data.comm = Some(text),
                _ => {} // cmdline: nothing beyond `comm` is useful here
            }
            continue;
        }
        let text = fixture.entry_text(name)?;
        match name {
            "proc-stat" => {
                stat = Some(parse_proc_stat(&text).ok_or_else(|| bad_source(name))?);
            }
            "proc-meminfo" => {
                meminfo = Some(parse_proc_meminfo(&text).ok_or_else(|| bad_source(name))?);
            }
            "proc-loadavg" => {
                loadavg = Some(parse_proc_loadavg(&text).ok_or_else(|| bad_source(name))?);
            }
            "proc-uptime" => {
                uptime = Some(parse_proc_uptime(&text).ok_or_else(|| bad_source(name))?);
            }
            "proc-diskstats" => disks = Some(parse_proc_diskstats(&text)),
            "proc-net-dev" => net = Some(parse_proc_net_dev(&text)),
            _ => {}
        }
    }

    let stat = stat.ok_or_else(|| missing_source("proc-stat"))?;
    let meminfo = meminfo.ok_or_else(|| missing_source("proc-meminfo"))?;
    let loadavg = loadavg.ok_or_else(|| missing_source("proc-loadavg"))?;
    let uptime = uptime.ok_or_else(|| missing_source("proc-uptime"))?;

    Ok(Sample {
        timestamp_ms: fixture.manifest().captured_at_unix * 1000,
        hostname: dir
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown")
            .to_string(),
        cpu: Cpu {
            cores: stat.cores,
            frequency_mhz: Vec::new(),
        },
        memory: memory_from(meminfo),
        load_avg: loadavg,
        uptime: Metric::available(uptime, Unit::Seconds),
        processes: process_table(&pids, meminfo.total),
        disks: disks.unwrap_or_default(),
        net: net.unwrap_or_default(),
        sensors: Sensors {
            temps: Vec::new(),
            fans: Vec::new(),
            battery: None,
        },
    })
}

#[cfg(target_os = "linux")]
pub use live::LinuxCollector;

/// The live Linux collector: feeds the parsers from a running host.
#[cfg(target_os = "linux")]
mod live {
    use std::collections::{BTreeMap, HashMap};
    use std::fs;
    use std::path::Path;
    use std::time::{Instant, SystemTime, UNIX_EPOCH};

    use super::{
        PidData, PidStat, USER_HZ, memory_from, parse_hwmon, parse_pid_stat, parse_pid_status,
        parse_power_supply, parse_proc_diskstats, parse_proc_loadavg, parse_proc_meminfo,
        parse_proc_net_dev, parse_proc_stat, parse_proc_uptime, process_row,
    };
    use crate::collector::{CollectError, Collector};
    use crate::model::{Cpu, Fan, Metric, Process, Sample, Sensors, TempSensor, Unit};

    /// Reads `/proc` and `/sys` on the running Linux host.
    ///
    /// Process CPU percentages are measured between samples: the first
    /// sample reports 0.0 for every process, later samples the share of
    /// wall time since the previous one, like `htop`.
    #[derive(Debug, Default)]
    pub struct LinuxCollector {
        prev: Option<Prev>,
    }

    /// State from the previous sample needed for rates.
    #[derive(Debug, Clone)]
    struct Prev {
        at: Instant,
        pids: HashMap<u32, PidStat>,
    }

    impl Collector for LinuxCollector {
        fn sample(&mut self) -> Result<Sample, CollectError> {
            let now = Instant::now();
            let timestamp_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| CollectError::Unavailable {
                    origin: "clock",
                    what: "the wall clock",
                })?
                .as_millis() as u64;
            let hostname = fs::read_to_string("/proc/sys/kernel/hostname")?
                .trim()
                .to_string();

            let stat_text = fs::read_to_string("/proc/stat")?;
            let stat = parse_proc_stat(&stat_text).ok_or(CollectError::Unavailable {
                origin: "/proc/stat",
                what: "CPU times",
            })?;
            let meminfo_text = fs::read_to_string("/proc/meminfo")?;
            let meminfo = parse_proc_meminfo(&meminfo_text).ok_or(CollectError::Unavailable {
                origin: "/proc/meminfo",
                what: "memory",
            })?;
            let loadavg_text = fs::read_to_string("/proc/loadavg")?;
            let load_avg = parse_proc_loadavg(&loadavg_text).ok_or(CollectError::Unavailable {
                origin: "/proc/loadavg",
                what: "load averages",
            })?;
            let uptime_text = fs::read_to_string("/proc/uptime")?;
            let uptime = parse_proc_uptime(&uptime_text).ok_or(CollectError::Unavailable {
                origin: "/proc/uptime",
                what: "uptime",
            })?;
            let disks = fs::read_to_string("/proc/diskstats")
                .ok()
                .as_deref()
                .map(parse_proc_diskstats)
                .unwrap_or_default();
            let net = fs::read_to_string("/proc/net/dev")
                .ok()
                .as_deref()
                .map(parse_proc_net_dev)
                .unwrap_or_default();

            let mut pids: BTreeMap<u32, PidData> = BTreeMap::new();
            for entry in fs::read_dir("/proc")? {
                let entry = entry?;
                let file_name = entry.file_name();
                let Some(name) = file_name.to_str() else {
                    continue;
                };
                if !name.bytes().all(|b| b.is_ascii_digit()) {
                    continue;
                }
                let Ok(pid) = name.parse::<u32>() else {
                    continue;
                };
                let base = entry.path();
                let data = pids.entry(pid).or_default();
                data.stat = fs::read_to_string(base.join("stat"))
                    .ok()
                    .and_then(|text| parse_pid_stat(&text));
                data.status = fs::read_to_string(base.join("status"))
                    .ok()
                    .map(|text| parse_pid_status(&text));
                data.comm = fs::read_to_string(base.join("comm")).ok();
            }

            let mut temps: Vec<TempSensor> = Vec::new();
            let mut fans: Vec<Fan> = Vec::new();
            for hwmon in read_dir_names(Path::new("/sys/class/hwmon")) {
                let dir = Path::new("/sys/class/hwmon").join(&hwmon);
                let (mut chip_temps, mut chip_fans) = parse_hwmon(&hwmon, &read_pairs(&dir));
                temps.append(&mut chip_temps);
                fans.append(&mut chip_fans);
            }
            let battery = read_dir_names(Path::new("/sys/class/power_supply"))
                .iter()
                .filter_map(|supply| {
                    parse_power_supply(&read_pairs(
                        &Path::new("/sys/class/power_supply").join(supply),
                    ))
                })
                .next();

            let interval_secs = self
                .prev
                .as_ref()
                .map(|prev| now.duration_since(prev.at).as_secs_f64());
            let prev_pids = self.prev.as_ref().map(|prev| &prev.pids);
            let total_mem_bytes = meminfo.total;
            let mut processes: Vec<Process> = Vec::new();
            for (pid, data) in &pids {
                let cpu_percent = match (prev_pids, data.stat.as_ref(), interval_secs) {
                    (Some(prev), Some(current), Some(secs)) if secs > 0.0 => {
                        let ticks = match prev.get(pid) {
                            Some(old) => {
                                current.utime_jiffies.saturating_sub(old.utime_jiffies)
                                    + current.stime_jiffies.saturating_sub(old.stime_jiffies)
                            }
                            None => 0,
                        };
                        ticks as f64 / USER_HZ / secs * 100.0
                    }
                    _ => 0.0,
                };
                processes.push(process_row(*pid, data, total_mem_bytes, cpu_percent));
            }
            self.prev = Some(Prev {
                at: now,
                pids: pids
                    .iter()
                    .filter_map(|(pid, data)| data.stat.as_ref().map(|stat| (*pid, *stat)))
                    .collect(),
            });

            Ok(Sample {
                timestamp_ms,
                hostname,
                cpu: Cpu {
                    cores: stat.cores,
                    frequency_mhz: Vec::new(),
                },
                memory: memory_from(meminfo),
                load_avg,
                uptime: Metric::available(uptime, Unit::Seconds),
                processes,
                disks,
                net,
                sensors: Sensors {
                    temps,
                    fans,
                    battery,
                },
            })
        }
    }

    /// Sorted file names of one directory, empty when it is absent.
    fn read_dir_names(path: &Path) -> Vec<String> {
        let Ok(entries) = fs::read_dir(path) else {
            return Vec::new();
        };
        let mut names: Vec<String> = entries
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    /// Sorted `(file name, contents)` pairs of one directory's files,
    /// skipping subdirectories and unreadable files.
    fn read_pairs(path: &Path) -> Vec<(String, String)> {
        let Ok(entries) = fs::read_dir(path) else {
            return Vec::new();
        };
        let mut pairs = Vec::new();
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                continue;
            }
            if let Ok(text) = fs::read_to_string(entry.path()) {
                pairs.push((entry.file_name().to_string_lossy().into_owned(), text));
            }
        }
        pairs.sort();
        pairs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proc_stat_parses_the_aggregate_away_and_orders_cores() {
        let text = "cpu  10 1 2 30 1 1 1 1 3 \
                    \ncpu1 1 0 1 4 0 0 0 0 0 \
                    \ncpu0 2 0 1 5 0 0 0 0 0 \
                    \nintr 123 \
                    \nctxt 456\n";
        let stat = parse_proc_stat(text).expect("stat parses");
        assert_eq!(stat.cores.len(), 2);
        assert_eq!(stat.cores[0].user, 0.02);
        assert_eq!(stat.cores[0].idle, 0.05);
        assert_eq!(stat.cores[1].user, 0.01);
    }

    #[test]
    fn proc_stat_rejects_gaps_and_bad_lines() {
        assert!(parse_proc_stat("cpu0 1 0 1 4 0 0 0 0 0\ncpu2 1 0 1 4 0 0 0 0 0\n").is_none());
        assert!(parse_proc_stat("cpu0 1 0 1\n").is_none());
        assert!(parse_proc_stat("cpuX 1 0 1 4 0 0 0 0 0\n").is_none());
        assert!(parse_proc_stat("intr 123\n").is_none());
        assert!(parse_proc_stat("").is_none());
    }

    #[test]
    fn meminfo_parses_kib_and_derives_available() {
        let text = "MemTotal:       16366640 kB \
                    \nMemFree:        12997176 kB \
                    \nMemAvailable:   14948708 kB \
                    \nBuffers:          137460 kB \
                    \nSwapTotal:       3145724 kB \
                    \nSwapFree:        3145724 kB \
                    \nHugePages_Total:       0\n";
        let mem = parse_proc_meminfo(text).expect("meminfo parses");
        assert_eq!(mem.total, 16366640 * 1024);
        assert_eq!(mem.available, 14948708 * 1024);
        assert_eq!(mem.free, Some(12997176 * 1024));
        assert_eq!(mem.swap_total, 3145724 * 1024);
        assert_eq!(mem.swap_free, 3145724 * 1024);
    }

    #[test]
    fn meminfo_falls_back_from_available_to_free() {
        let text = "MemTotal:       1000 kB\nMemFree:         250 kB\n";
        let mem = parse_proc_meminfo(text).expect("meminfo parses");
        assert_eq!(mem.available, 250 * 1024);
        let memory = memory_from(mem);
        assert_eq!(memory.used, Metric::available(750.0 * 1024.0, Unit::Bytes));
    }

    #[test]
    fn meminfo_needs_total() {
        assert!(parse_proc_meminfo("MemFree: 1 kB\n").is_none());
        assert!(parse_proc_meminfo("").is_none());
    }

    #[test]
    fn memory_metrics_map_from_meminfo() {
        let mem = ProcMem {
            total: 1000 * 1024,
            available: 800 * 1024,
            free: Some(700 * 1024),
            swap_total: 100 * 1024,
            swap_free: 60 * 1024,
        };
        let memory = memory_from(mem);
        assert_eq!(
            memory.total,
            Metric::available(1000.0 * 1024.0, Unit::Bytes)
        );
        assert_eq!(memory.used, Metric::available(200.0 * 1024.0, Unit::Bytes));
        assert_eq!(memory.free, Metric::available(700.0 * 1024.0, Unit::Bytes));
        assert_eq!(
            memory.swap_total,
            Metric::available(100.0 * 1024.0, Unit::Bytes)
        );
        assert_eq!(
            memory.swap_used,
            Metric::available(40.0 * 1024.0, Unit::Bytes)
        );
        assert_eq!(memory.compressed, Metric::unavailable(Unit::Bytes));
    }

    #[test]
    fn loadavg_needs_three_numbers() {
        assert_eq!(
            parse_proc_loadavg("1.93 0.57 0.20 1/269 3401\n"),
            Some([1.93, 0.57, 0.20])
        );
        assert!(parse_proc_loadavg("1.93 0.57\n").is_none());
        assert!(parse_proc_loadavg("a b c\n").is_none());
    }

    #[test]
    fn uptime_takes_the_first_field() {
        assert_eq!(parse_proc_uptime("61.77 110.52\n"), Some(61.77));
        assert_eq!(parse_proc_uptime("5\n"), Some(5.0));
        assert!(parse_proc_uptime("\n").is_none());
    }

    #[test]
    fn diskstats_converts_sectors_to_bytes() {
        let text = "   8       0 sda 18342 630 1474182 10527 7429 6385 7098027 44835 0 12520 55372 \
                    \n   8       1 sda1 154 13 1332 12 2 0 2 8 0 18 20 \
                    \nnot a diskstats line \
                    \n";
        let disks = parse_proc_diskstats(text);
        assert_eq!(disks.len(), 2);
        assert_eq!(disks[0].name, "sda");
        assert_eq!(disks[0].read_bytes, 1474182 * 512);
        assert_eq!(disks[0].write_bytes, 7098027 * 512);
        assert_eq!(disks[1].name, "sda1");
    }

    #[test]
    fn net_dev_parses_interfaces_and_skips_headers() {
        let text = "Inter-|   Receive                        \
                    \n face |bytes    packets errs drop fifo frame \
                    \n    lo: 34497 34071 0 0 0 0 0 0 34497 34071 0 0 0 0 0 0 \
                    \n  eth0: 265744198 29836 0 0 0 0 0 0 1193601 10693 0 0 0 0 0 0\n";
        let interfaces = parse_proc_net_dev(text);
        assert_eq!(interfaces.len(), 2);
        assert_eq!(interfaces[0].name, "lo");
        assert_eq!(interfaces[1].name, "eth0");
        assert_eq!(interfaces[1].rx_bytes, 265744198);
        assert_eq!(interfaces[1].rx_packets, 29836);
        assert_eq!(interfaces[1].tx_bytes, 1193601);
        assert_eq!(interfaces[1].tx_packets, 10693);
    }

    #[test]
    fn pid_status_reads_the_fields_collectors_use() {
        let text = "Name:\tproc-a-1 \
                    \nState:\tS (sleeping) \
                    \nPPid:\t0 \
                    \nUid:\t0\t0\t0\t0 \
                    \nVmSize:\t   25700 kB \
                    \nVmRSS:\t   17044 kB \
                    \nThreads:\t1\n";
        let status = parse_pid_status(text);
        assert_eq!(status.name, "proc-a-1");
        assert_eq!(status.state.as_deref(), Some("S"));
        assert_eq!(status.parent, Some(0));
        assert_eq!(status.uid, Some(0));
        assert_eq!(status.vm_size, 25700 * 1024);
        assert_eq!(status.vm_rss, 17044 * 1024);
        assert_eq!(status.threads, 1);
    }

    #[test]
    fn pid_status_tolerates_missing_fields() {
        let status = parse_pid_status("VmPeak:\t   100 kB\n");
        assert_eq!(status.name, "");
        assert_eq!(status.state, None);
        assert_eq!(status.parent, None);
        assert_eq!(status.uid, None);
        assert_eq!(status.threads, 0);
    }

    #[test]
    fn pid_stat_skips_the_parenthesised_command() {
        let line = "1 (proc-a-1) S 0 1 1 0 -1 4194560 37747 373471 29 1045 151 189 395 371 20 0 1 0 40 26316800 4140 18446744073709551615\n";
        let stat = parse_pid_stat(line).expect("stat parses");
        assert_eq!(stat.utime_jiffies, 151);
        assert_eq!(stat.stime_jiffies, 189);
    }

    #[test]
    fn pid_stat_handles_commands_with_parentheses() {
        let line = "7 ((sd-pam) ) S 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 44 70000 100 18446744073709551615\n";
        let stat = parse_pid_stat(line).expect("stat parses");
        assert_eq!(stat.utime_jiffies, 0);
        assert_eq!(stat.stime_jiffies, 0);
        assert!(parse_pid_stat("no parens here\n").is_none());
    }

    #[test]
    fn hwmon_groups_inputs_under_one_chip_label() {
        let files = vec![
            ("fan1_input".to_string(), "1200\n".to_string()),
            ("name".to_string(), "coretemp\n".to_string()),
            ("temp1_input".to_string(), "45000\n".to_string()),
            ("temp1_label".to_string(), "Package id 0\n".to_string()),
            ("temp2_input".to_string(), "41500\n".to_string()),
        ];
        let (temps, fans) = parse_hwmon("hwmon0", &files);
        assert_eq!(temps.len(), 2);
        assert_eq!(temps[0].label, "Package id 0");
        assert_eq!(temps[0].celsius, Metric::available(45.0, Unit::Celsius));
        assert_eq!(temps[1].label, "coretemp");
        assert_eq!(temps[1].celsius, Metric::available(41.5, Unit::Celsius));
        assert_eq!(fans.len(), 1);
        assert_eq!(fans[0].label, "coretemp");
        assert_eq!(
            fans[0].rpm,
            Metric::available(1200.0, Unit::RevolutionsPerMinute)
        );
    }

    #[test]
    fn hwmon_ignores_non_input_and_garbage_files() {
        let files = vec![
            ("temp1_max".to_string(), "90000\n".to_string()),
            ("temp2_input".to_string(), "not a number\n".to_string()),
            ("power1_input".to_string(), "1000\n".to_string()),
        ];
        let (temps, fans) = parse_hwmon("acpitz", &files);
        assert!(temps.is_empty());
        assert!(fans.is_empty());
    }

    #[test]
    fn power_supply_reads_capacity_and_power() {
        let files = vec![
            ("capacity".to_string(), "80\n".to_string()),
            ("power_now".to_string(), "12000000\n".to_string()),
            ("status".to_string(), "Discharging\n".to_string()),
        ];
        let battery = parse_power_supply(&files).expect("a battery");
        assert_eq!(battery.percent, Metric::available(80.0, Unit::Percent));
        assert_eq!(battery.power_watts, Metric::available(12.0, Unit::Watts));
        assert_eq!(battery.state, BatteryState::Discharging);
    }

    #[test]
    fn power_supply_tolerates_missing_files() {
        let files = vec![("capacity".to_string(), "55\n".to_string())];
        let battery = parse_power_supply(&files).expect("a battery");
        assert_eq!(battery.power_watts, Metric::unavailable(Unit::Watts));
        assert_eq!(battery.state, BatteryState::Unknown);

        // A mains adapter has no capacity and is not a battery.
        let files = vec![("online".to_string(), "1\n".to_string())];
        assert!(parse_power_supply(&files).is_none());
    }

    #[test]
    fn battery_state_maps_known_words() {
        assert_eq!(battery_state("Charging\n"), BatteryState::Charging);
        assert_eq!(battery_state("Discharging\n"), BatteryState::Discharging);
        assert_eq!(battery_state("Full\n"), BatteryState::Full);
        assert_eq!(battery_state("Unknown\n"), BatteryState::Unknown);
    }

    #[test]
    fn pid_entry_names_split_into_pid_and_kind() {
        assert_eq!(split_pid_entry("proc-1-stat"), Some((1, "stat")));
        assert_eq!(split_pid_entry("proc-42-cmdline"), Some((42, "cmdline")));
        assert_eq!(split_pid_entry("proc-stat"), None);
        assert_eq!(split_pid_entry("proc-sys-kernel-osrelease"), None);
        assert_eq!(split_pid_entry("proc-1-mounts"), None);
        assert_eq!(split_pid_entry("proc--stat"), None);
    }

    #[test]
    fn process_row_uses_status_and_comm() {
        let status = PidStatus {
            name: "proc-a-1".to_string(),
            state: Some("S".to_string()),
            parent: Some(0),
            uid: Some(0),
            vm_size: 25700 * 1024,
            vm_rss: 17044 * 1024,
            threads: 1,
        };
        let data = PidData {
            status: Some(status),
            stat: None,
            comm: Some("proc-a-1\n".to_string()),
        };
        let row = process_row(1, &data, 16366640 * 1024, 0.0);
        assert_eq!(row.pid, 1);
        assert_eq!(row.name, "proc-a-1");
        assert_eq!(row.state, "S");
        assert_eq!(row.user, "0");
        assert_eq!(row.parent, Some(0));
        assert_eq!(row.virtual_bytes, 25700 * 1024);
        assert_eq!(row.resident_bytes, 17044 * 1024);
        assert_eq!(row.threads, 1);
    }

    #[test]
    fn process_row_falls_back_to_comm() {
        let data = PidData {
            status: None,
            stat: None,
            comm: Some("worker-a\n".to_string()),
        };
        let row = process_row(9, &data, 1000 * 1024, 0.0);
        assert_eq!(row.name, "worker-a");
        assert_eq!(row.state, "?");
        assert_eq!(row.user, "?");
        assert_eq!(row.parent, None);
    }

    #[test]
    fn process_row_falls_back_when_names_are_missing() {
        let data = PidData::default();
        let row = process_row(42, &data, 0, 0.0);
        assert_eq!(row.name, "pid-42");
        assert_eq!(row.state, "?");
        assert_eq!(row.user, "?");
        assert_eq!(row.parent, None);
        assert_eq!(row.mem_percent, 0.0);
    }
}
