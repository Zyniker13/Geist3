// SPDX-License-Identifier: MIT OR Apache-2.0
//! The macOS side of ztop-core: text parsers over the recorded capture
//! entries and the fixture replay path.
//!
//! The live macOS collector reads sysctl, Mach and libproc (see
//! `capture_macos`); the recorded capture carries the same values as
//! plain text. Parsing is pure text work, so the fixture tests run on
//! every machine, not just macOS.
//!
//! Units, documented once here:
//!
//! - `hostinfo` CPU ticks are `host_statistics64` counters, which the
//!   kernel increments at the BSD scheduler tick rate of 100 Hz (read
//!   unprivileged from `kern.clockrate`); seconds are ticks divided by
//!   100.
//! - `processes` CPU fields are cumulative CPU nanoseconds, converted at
//!   capture time from mach absolute-time ticks via
//!   `mach_timebase_info`; a process whose task info the kernel denied
//!   (another user's process, read without privileges) records `-` for
//!   all four task fields.
//! - Memory and swap fields are bytes. "Used" memory is wired plus
//!   active plus compressed, the memory that actually holds data.

use std::path::Path;

use crate::fixture::Fixture;
use crate::linux::{FixtureSampleError, bad_source, missing_source};
use crate::model::{
    AppleSilicon, Cpu, CpuRates, CpuTimes, Memory, Metric, Process, ProcessIo, Sample, Sensors,
    Unit,
};

/// BSD scheduler tick rate in hertz, the rate `host_statistics64` CPU
/// ticks are counted at. Confirmed unprivileged via `kern.clockrate`.
const HOST_TICK_HZ: f64 = 100.0;

/// Per-core CPU tick counters from the `hostinfo` entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CoreTicks {
    pub core: u32,
    pub user: u64,
    pub system: u64,
    pub idle: u64,
    pub nice: u64,
}

/// Mach virtual-memory statistics from the `hostinfo` entry, in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VmStats {
    pub free: u64,
    pub active: u64,
    pub inactive: u64,
    pub wired: u64,
    pub compressed: u64,
}

/// Swap usage from the `hostinfo` entry, in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SwapStats {
    pub total: u64,
    pub avail: u64,
    pub used: u64,
}

/// Host values parsed from the `hostinfo` capture entry.
///
/// A field stays `None` when the entry lacks it; `sample_from_fixture`
/// requires the parts the model needs.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct HostInfo {
    /// Per-core ticks, sorted by core number.
    pub cores: Vec<CoreTicks>,
    /// 1, 5 and 15 minute load averages in fixed point, scaled by 1000.
    pub load_avg: Option<[u64; 3]>,
    pub vm: Option<VmStats>,
    pub swap: Option<SwapStats>,
    /// `(seconds, microseconds)` of the boot time.
    pub boottime: Option<(u64, u64)>,
}

/// One recorded process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacProcess {
    pub pid: u32,
    pub ppid: u32,
    /// Raw `pbsi_status` from `proc_bsdshortinfo`; on modern XNU most
    /// in-memory processes report 2 (`SRUN`), because fine-grained state
    /// lives in the threads, not the process.
    pub status: u32,
    pub uid: u32,
    /// Cumulative task usage when the kernel allowed the read, `None`
    /// when the capture recorded `-` for all four fields.
    pub task: Option<TaskUsage>,
    /// Virtual memory size in bytes (task.virtual_size), when available.
    pub vsize: Option<u64>,
    /// Scheduling priority (task.priority), when available.
    pub priority: Option<i32>,
    /// Nice value (proc_bsdinfo.nice), when available.
    pub nice: Option<i32>,
    /// Wall-clock start time in Unix seconds (proc_bsdinfo.start_tvsec),
    /// when available.
    pub start_secs: Option<u64>,
    pub name: String,
    /// Executable path (libproc `proc_pidpath`), when the capture could
    /// read it; the closest an unprivileged reader gets to a command line.
    pub command: Option<String>,
}

