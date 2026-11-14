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
use crate::model::{Cpu, CpuTimes, Memory, Metric, Process, Sample, Sensors, Unit};

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
    pub name: String,
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
/// name is the trailing quoted string; quoted names may contain spaces.
/// The four task fields must be all `-` (denied) or all numbers; the
/// capture never writes a mix.
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
/// threads "name"`.
fn parse_process_line(line: &str) -> Option<MacProcess> {
    let (prefix, quoted) = line.split_once(" \"")?;
    let name = quoted.strip_suffix('"')?;
    let mut fields = prefix.split_whitespace();
    let pid = fields.next()?.parse().ok()?;
    let ppid = fields.next()?.parse().ok()?;
    let status = fields.next()?.parse().ok()?;
    let uid = fields.next()?.parse().ok()?;
    let rest: Vec<&str> = fields.collect();
    if rest.len() != 4 {
        return None;
    }
    let task = if rest.iter().all(|field| *field == "-") {
        None
    } else {
        Some(TaskUsage {
            utime_ns: rest[0].parse().ok()?,
            stime_ns: rest[1].parse().ok()?,
            rss_bytes: rest[2].parse().ok()?,
            threads: rest[3].parse().ok()?,
        })
    };
    Some(MacProcess {
        pid,
        ppid,
        status,
        uid,
        task,
        name: name.to_string(),
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
        fixture.manifest().captured_at_unix * 1000,
        Vec::new(),
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
/// interpret the recorded text identically. `cpu_busy` carries per-core
/// busy percentages measured between two samples; the fixture replay has
/// no interval and passes an empty vector, which becomes zeros. Uptime is
/// the timestamp minus the host's boot time.
///
/// # Errors
///
/// Returns a [`SourceError`] when a required `hostinfo` field is absent.
pub(crate) fn sample_from_parts(
    host: HostInfo,
    procs: Vec<MacProcess>,
    memsize: u64,
    hostname: &str,
    timestamp_ms: u64,
    cpu_busy: Vec<f64>,
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
                virtual_bytes: 0,
                resident_bytes: resident,
                threads,
            }
        })
        .collect();
    let uptime_secs =
        (timestamp_ms as f64 / 1000.0 - boot_sec as f64 - boot_usec as f64 / 1_000_000.0).max(0.0);

    Ok(Sample {
        timestamp_ms,
        hostname: hostname.to_string(),
        cpu: Cpu {
            busy_percent: if cpu_busy.len() == cores.len() {
                cpu_busy
            } else {
                vec![0.0; cores.len()]
            },
            cores,
            frequency_mhz: Vec::new(),
        },
        memory: Memory {
            total: Metric::available(total_mem, Unit::Bytes),
            used: Metric::available((vm.wired + vm.active + vm.compressed) as f64, Unit::Bytes),
            free: Metric::available(vm.free as f64, Unit::Bytes),
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
        processes,
        disks: Vec::new(),
        net: Vec::new(),
        sensors: Sensors::default(),
    })
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
                    58372 1 2 502 580186517500 789640461958 34619392 7 \"Safari\"\n";
        let procs = parse_processes(text);
        assert_eq!(procs.len(), 2);
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
    }

    #[test]
    fn process_names_may_contain_spaces() {
        let procs = parse_processes("7 1 2 0 - - - - \"Window Server\"\n");
        assert_eq!(procs[0].name, "Window Server");
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