/// Cumulative task usage of one process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TaskUsage {
    /// Total user CPU time in nanoseconds.
    pub utime_ns: u64,
    /// Total system CPU time in nanoseconds.
    pub stime_ns: u64,
    /// Resident set size in bytes.
    pub rss_bytes: u64,
    pub threads: u32,
}

/// Parses the recorded `hostinfo` entry.
///
/// Well-formed lines fill the corresponding field; unknown or malformed
/// lines are ignored, and [`HostInfo::cores`] ends up sorted by core
/// number regardless of the capture's ordering.
pub fn parse_hostinfo(text: &str) -> HostInfo {
    let mut info = HostInfo::default();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        match fields.next() {
            Some("ticks") => {
                if let Some(ticks) = unsigned_fields::<u64, 5>(&mut fields) {
                    info.cores.push(CoreTicks {
                        core: ticks[0] as u32,
                        user: ticks[1],
                        system: ticks[2],
                        idle: ticks[3],
                        nice: ticks[4],
                    });
                }
            }
            Some("loadavg") => {
                if let Some(avg) = unsigned_fields::<u64, 3>(&mut fields) {
                    info.load_avg = Some([avg[0], avg[1], avg[2]]);
                }
            }
            Some("boottime") => {
                if let Some(time) = unsigned_fields::<u64, 2>(&mut fields) {
                    info.boottime = Some((time[0], time[1]));
                }
            }
            Some("vm") => {
                if let Some(stats) = parse_pairs(
                    &mut fields,
                    ["free", "active", "inactive", "wired", "compressed"],
                ) {
                    info.vm = Some(VmStats {
                        free: stats[0],
                        active: stats[1],
                        inactive: stats[2],
                        wired: stats[3],
                        compressed: stats[4],
                    });
                }
            }
            Some("swap") => {
                if let Some(stats) = parse_pairs(&mut fields, ["total", "avail", "used"]) {
                    info.swap = Some(SwapStats {
                        total: stats[0],
                        avail: stats[1],
                        used: stats[2],
                    });
                }
            }
            _ => {}
        }
    }
    info.cores.sort_unstable_by_key(|ticks| ticks.core);
    info
}

/// Consumes exactly `N` whitespace-separated unsigned fields.
fn unsigned_fields<T: std::str::FromStr + std::marker::Copy, const N: usize>(
    fields: &mut dyn Iterator<Item = &str>,
) -> Option<[T; N]> {
    let mut out = [None; N];
    for slot in out.iter_mut() {
        *slot = Some(fields.next()?.parse().ok()?);
    }
    Some(out.map(|slot| slot.unwrap()))
}

/// Parses `key value` pairs into a fixed-size array, in the order the
/// keys are listed. Every key must appear exactly once.
fn parse_pairs<const N: usize>(
    fields: &mut dyn Iterator<Item = &str>,
    keys: [&str; N],
) -> Option<[u64; N]> {
    let mut out = [0u64; N];
    let mut seen = [false; N];
    while let (Some(key), Some(value)) = (fields.next(), fields.next()) {
        let slot = keys.iter().position(|known| known == &key)?;
        out[slot] = value.parse().ok()?;
        seen[slot] = true;
    }
    if seen.iter().all(|seen| *seen) {
        Some(out)
    } else {
        None
    }
}

/// Parses the recorded `processes` entry, one [`MacProcess`] per
/// well-formed line, in the recorded order.
///
/// A line is well-formed when the eight leading fields parse and the
/// name is the trailing quoted string (optionally followed by a second
/// quoted executable path); quoted names may contain spaces. The four
/// task fields must be all `-` (denied) or all numbers; the capture
/// never writes a mix.
pub fn parse_processes(text: &str) -> Vec<MacProcess> {
    text.lines().filter_map(parse_process_line).collect()
}

/// Maps the BSD process status byte to the letter `ps` prints: 1
/// (`SIDL`) →I, 2 (`SRUN`) →R, 3 (`SSLEEP`) →S, 4 (`SSTOP`) →T, 5
/// (`SZOMB`) →Z; the rarely seen wait/lock states collapse to U.
fn status_letter(status: u32) -> &'static str {
    match status {
        1 => "I",
        2 => "R",
        3 => "S",
        4 => "T",
        5 => "Z",
        _ => "U",
    }
}

/// Parses one `processes` line: `pid ppid status uid utime stime rss
/// threads "name"` (8 fields), the same with `vsize priority nice start`
/// (12 fields), or either with a trailing `"path"` — the executable path
/// the capture read with `proc_pidpath`. Names and paths are scrubbed of
/// quotes and backslashes by the capture, so each quoted tail is one
/// field.
fn parse_process_line(line: &str) -> Option<MacProcess> {
    let (prefix, quoted) = line.split_once(" \"")?;
    let (name, command) = match quoted.rsplit_once("\" \"") {
        Some((name, path)) => {
            let path = path.strip_suffix('"')?;
            let command = if path.is_empty() { None } else { Some(path) };
            (name, command)
        }
        None => (quoted.strip_suffix('"')?, None),
    };
    let mut fields = prefix.split_whitespace();
    let pid = fields.next()?.parse().ok()?;
    let ppid = fields.next()?.parse().ok()?;
    let status = fields.next()?.parse().ok()?;
    let uid = fields.next()?.parse().ok()?;
    let rest: Vec<&str> = fields.collect();
    if rest.len() != 4 && rest.len() != 8 {
        return None;
    }
    let task = if rest[..4].iter().all(|field| *field == "-") {
        None
    } else {
        Some(TaskUsage {
            utime_ns: rest[0].parse().ok()?,
            stime_ns: rest[1].parse().ok()?,
            rss_bytes: rest[2].parse().ok()?,
            threads: rest[3].parse().ok()?,
        })
    };
    let (vsize, priority, nice, start_secs) = if rest.len() == 8 {
        (
            rest[4].parse().ok(),
            rest[5].parse().ok(),
            rest[6].parse().ok(),
            rest[7].parse().ok(),
        )
    } else {
        (None, None, None, None)
    };
    Some(MacProcess {
        pid,
        ppid,
        status,
        uid,
        task,
        vsize,
        priority,
        nice,
        start_secs,
        name: name.to_string(),
        command: command.map(str::to_string),
    })
}

/// Builds a [`Sample`] from a recorded macOS fixture directory.
///
/// Like the Linux path, the hostname comes from the directory name, the
/// timestamp from the manifest, and per-process CPU percentages are 0.0
/// because a lone snapshot has no interval to measure against. Uptime is
/// derived from the recorded boot time and the manifest timestamp, which
/// keeps replay machine-independent.
///
/// # Errors
///
/// Returns [`FixtureSampleError`] when reading the fixture fails, a
/// required source is missing, or a required source does not parse.
pub fn sample_from_fixture(dir: &Path) -> Result<Sample, FixtureSampleError> {
    let fixture = Fixture::open(dir)?;
    let mut host = HostInfo::default();
    let mut procs = Vec::new();
    let mut memsize = None;
    let mut have_hostinfo = false;
    let mut have_processes = false;

    for name in fixture.entry_names() {
        let text = fixture.entry_text(name)?;
        match name {
            "hostinfo" => {
                have_hostinfo = true;
                host = parse_hostinfo(&text);
            }
            "processes" => {
                have_processes = true;
                procs = parse_processes(&text);
            }
            "sysctl-hw_memsize" => memsize = text.trim().parse::<u64>().ok(),
            _ => {}
        }
    }

    if !have_hostinfo {
        return Err(missing_source("hostinfo"));
    }
    if host.cores.is_empty() {
        return Err(bad_source("hostinfo"));
    }
    let memsize = match memsize {
        Some(bytes) => bytes,
        None if fixture.entry_names().any(|n| n == "sysctl-hw_memsize") => {
            return Err(bad_source("sysctl-hw_memsize"));
        }
        None => return Err(missing_source("sysctl-hw_memsize")),
    };
    if !have_processes {
        return Err(missing_source("processes"));
    }

    sample_from_parts(
        host,
        procs,
        memsize,
        dir.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown"),
        // Recorded macOS fixtures do not carry the system string yet;
        // the header omits it rather than guessing.
        "",
        fixture.manifest().captured_at_unix * 1000,
        CpuRates {
            busy_percent: Vec::new(),
            state_percent: Vec::new(),
        },
    )
    .map_err(|_| bad_source("hostinfo"))
}

/// Converts core tick counters into [`CpuTimes`] seconds at the recorded
/// tick rate; shared by the fixture replay and the live collector, so both
/// scale the counters identically.
pub(crate) fn core_times(cores: &[CoreTicks]) -> Vec<CpuTimes> {
    cores
        .iter()
        .map(|ticks| {
            let seconds = |value: u64| value as f64 / HOST_TICK_HZ;
            CpuTimes {
                user: seconds(ticks.user),
                system: seconds(ticks.system),
                nice: seconds(ticks.nice),
                idle: seconds(ticks.idle),
                ..CpuTimes::default()
            }
        })
        .collect()
}

/// A required field a parsed macOS source did not provide.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SourceError {
    /// The entry or sysctl the field belongs to, as the capture names it.
    pub(crate) origin: &'static str,
    /// The field the source lacked.
    pub(crate) what: &'static str,
}

/// Assembles a [`Sample`] from parsed macOS sources — the shared tail of
/// the fixture replay and the live collector (decision 0010), so both
/// interpret the recorded text identically. `rates` carries the per-core
/// busy percentages and their per-state shares measured between two
/// samples; the fixture replay has no interval and passes empty vectors,
/// which become zeros. Uptime is the timestamp minus the host's boot time.
///
/// # Errors
///
/// Returns a [`SourceError`] when a required `hostinfo` field is absent.
pub(crate) fn sample_from_parts(
    host: HostInfo,
    procs: Vec<MacProcess>,
    memsize: u64,
    hostname: &str,
    system: &str,
    timestamp_ms: u64,
    rates: CpuRates,
) -> Result<Sample, SourceError> {
    if host.cores.is_empty() {
        return Err(SourceError {
            origin: "hostinfo",
            what: "CPU tick counters",
        });
    }
    let vm = host.vm.ok_or(SourceError {
        origin: "hostinfo",
        what: "vm counters",
    })?;
    let swap = host.swap.ok_or(SourceError {
        origin: "hostinfo",
        what: "swap counters",
    })?;
    let load_avg = host.load_avg.ok_or(SourceError {
        origin: "hostinfo",
        what: "load average",
    })?;
    let (boot_sec, boot_usec) = host.boottime.ok_or(SourceError {
        origin: "hostinfo",
        what: "boot time",
    })?;

    let cores = core_times(&host.cores);
    let total_mem = memsize as f64;
    let processes: Vec<Process> = procs
        .iter()
        .map(|mac| {
            let (resident, threads, mem_percent) = match mac.task {
                Some(usage) => {
                    let percent = if total_mem > 0.0 {
                        usage.rss_bytes as f64 / total_mem * 100.0
                    } else {
                        0.0
                    };
                    (usage.rss_bytes, usage.threads, percent)
                }
                None => (0, 0, 0.0),
            };
            Process {
                pid: mac.pid,
                parent: Some(mac.ppid),
                user: mac.uid.to_string(),
                state: status_letter(mac.status).to_string(),
                name: mac.name.clone(),
                cpu_percent: 0.0,
                mem_percent,
                virtual_bytes: mac.vsize.unwrap_or(0),
                resident_bytes: resident,
                threads,
                priority: mac.priority,
                nice: mac.nice,
                shared_bytes: None,
                total_time_ns: mac.task.map(|t| t.utime_ns + t.stime_ns),
                start_time_secs: mac.start_secs,
                processor: None,
                command: mac.command.clone(),
                is_thread: false,
                kernel_thread: false,
                io: ProcessIo::default(),
            }
        })
        .collect();
    let uptime_secs =
        (timestamp_ms as f64 / 1000.0 - boot_sec as f64 - boot_usec as f64 / 1_000_000.0).max(0.0);

    Ok(Sample {
        timestamp_ms,
        hostname: hostname.to_string(),
        system: system.to_string(),
        cpu: Cpu {
            busy_percent: if rates.busy_percent.len() == cores.len() {
                rates.busy_percent
            } else {
                vec![0.0; cores.len()]
            },
            state_percent: if rates.state_percent.len() == cores.len() {
                rates.state_percent
            } else {
                vec![CpuTimes::default(); cores.len()]
            },
            cores,
            frequency_mhz: Vec::new(),
        },
        memory: Memory {
            total: Metric::available(total_mem, Unit::Bytes),
            used: Metric::available((vm.wired + vm.active + vm.compressed) as f64, Unit::Bytes),
            free: Metric::available(vm.free as f64, Unit::Bytes),
            buffers: Metric::unavailable(Unit::Bytes),
            shared: Metric::unavailable(Unit::Bytes),
            cache: Metric::unavailable(Unit::Bytes),
            swap_total: Metric::available(swap.total as f64, Unit::Bytes),
            swap_used: Metric::available(swap.used as f64, Unit::Bytes),
            compressed: Metric::available(vm.compressed as f64, Unit::Bytes),
        },
        load_avg: [
            load_avg[0] as f64 / 1000.0,
            load_avg[1] as f64 / 1000.0,
            load_avg[2] as f64 / 1000.0,
        ],
        uptime: Metric::available(uptime_secs, Unit::Seconds),
        threads: Metric::available(
            processes.iter().map(|process| process.threads as f64).sum(),
            Unit::Count,
        ),
        kernel_threads: Metric::unavailable(Unit::Count),
        processes,
        disks: Vec::new(),
        net: Vec::new(),
        sensors: Sensors::default(),
        apple_silicon: AppleSilicon::default(),
        pressure: None,
    })
}

// ── Apple Silicon topology ───────────────────────────────────────────

/// Chip identity and core-type counts parsed from perflevel sysctls.
///
/// Pure so tests cover the parsing without a live machine; the live
/// reader (`apple_silicon_topology`) only feeds it sysctl values.
/// Compiled on macOS and in tests: elsewhere there is no caller, and
/// dead code fails the clippy gate.
#[cfg(any(target_os = "macos", test))]
pub(crate) struct ChipTopology {
    pub(crate) chip_name: Option<String>,
    pub(crate) e_cores: Option<u64>,
    pub(crate) p_cores: Option<u64>,
}

/// Classify perflevel sysctl values into chip name and core-type counts.
///
/// Real Apple Silicon reports `hw.perflevel0.name` = "Performance" and
/// `hw.perflevel1.name` = "Efficiency"; a level is only counted when its
/// name says so, so a VM advertising other names ("Super") contributes
/// nothing instead of a wrong count. A non-Apple brand leaves the chip
/// name unset — Intel Macs get no Apple Silicon data at all.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn parse_chip_topology(brand: Option<&str>, levels: &[(&str, u64)]) -> ChipTopology {
    let chip_name = brand
        .filter(|name| name.starts_with("Apple"))
        .map(|name| name.to_string());
    let mut e_cores = None;
    let mut p_cores = None;
    for (name, count) in levels {
        if name.contains("Performance") {
            p_cores = Some(*count);
        } else if name.contains("Efficiency") {
            e_cores = Some(*count);
        }
    }
    ChipTopology {
        chip_name,
        e_cores,
        p_cores,
    }
}

/// Read the chip topology live from sysctls. macOS only; the pure
/// parser above carries the logic and the tests.
#[cfg(target_os = "macos")]
pub(crate) fn apple_silicon_topology() -> AppleSilicon {
    let brand = crate::capture_macos::sysctl_text("machdep.cpu.brand_string");
    let mut levels: Vec<(String, u64)> = Vec::new();
    for level in 0..4u64 {
        let name = crate::capture_macos::sysctl_text(&format!("hw.perflevel{level}.name"));
        let count = crate::capture_macos::sysctl_u64(&format!("hw.perflevel{level}.logicalcpu"));
        match (name, count) {
            (Some(name), Some(count)) => levels.push((name, count)),
            _ => break,
        }
    }
    let borrowed: Vec<(&str, u64)> = levels
        .iter()
        .map(|(name, count)| (name.as_str(), *count))
        .collect();
    let topology = parse_chip_topology(brand.as_deref(), &borrowed);
    AppleSilicon {
        chip_name: topology.chip_name,
        e_core_count: topology.e_cores.map_or_else(
            || Metric::unavailable(Unit::Count),
            |count| Metric::available(count as f64, Unit::Count),
        ),
        p_core_count: topology.p_cores.map_or_else(
            || Metric::unavailable(Unit::Count),
            |count| Metric::available(count as f64, Unit::Count),
        ),
        ..AppleSilicon::default()
    }
}

#[cfg(test)]
mod chip_topology_tests {
    use super::*;

    #[test]
    fn standard_levels_map_to_p_and_e_counts() {
        let topology = parse_chip_topology(
            Some("Apple M3 Pro"),
            &[("Performance", 6), ("Efficiency", 6)],
        );
        assert_eq!(topology.chip_name.as_deref(), Some("Apple M3 Pro"));
        assert_eq!(topology.p_cores, Some(6));
        assert_eq!(topology.e_cores, Some(6));
    }

    #[test]
    fn unknown_level_names_contribute_nothing() {
        // A VM may advertise names that are neither Performance nor
        // Efficiency; counting them would be a lie.
        let topology = parse_chip_topology(Some("Apple M6"), &[("Super", 2), ("Performance", 4)]);
        assert_eq!(topology.chip_name.as_deref(), Some("Apple M6"));
        assert_eq!(topology.p_cores, Some(4));
        assert_eq!(topology.e_cores, None);
    }

    #[test]
    fn a_non_apple_brand_gets_no_silicon_data() {
        let topology = parse_chip_topology(Some("Intel Core i9"), &[("Performance", 8)]);
        assert_eq!(topology.chip_name, None);
        // Core counts stay set — they are still perflevel counts — but
        // the screen is hidden without a chip name.
        assert_eq!(topology.p_cores, Some(8));
    }

    #[test]
    fn a_missing_brand_leaves_everything_unset() {
        let topology = parse_chip_topology(None, &[("Performance", 8), ("Efficiency", 4)]);
        assert_eq!(topology.chip_name, None);
        assert_eq!(topology.p_cores, Some(8));
        assert_eq!(topology.e_cores, Some(4));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hostinfo_parses_every_group() {
        let text = "ticks 1 10 20 30 40\n\
                    loadavg 1500 2500 3500\n\
                    vm free 1 active 2 inactive 3 wired 4 compressed 5\n\
                    swap total 10 avail 3 used 7\n\
                    boottime 1000 500000\n";
        let info = parse_hostinfo(text);
        assert_eq!(info.cores.len(), 1);
        assert_eq!(
            info.cores[0],
            CoreTicks {
                core: 1,
                user: 10,
                system: 20,
                idle: 30,
                nice: 40
            }
        );
        assert_eq!(info.load_avg, Some([1500, 2500, 3500]));
        assert_eq!(
            info.vm,
            Some(VmStats {
                free: 1,
                active: 2,
                inactive: 3,
                wired: 4,
                compressed: 5
            })
        );
        assert_eq!(
            info.swap,
            Some(SwapStats {
                total: 10,
                avail: 3,
                used: 7
            })
        );
        assert_eq!(info.boottime, Some((1000, 500_000)));
    }

    #[test]
    fn hostinfo_sorts_cores_and_skips_unknown_lines() {
        let text = "note something else\n\
                    ticks 2 1 1 1 1\n\
                    ticks 0 2 2 2 2\n";
        let info = parse_hostinfo(text);
        assert_eq!(
            info.cores,
            vec![
                CoreTicks {
                    core: 0,
                    user: 2,
                    system: 2,
                    idle: 2,
                    nice: 2
                },
                CoreTicks {
                    core: 2,
                    user: 1,
                    system: 1,
                    idle: 1,
                    nice: 1
                },
            ]
        );
        assert_eq!(info.load_avg, None);
        assert_eq!(info.vm, None);
        assert_eq!(info.swap, None);
        assert_eq!(info.boottime, None);
    }

    #[test]
    fn vm_line_with_a_missing_key_is_rejected() {
        let info = parse_hostinfo("vm free 1 active 2 wired 4 compressed 5\n");
        assert_eq!(info.vm, None);
    }

    #[test]
    fn processes_parse_both_recorded_shapes() {
        let text = "0 0 2 0 - - - - \"kernel_task\"\n\
                    58372 1 2 502 580186517500 789640461958 34619392 7 \"Safari\"\n\
                    600 1 2 502 100 200 4096 3 268435456 20 10 1700000000 \"new\"\n";
        let procs = parse_processes(text);
        assert_eq!(procs.len(), 3);
        assert_eq!(procs[0].pid, 0);
        assert_eq!(procs[0].task, None);
        assert_eq!(procs[0].name, "kernel_task");
        assert_eq!(procs[1].uid, 502);
        assert_eq!(
            procs[1].task,
            Some(TaskUsage {
                utime_ns: 580_186_517_500,
                stime_ns: 789_640_461_958,
                rss_bytes: 34_619_392,
                threads: 7
            })
        );
        // The extended capture shape carries the M3 columns after the
        // task block: vsize, priority, nice, start.
        assert_eq!(procs[2].vsize, Some(268_435_456));
        assert_eq!(procs[2].priority, Some(20));
        assert_eq!(procs[2].nice, Some(10));
        assert_eq!(procs[2].start_secs, Some(1_700_000_000));
    }

    #[test]
    fn process_names_may_contain_spaces() {
        let procs = parse_processes("7 1 2 0 - - - - \"Window Server\"\n");
        assert_eq!(procs[0].name, "Window Server");
        assert_eq!(procs[0].command, None);
    }

    #[test]
    fn a_quoted_path_tail_becomes_the_command() {
        // The capture appends the executable path (`proc_pidpath`) as a
        // second quoted field; names and paths are scrubbed of quotes and
        // backslashes, so each quoted tail is one field.
        let procs = parse_processes(
            "12 1 2 501 100 200 4096 3 \"Safari\" \"/Applications/Safari.app/Contents/MacOS/Safari\"\n",
        );
        assert_eq!(procs[0].name, "Safari");
        assert_eq!(
            procs[0].command,
            Some("/Applications/Safari.app/Contents/MacOS/Safari".to_string())
        );
        // Legacy captures without the path leave the command unavailable.
        let legacy = parse_processes("13 1 2 501 100 200 4096 3 \"no path\"\n");
        assert_eq!(legacy[0].name, "no path");
        assert_eq!(legacy[0].command, None);
        // An empty quoted path means the read failed, not an empty command.
        let empty = parse_processes("14 1 2 501 100 200 4096 3 \"no path\" \"\"\n");
        assert_eq!(empty[0].command, None);
    }

    #[test]
    fn malformed_process_lines_are_dropped() {
        // A mixed task block (some `-`, some numbers) and a missing quote
        // are both malformed; the capture never writes either.
        let text = "1 0 2 0 - 5 - - \"half\"\n\
                    2 0 2 0 - - - - \"unclosed\n\
                    3 0 2 0 - - - - \"ok\"\n";
        let procs = parse_processes(text);
        assert_eq!(procs.len(), 1);
        assert_eq!(procs[0].pid, 3);
    }

    #[test]
    fn status_letter_maps_the_common_states() {
        assert_eq!(status_letter(1), "I");
        assert_eq!(status_letter(2), "R");
        assert_eq!(status_letter(3), "S");
        assert_eq!(status_letter(4), "T");
        assert_eq!(status_letter(5), "Z");
        assert_eq!(status_letter(7), "U");
    }
}
