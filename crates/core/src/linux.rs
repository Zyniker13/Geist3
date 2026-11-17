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
//!   on some kernels; a block without a `cpu MHz` line reports
//!   unavailable.
//! - The first sample of a live collector cannot know an interval, so
//!   process CPU percentages start at 0.0 and later samples report the
//!   share of wall time since the previous sample, like `htop`.

use std::collections::BTreeMap;
use std::path::Path;

use crate::fixture::{Fixture, FixtureError};
#[cfg(any(target_os = "linux", test))]
use crate::model::core_percents;
use crate::model::{
    AppleSilicon, Container, Cpu, CpuTimes, Disk, Memory, Metric, NetIf, Pressure, Process,
    ProcessIo, Psi, PsiAvg, Sample, Sensors, Unit,
};
#[cfg(any(target_os = "linux", test))]
use crate::model::{Battery, BatteryState, Fan, TempSensor};

/// Jiffies per second: the fixed `USER_HZ` of the kernel/user ABI.
const USER_HZ: f64 = 100.0;

/// Parsed `/proc/stat`: one [`CpuTimes`] per core, ordered by core number,
/// plus the boot time (`btime`) when the line is present.
#[derive(Debug, Clone, Default)]
pub struct ProcStat {
    pub(crate) cores: Vec<CpuTimes>,
    /// Boot time in Unix seconds; `None` when the `btime` line is
    /// missing, which turns every start time unavailable.
    pub(crate) btime: Option<u64>,
}

/// Parses `/proc/stat` into per-core CPU times.
///
/// Returns `None` when the text has no core lines, when a core line does
/// not parse, or when core numbers have gaps or duplicates: a collector
/// must not silently drop part of a source. The aggregate `cpu` line and
/// every non-CPU line are ignored; the aggregate's kernel-side accounting
/// does not reliably equal the sum of the cores, so the collector only
/// reports per-core times.
pub fn parse_proc_stat(text: &str) -> Option<ProcStat> {
    let mut cores: Vec<(usize, CpuTimes)> = Vec::new();
    let mut btime = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("btime ") {
            btime = rest.trim().parse().ok();
            continue;
        }
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
        btime,
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
pub struct ProcMem {
    pub(crate) total: u64,
    pub(crate) available: u64,
    pub(crate) free: Option<u64>,
    pub(crate) buffers: Option<u64>,
    pub(crate) shared: Option<u64>,
    pub(crate) cache: Option<u64>,
    pub(crate) swap_total: u64,
    pub(crate) swap_free: u64,
}

/// Parses `/proc/meminfo`.
///
/// `MemTotal` is required; `MemAvailable` falls back to `MemFree` on old
/// kernels that do not report it.
pub fn parse_proc_meminfo(text: &str) -> Option<ProcMem> {
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
            "Buffers" => mem.buffers = Some(kib * 1024),
            "Shmem" => mem.shared = Some(kib * 1024),
            "Cached" => mem.cache = Some(kib * 1024),
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
pub fn parse_proc_loadavg(text: &str) -> Option<[f64; 3]> {
    let mut fields = text.split_whitespace();
    let one: f64 = fields.next()?.parse().ok()?;
    let five: f64 = fields.next()?.parse().ok()?;
    let fifteen: f64 = fields.next()?.parse().ok()?;
    Some([one, five, fifteen])
}

/// Parses the scheduling-entity counts from `/proc/loadavg`'s fourth
/// field (`1/262`): the currently runnable entities and the total
/// scheduling entities, which is the host's thread count.
pub fn parse_proc_loadavg_entities(text: &str) -> Option<(u64, u64)> {
    let field = text.split_whitespace().nth(3)?;
    let (running, total) = field.split_once('/')?;
    Some((running.parse().ok()?, total.parse().ok()?))
}

/// Parses the per-core frequencies in MHz from `/proc/cpuinfo`: one
/// metric per `processor` block, unavailable when a block carries no
/// `cpu MHz` line (some kernels and boards omit them).
pub fn parse_cpuinfo_frequencies(text: &str) -> Vec<Metric> {
    let mut frequencies = Vec::new();
    let mut current: Option<f64> = None;
    let mut saw_processor = false;
    for line in text.lines() {
        if line.starts_with("processor") {
            match current.take() {
                Some(mhz) => frequencies.push(Metric::available(mhz, Unit::Hertz)),
                None if saw_processor => frequencies.push(Metric::unavailable(Unit::Hertz)),
                None => {}
            }
            saw_processor = true;
        } else if let Some(rest) = line.strip_prefix("cpu MHz") {
            if let Some(value) = rest.split(':').nth(1).and_then(|v| v.trim().parse().ok()) {
                current = Some(value);
            }
        }
    }
    match current.take() {
        Some(mhz) => frequencies.push(Metric::available(mhz, Unit::Hertz)),
        None if saw_processor => frequencies.push(Metric::unavailable(Unit::Hertz)),
        None => {}
    }
    frequencies
}

/// Parses the first field of `/proc/uptime`, in seconds.
pub fn parse_proc_uptime(text: &str) -> Option<f64> {
    text.split_whitespace().next()?.parse().ok()
}

/// Parses one `/proc/pressure/<resource>` file: the `some` line always,
/// the `full` line when the kernel writes one (cpu has none). Returns
/// `None` for unparseable or truncated text.
pub fn parse_pressure(text: &str) -> Option<Psi> {
    let mut some = None;
    let mut full = None;
    for line in text.lines() {
        let (kind, rest) = line.split_once(' ')?;
        let mut avg = PsiAvg::default();
        for field in rest.split_whitespace() {
            let (name, value) = field.split_once('=')?;
            let value: f64 = value.parse().ok()?;
            match name {
                "avg10" => avg.ten = value,
                "avg60" => avg.sixty = value,
                "avg300" => avg.three_hundred = value,
                // The `total=` microsecond counter is not needed here.
                "total" => {}
                _ => return None,
            }
        }
        match kind {
            "some" => some = Some(avg),
            "full" => full = Some(avg),
            _ => return None,
        }
    }
    Some(Psi { some: some?, full })
}

/// Builds the `Sample.system` string from `/proc/sys/kernel/osrelease`
/// text: "Linux <release>". Empty when the file is absent, so recorded
/// fixtures that predate the field stay honest instead of guessing.
fn system_text(osrelease: &str) -> String {
    let release = osrelease.trim();
    if release.is_empty() {
        String::new()
    } else {
        format!("Linux {release}")
    }
}

/// Parses `/proc/mounts` into a map of device name → mount point.
///
/// Lines that do not follow the field layout are skipped.
pub fn parse_proc_mounts(text: &str) -> std::collections::HashMap<String, String> {
    let mut mounts = std::collections::HashMap::new();
    for line in text.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 2 {
            continue;
        }
        mounts.insert(fields[0].to_string(), fields[1].to_string());
    }
    mounts
}

/// Capacity of one mounted filesystem via `statvfs`.
///
/// Returns `(total, used, usage_pct)`. Used is the capacity not
/// available to unprivileged users: `f_frsize * (f_blocks - f_bavail)`.
/// The numeric fields are zero when `statvfs` fails. Field widths
/// differ between macOS (`u32`) and Linux (`u64`), so every value is
/// cast to `u64` first.
#[cfg(target_os = "linux")]
fn disk_usage(mount: &str) -> (u64, u64, f64) {
    let mut st = unsafe { std::mem::zeroed::<libc::statvfs>() };
    let path = std::ffi::CString::new(mount).unwrap_or_default();
    let rc = unsafe { libc::statvfs(path.as_ptr(), &mut st) };
    if rc != 0 {
        return (0, 0, 0.0);
    }
    let total = (st.f_frsize as u64) * (st.f_blocks as u64);
    let avail = (st.f_frsize as u64) * (st.f_bavail as u64);
    let used = total.saturating_sub(avail);
    let pct = if total > 0 {
        used as f64 / total as f64 * 100.0
    } else {
        0.0
    };
    (total, used, pct)
}

/// Parses `/proc/diskstats`, with mount points from `mounts`.
///
/// The kernel counts 512-byte sectors regardless of the device's real
/// sector size, so both byte totals are sector counts times 512. Usage
/// stays zeroed here so fixture replay never touches the host's
/// filesystems; the live collectors fill it with `disk_usage`. Lines
/// that do not follow the field layout are skipped: device sets
/// legitimately differ between hosts.
pub fn parse_proc_diskstats(
    text: &str,
    mounts: &std::collections::HashMap<String, String>,
) -> Vec<Disk> {
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
        let mount = mounts.get(name).cloned().unwrap_or_default();
        disks.push(Disk {
            name: name.to_string(),
            read_bytes: counters[2] * 512,
            write_bytes: counters[6] * 512,
            mount,
            total_bytes: 0,
            used_bytes: 0,
            usage_pct: 0.0,
            read_rate: None,
            write_rate: None,
        });
    }
    disks
}

/// Parses `/proc/net/dev`, skipping the two header lines.
///
/// Lines that do not follow the field layout are skipped.
pub fn parse_proc_net_dev(text: &str) -> Vec<NetIf> {
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
            rx_rate: None,
            tx_rate: None,
        });
    }
    interfaces
}

/// Parsed fields of one process's `status` file.
#[derive(Debug, Default)]
pub struct PidStatus {
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
pub fn parse_pid_status(text: &str) -> PidStatus {
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

/// Parsed fields from one process's `stat` file.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PidStat {
    // Read only by the live collector's CPU-percentage deltas, which do
    // not compile on non-Linux hosts.
    #[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
    pub(crate) utime_jiffies: u64,
    #[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
    pub(crate) stime_jiffies: u64,
    /// Scheduling priority (`stat` field 18).
    pub(crate) priority: i32,
    /// Nice value (`stat` field 19).
    pub(crate) nice: i32,
    /// Start time in jiffies since boot (`stat` field 22).
    pub(crate) start_jiffies: u64,
    /// Core the process last ran on (`stat` field 39).
    pub(crate) processor: u32,
}

/// Parses the per-process fields of `stat`, which sit after the
/// parenthesised command and must therefore not be split naively.
///
/// All parsed fields are mandatory: a `stat` line short enough to miss
/// one is treated as unparsed rather than half-known, matching the
/// fixture-parser rule that column drift must fail, not guess.
fn parse_pid_stat(text: &str) -> Option<PidStat> {
    let open = text.find('(')?;
    let close = text.rfind(')')?;
    if close <= open {
        return None;
    }
    let mut fields = text[close + 1..].split_whitespace();
    let utime_jiffies: u64 = fields.nth(11)?.parse().ok()?;
    let stime_jiffies: u64 = fields.next()?.parse().ok()?;
    // Fields 16 and 17 (`cutime`, `cstime`) are skipped.
    let _cutime: i64 = fields.next()?.parse().ok()?;
    let _cstime: i64 = fields.next()?.parse().ok()?;
    let priority: i32 = fields.next()?.parse().ok()?;
    let nice: i32 = fields.next()?.parse().ok()?;
    let _num_threads: i64 = fields.next()?.parse().ok()?;
    let _itreal: i64 = fields.next()?.parse().ok()?;
    let start_jiffies: u64 = fields.next()?.parse().ok()?;
    // Fields 23 through 38 (`vsize` .. `exit_signal`) are skipped.
    for _ in 0..16 {
        let _skipped: &str = fields.next()?;
    }
    let processor: u32 = fields.next()?.parse().ok()?;
    Some(PidStat {
        utime_jiffies,
        stime_jiffies,
        priority,
        nice,
        start_jiffies,
        processor,
    })
}

/// Shared memory bytes from one process's `statm` file: the third field
/// (shared pages) times the page size.
///
/// The page size is the 4 KiB that every recorded Linux host and CI
/// runner uses; kernels with larger pages would report a proportionally
/// larger shared footprint as smaller. Decision 0014 records this.
fn parse_pid_statm(text: &str) -> Option<u64> {
    let shared_pages: u64 = text.split_whitespace().nth(2)?.parse().ok()?;
    Some(shared_pages * 4096)
}

/// The full command line from one process's `cmdline` file: the
/// NUL-separated argv joined with single spaces. An empty file (kernel
/// threads have none) means no command line, not an empty one.
fn parse_pid_cmdline(text: &str) -> Option<String> {
    let argv: Vec<&str> = text.split('\0').filter(|arg| !arg.is_empty()).collect();
    if argv.is_empty() {
        return None;
    }
    Some(argv.join(" "))
}

/// Disk I/O counters from `/proc/<pid>/io` for one process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PidIo {
    pub(crate) read_bytes: u64,
    pub(crate) write_bytes: u64,
}

/// Parses the `read_bytes` and `write_bytes` lines of `/proc/<pid>/io`.
///
/// Returns `None` when either counter is missing or unparsable: an `io`
/// file the kernel did not fill completely is better treated as
/// unavailable than half-known. `rchar`/`wchar` (cached traffic) and
/// `cancelled_write_bytes` are ignored, as is everything else.
pub(crate) fn parse_pid_io(text: &str) -> Option<PidIo> {
    let mut read_bytes = None;
    let mut write_bytes = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("read_bytes:") {
            read_bytes = rest.trim().parse().ok();
        } else if let Some(rest) = line.strip_prefix("write_bytes:") {
            write_bytes = rest.trim().parse().ok();
        }
    }
    Some(PidIo {
        read_bytes: read_bytes?,
        write_bytes: write_bytes?,
    })
}

/// Disk I/O rates between two samples, in bytes per second.
///
/// Rates are `Some` only when both samples saw the counters and the
/// interval is known and positive. A counter that went backwards, which
/// happens when a container's cgroup is reset, reports zero rather than
/// a negative rate.
#[cfg(any(target_os = "linux", test))]
pub(crate) fn io_rates(
    current: Option<PidIo>,
    previous: Option<PidIo>,
    seconds: Option<f64>,
) -> (Option<f64>, Option<f64>) {
    let (Some(current), Some(previous), Some(secs)) = (current, previous, seconds) else {
        return (None, None);
    };
    if secs <= 0.0 {
        return (None, None);
    }
    let rate = |current_bytes: u64, previous_bytes: u64| {
        Some((current_bytes.saturating_sub(previous_bytes) as f64) / secs)
    };
    (
        rate(current.read_bytes, previous.read_bytes),
        rate(current.write_bytes, previous.write_bytes),
    )
}

/// Rate of one monotonic counter between two samples, in units per
/// second.
///
/// `Some` only when the interval is known and positive and the counter
/// was seen before; a counter that went backwards, which happens when an
/// interface is recreated or a cgroup is reset, reports zero rather than
/// a negative rate. The same rule underlies the per-process and
/// per-disk rates.
#[cfg(any(target_os = "linux", test))]
fn counter_rate(current: u64, previous: Option<u64>, seconds: Option<f64>) -> Option<f64> {
    let secs = seconds?;
    if secs <= 0.0 {
        return None;
    }
    let previous = previous?;
    Some((current.saturating_sub(previous) as f64) / secs)
}

/// Everything recorded for one process, keyed by pid.
#[derive(Debug, Default)]
pub(crate) struct PidData {
    pub(crate) status: Option<PidStatus>,
    pub(crate) stat: Option<PidStat>,
    pub(crate) comm: Option<String>,
    pub(crate) command: Option<String>,
    pub(crate) io: Option<PidIo>,
    pub(crate) statm: Option<u64>,
    /// This entry is a task (thread) of the process `tgid`, not a
    /// process of its own; only the task walk sets it.
    pub(crate) is_thread: bool,
    /// For a task entry, the thread group's pid. Linux reports a task's
    /// `PPid` as the process's own parent, so the group has to travel
    /// with the entry.
    pub(crate) tgid: Option<u32>,
    /// The container this pid runs in, from `/proc/<pid>/cgroup`;
    /// `None` when the file is unreadable or names no container.
    pub(crate) cgroup: Option<Container>,
}

/// The container a cgroup path points into, when the path marks one.
///
/// Recognizes the layouts the common runtimes leave in the cgroup
/// hierarchy: docker's `/docker/<64 hex>` and `docker-<hex>.scope`
/// (which also covers Kubernetes pods that name their containers after
/// docker), podman's `libpod-<hex>.scope` and `/podman/<id>`,
/// containerd's `cri-containerd-<hex>.scope`, cri-o's `crio-<hex>.scope`,
/// LXC's `/lxc/<name>` and systemd-nspawn's `machine-<name>.scope`.
/// Everything else — plain systemd services, user sessions, the root
/// cgroup — is `None`: zTop shows a container only when the path says
/// so, never by guessing.
///
/// The id is the first 12 hex characters of the full run id, the shape
/// `docker ps` and friends print; LXC and nspawn have names instead.
pub(crate) fn detect_container(text: &str) -> Option<Container> {
    // `12:pids:/docker/abc…` (v1) or `0::/docker/abc…` (v2): the path
    // is everything after the last colon; cgroup paths cannot contain
    // one.
    let path = text.trim().rsplit(':').next()?.trim();
    // The id inside a scope or directory: the hex characters of the
    // segment, needing at least the 12 `docker ps` prints.
    let id_of = |segment: &str| -> Option<String> {
        let hex: String = segment.chars().filter(char::is_ascii_hexdigit).collect();
        (hex.len() >= 12).then(|| hex[..12].to_string())
    };
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    for (index, segment) in segments.iter().enumerate() {
        let next = segments.get(index + 1).copied().unwrap_or("");
        // Docker: `docker-<hex>.scope` under a systemd slice, or a
        // `docker` directory followed by the full id.
        let docker_scope = segment
            .strip_prefix("docker-")
            .and_then(|rest| rest.strip_suffix(".scope"))
            .and_then(id_of);
        if let Some(id) = docker_scope {
            return Some(Container {
                id,
                runtime: "docker".into(),
            });
        }
        if *segment == "docker" {
            if let Some(id) = id_of(next) {
                return Some(Container {
                    id,
                    runtime: "docker".into(),
                });
            }
        }
        // Podman keeps its own scope shape and podman-prefixed dirs.
        let podman_scope = segment
            .strip_prefix("libpod-")
            .and_then(|rest| rest.strip_suffix(".scope"))
            .and_then(id_of);
        if let Some(id) = podman_scope {
            return Some(Container {
                id,
                runtime: "podman".into(),
            });
        }
        if *segment == "podman" || *segment == "libpod" {
            if let Some(id) = id_of(next) {
                return Some(Container {
                    id,
                    runtime: "podman".into(),
                });
            }
        }
        // The container runtimes behind Kubernetes name their scopes
        // after themselves.
        let cri_scope = segment
            .strip_prefix("cri-containerd-")
            .and_then(|rest| rest.strip_suffix(".scope"))
            .and_then(id_of);
        if let Some(id) = cri_scope {
            return Some(Container {
                id,
                runtime: "containerd".into(),
            });
        }
        let crio_scope = segment
            .strip_prefix("crio-")
            .and_then(|rest| rest.strip_suffix(".scope"))
            .and_then(id_of);
        if let Some(id) = crio_scope {
            return Some(Container {
                id,
                runtime: "cri-o".into(),
            });
        }
        // LXC: `/lxc/<container-name>` — a name, not a hex id.
        if *segment == "lxc" && !next.is_empty() {
            return Some(Container {
                id: next.to_string(),
                runtime: "lxc".into(),
            });
        }
        // systemd-nspawn: `machine-<name>.scope` under machine.slice.
        let machine_scope = segment
            .strip_prefix("machine-")
            .and_then(|rest| rest.strip_suffix(".scope"))
            .map(str::to_string);
        if let Some(name) = machine_scope {
            return Some(Container {
                id: name,
                runtime: "systemd-nspawn".into(),
            });
        }
    }
    None
}

/// Builds one [`Process`] row.
///
/// The user is the numeric uid; the name falls back from `status` to
/// `comm` to `pid-<pid>`. Memory percentages use the recorded `MemTotal`.
/// `btime` (the boot time from `/proc/stat`) turns a `stat` start time
/// into a wall-clock start; without it the start stays unavailable.
fn process_row(
    pid: u32,
    data: &PidData,
    total_mem_bytes: u64,
    cpu_percent: f64,
    btime: Option<u64>,
) -> Process {
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
    let start_time_secs = match (btime, data.stat.as_ref()) {
        (Some(boot), Some(stat)) => Some(boot + stat.start_jiffies / (USER_HZ as u64)),
        _ => None,
    };
    let parent = status.and_then(|status| status.parent);
    // Kernel threads are the set the `kernel_threads` metric counts:
    // processes whose parent is 0 (orphaned, including pid 1) or 2
    // (kthreadd's children). Thread rows are filtered by the threads
    // toggle, not by this flag.
    let kernel_thread = !data.is_thread && matches!(parent, Some(0) | Some(2));
    Process {
        pid,
        parent: if data.is_thread {
            data.tgid.or(parent)
        } else {
            parent
        },
        user,
        state,
        name,
        cpu_percent,
        mem_percent,
        virtual_bytes,
        resident_bytes,
        threads,
        priority: data.stat.as_ref().map(|stat| stat.priority),
        nice: data.stat.as_ref().map(|stat| stat.nice),
        shared_bytes: data.statm,
        total_time_ns: data.stat.as_ref().map(|stat| {
            (stat.utime_jiffies + stat.stime_jiffies) * 1_000_000_000 / (USER_HZ as u64)
        }),
        start_time_secs,
        processor: data.stat.as_ref().map(|stat| stat.processor),
        command: data.command.clone(),
        is_thread: data.is_thread,
        kernel_thread,
        container: data.cgroup.clone(),
        io: ProcessIo {
            read_bytes: data.io.map(|io| io.read_bytes),
            write_bytes: data.io.map(|io| io.write_bytes),
            read_rate: None,
            write_rate: None,
        },
    }
}

/// Builds the process table from the recorded per-pid entries.
///
/// Only pids with a `status` or a `comm` produce a row; a `stat`-only
/// entry carries no usable name.
fn process_table(
    pids: &BTreeMap<u32, PidData>,
    total_mem_bytes: u64,
    btime: Option<u64>,
) -> Vec<Process> {
    let mut rows = Vec::new();
    for (pid, data) in pids {
        if data.status.is_none() && data.comm.is_none() {
            continue;
        }
        rows.push(process_row(*pid, data, total_mem_bytes, 0.0, btime));
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
        buffers: match mem.buffers {
            Some(buffers) => Metric::available(buffers as f64, Unit::Bytes),
            None => Metric::unavailable(Unit::Bytes),
        },
        shared: match mem.shared {
            Some(shared) => Metric::available(shared as f64, Unit::Bytes),
            None => Metric::unavailable(Unit::Bytes),
        },
        cache: match mem.cache {
            Some(cache) => Metric::available(cache as f64, Unit::Bytes),
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

/// Splits a per-pid entry name like `proc-42-status` into id and kind.
///
/// Task entries name the thread group too: `proc-300-task-301-stat` is
/// task 301 of process 300, recorded as a thread row. The result is the
/// id to key the row by (the tid for a task entry), the kind, and, for
/// a task entry, the thread group's pid.
fn split_pid_entry(name: &str) -> Option<(u32, &'static str, Option<u32>)> {
    let rest = name.strip_prefix("proc-")?;
    let (pid, kind) = rest.split_once('-')?;
    if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let pid: u32 = pid.parse().ok()?;
    if let Some((tid, kind)) = kind
        .strip_prefix("task-")
        .and_then(|rest| rest.split_once('-'))
    {
        let tid: u32 = tid.parse().ok()?;
        let kind: &'static str = match kind {
            "stat" => "stat",
            "status" => "status",
            "comm" => "comm",
            _ => return None,
        };
        return Some((tid, kind, Some(pid)));
    }
    let kind: &'static str = match kind {
        "stat" => "stat",
        "status" => "status",
        "comm" => "comm",
        "cmdline" => "cmdline",
        "io" => "io",
        _ => return None,
    };
    Some((pid, kind, None))
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
    /// The manifest names a platform this build has no reader for.
    #[error("no fixture reader for platform {platform:?}")]
    UnknownPlatform {
        /// The recorded platform string, e.g. `linux` or `macos`.
        platform: String,
    },
}

pub(crate) fn missing_source(name: &'static str) -> FixtureSampleError {
    FixtureSampleError::MissingSource {
        name: name.to_string(),
    }
}

pub(crate) fn bad_source(name: &str) -> FixtureSampleError {
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
    let mut loadavg_entities = None;
    let mut cpuinfo = None;
    let mut uptime = None;
    let mut disks = None;
    let mut net = None;
    let mut pressure_cpu = None;
    let mut pressure_memory = None;
    let mut pressure_io = None;
    let mut pids: BTreeMap<u32, PidData> = BTreeMap::new();

    for name in fixture.entry_names() {
        if let Some((id, kind, group)) = split_pid_entry(name) {
            let text = fixture.entry_text(name)?;
            let data = pids.entry(id).or_default();
            if let Some(group) = group {
                data.is_thread = true;
                data.tgid = Some(group);
            }
            match kind {
                "stat" => data.stat = parse_pid_stat(&text),
                "status" => data.status = Some(parse_pid_status(&text)),
                "comm" => data.comm = Some(text),
                "cmdline" => data.command = parse_pid_cmdline(&text),
                "io" => data.io = parse_pid_io(&text),
                "statm" => data.statm = parse_pid_statm(&text),
                "cgroup" => data.cgroup = detect_container(&text),
                _ => {}
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
                loadavg_entities = parse_proc_loadavg_entities(&text);
            }
            "proc-cpuinfo" => cpuinfo = Some(text),
            "proc-uptime" => {
                uptime = Some(parse_proc_uptime(&text).ok_or_else(|| bad_source(name))?);
            }
            "proc-diskstats" => {
                let mounts_text = fixture.entry_text("proc-mounts").unwrap_or_default();
                disks = Some(parse_proc_diskstats(
                    &text,
                    &parse_proc_mounts(&mounts_text),
                ));
            }
            "proc-net-dev" => net = Some(parse_proc_net_dev(&text)),
            "proc-pressure-cpu" => pressure_cpu = parse_pressure(&text),
            "proc-pressure-memory" => pressure_memory = parse_pressure(&text),
            "proc-pressure-io" => pressure_io = parse_pressure(&text),
            _ => {}
        }
    }

    let stat = stat.ok_or_else(|| missing_source("proc-stat"))?;
    let meminfo = meminfo.ok_or_else(|| missing_source("proc-meminfo"))?;
    let loadavg = loadavg.ok_or_else(|| missing_source("proc-loadavg"))?;
    let uptime = uptime.ok_or_else(|| missing_source("proc-uptime"))?;
    // Pressure is optional: older captures have no pressure files, and
    // one file without the others shows nothing rather than a half
    // picture.
    let pressure = match (pressure_cpu, pressure_memory, pressure_io) {
        (Some(cpu), Some(memory), Some(io)) => Some(Pressure { cpu, memory, io }),
        _ => None,
    };

    Ok(Sample {
        timestamp_ms: fixture.manifest().captured_at_unix * 1000,
        hostname: dir
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown")
            .to_string(),
        system: system_text(
            &fixture
                .entry_text("proc-sys-kernel-osrelease")
                .unwrap_or_default(),
        ),
        cpu: Cpu {
            busy_percent: vec![0.0; stat.cores.len()],
            state_percent: vec![CpuTimes::default(); stat.cores.len()],
            cores: stat.cores,
            frequency_mhz: cpuinfo
                .map(|text| parse_cpuinfo_frequencies(&text))
                .unwrap_or_default(),
        },
        memory: memory_from(meminfo),
        load_avg: loadavg,
        uptime: Metric::available(uptime, Unit::Seconds),
        threads: match loadavg_entities {
            Some((_, total)) => Metric::available(total as f64, Unit::Count),
            None => Metric::unavailable(Unit::Count),
        },
        kernel_threads: Metric::available(
            pids.values()
                .filter(|data| {
                    // Thread entries are not kernel threads: their
                    // parent is the thread group's own parent.
                    !data.is_thread
                        && data
                            .status
                            .as_ref()
                            .and_then(|status| status.parent)
                            .is_some_and(|parent| parent == 0 || parent == 2)
                })
                .count() as f64,
            Unit::Count,
        ),
        processes: process_table(&pids, meminfo.total, stat.btime),
        disks: disks.unwrap_or_default(),
        net: net.unwrap_or_default(),
        sensors: Sensors {
            temps: Vec::new(),
            fans: Vec::new(),
            battery: None,
            ..Sensors::default()
        },
        apple_silicon: AppleSilicon::default(),
        // Recorded captures predate GPU collection: a replay shows no
        // GPU rows rather than a half-populated picture (decision 0034).
        gpus: Vec::new(),
        pressure,
    })
}

// Per-core busy percentages between the previous and current core times
// are defined in `model` (`core_percents`) so the macOS collector shares
// it.

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
        CpuTimes, PidData, PidIo, PidStat, USER_HZ, core_percents, counter_rate, detect_container,
        disk_usage, io_rates, memory_from, parse_cpuinfo_frequencies, parse_hwmon, parse_pid_io,
        parse_pid_stat, parse_pid_statm, parse_pid_status, parse_power_supply, parse_pressure,
        parse_proc_diskstats, parse_proc_loadavg, parse_proc_loadavg_entities, parse_proc_meminfo,
        parse_proc_mounts, parse_proc_net_dev, parse_proc_stat, parse_proc_uptime, process_row,
        system_text,
    };
    use crate::collector::{CollectError, Collector};
    use crate::model::core_state_percents;
    use crate::model::{
        AppleSilicon, Cpu, Fan, Metric, Pressure, Process, Sample, Sensors, TempSensor, Unit,
    };

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
        ios: HashMap<u32, PidIo>,
        cores: Vec<CpuTimes>,
        /// Per-device byte counters keyed by device name.
        disks: HashMap<String, (u64, u64)>,
        /// Per-interface byte counters keyed by interface name.
        net: HashMap<String, (u64, u64)>,
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
            let interval_secs = self
                .prev
                .as_ref()
                .map(|prev| now.duration_since(prev.at).as_secs_f64());

            let stat_text = fs::read_to_string("/proc/stat")?;
            let stat = parse_proc_stat(&stat_text).ok_or(CollectError::Unavailable {
                origin: "/proc/stat",
                what: "CPU times",
            })?;
            let (per_core_percent, per_core_states) = match (self.prev.as_ref(), interval_secs) {
                (Some(prev), Some(secs)) => (
                    core_percents(&stat.cores, &prev.cores, secs),
                    core_state_percents(&stat.cores, &prev.cores, secs),
                ),
                _ => (
                    vec![0.0; stat.cores.len()],
                    vec![CpuTimes::default(); stat.cores.len()],
                ),
            };
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
            let mut disks = fs::read_to_string("/proc/diskstats")
                .ok()
                .map(|disk_text| {
                    let mounts_text = fs::read_to_string("/proc/mounts").unwrap_or_default();
                    parse_proc_diskstats(&disk_text, &parse_proc_mounts(&mounts_text))
                })
                .unwrap_or_default();
            let mut net = fs::read_to_string("/proc/net/dev")
                .ok()
                .as_deref()
                .map(parse_proc_net_dev)
                .unwrap_or_default();
            // Pressure stall information: all three files must read and
            // parse; one missing (kernel without PSI, or PSI disabled)
            // hides the meters rather than showing a half picture.
            let pressure = read_pressure();

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
                data.io = fs::read_to_string(base.join("io"))
                    .ok()
                    .and_then(|text| parse_pid_io(&text));
                data.statm = fs::read_to_string(base.join("statm"))
                    .ok()
                    .and_then(|text| parse_pid_statm(&text));
                // Container membership: tasks of a process share its
                // cgroup, so the group's value is cloned here (before
                // the task loop re-borrows the map) and copied onto the
                // thread rows below rather than re-read per task.
                data.cgroup = fs::read_to_string(base.join("cgroup"))
                    .ok()
                    .and_then(|text| detect_container(&text));
                let group_container = data.cgroup.clone();
                // Thread rows: every numeric task below the process
                // except the leader (the process's own row) becomes a
                // row of its own, keyed by tid; the group travels in
                // `tgid` because a task's `PPid` is the process's
                // parent, not the group.
                for task in read_dir_names(&base.join("task")) {
                    let Ok(tid) = task.parse::<u32>() else {
                        continue;
                    };
                    if tid == pid {
                        continue;
                    }
                    let task_base = base.join("task").join(&task);
                    let thread = pids.entry(tid).or_default();
                    thread.is_thread = true;
                    thread.tgid = Some(pid);
                    thread.cgroup = group_container.clone();
                    thread.stat = fs::read_to_string(task_base.join("stat"))
                        .ok()
                        .and_then(|text| parse_pid_stat(&text));
                    thread.status = fs::read_to_string(task_base.join("status"))
                        .ok()
                        .map(|text| parse_pid_status(&text));
                    thread.comm = fs::read_to_string(task_base.join("comm")).ok();
                }
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

            let prev = self.prev.as_ref();
            let prev_pids = prev.map(|prev| &prev.pids);
            let prev_ios = prev.map(|prev| &prev.ios);

            // Disk usage comes from `statvfs`, only on the live path: the
            // fixture replay path keeps the parser pure so recorded samples
            // replay deterministically. Rates reuse the counter-rate rule
            // applied to the byte counters.
            for disk in &mut disks {
                let previous = prev.and_then(|prev| prev.disks.get(&disk.name));
                disk.read_rate = counter_rate(
                    disk.read_bytes,
                    previous.map(|(read, _)| *read),
                    interval_secs,
                );
                disk.write_rate = counter_rate(
                    disk.write_bytes,
                    previous.map(|(_, write)| *write),
                    interval_secs,
                );
                if !disk.mount.is_empty() {
                    let (total, used, pct) = disk_usage(&disk.mount);
                    disk.total_bytes = total;
                    disk.used_bytes = used;
                    disk.usage_pct = pct;
                }
            }
            for iface in &mut net {
                let previous = prev.and_then(|prev| prev.net.get(&iface.name));
                iface.rx_rate =
                    counter_rate(iface.rx_bytes, previous.map(|(rx, _)| *rx), interval_secs);
                iface.tx_rate =
                    counter_rate(iface.tx_bytes, previous.map(|(_, tx)| *tx), interval_secs);
            }

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
                let mut row = process_row(*pid, data, total_mem_bytes, cpu_percent, stat.btime);
                let (read_rate, write_rate) = io_rates(
                    data.io,
                    prev_ios.and_then(|ios| ios.get(pid)).copied(),
                    interval_secs,
                );
                row.io.read_rate = read_rate;
                row.io.write_rate = write_rate;
                processes.push(row);
            }
            self.prev = Some(Prev {
                at: now,
                pids: pids
                    .iter()
                    .filter_map(|(pid, data)| data.stat.as_ref().map(|stat| (*pid, *stat)))
                    .collect(),
                ios: pids
                    .iter()
                    .filter_map(|(pid, data)| data.io.map(|io| (*pid, io)))
                    .collect(),
                cores: stat.cores.clone(),
                disks: disks
                    .iter()
                    .map(|disk| (disk.name.clone(), (disk.read_bytes, disk.write_bytes)))
                    .collect(),
                net: net
                    .iter()
                    .map(|iface| (iface.name.clone(), (iface.rx_bytes, iface.tx_bytes)))
                    .collect(),
            });

            Ok(Sample {
                timestamp_ms,
                hostname,
                system: system_text(
                    &fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default(),
                ),
                cpu: Cpu {
                    busy_percent: per_core_percent,
                    state_percent: per_core_states,
                    cores: stat.cores,
                    frequency_mhz: parse_cpuinfo_frequencies(
                        &fs::read_to_string("/proc/cpuinfo").unwrap_or_default(),
                    ),
                },
                memory: memory_from(meminfo),
                load_avg,
                uptime: Metric::available(uptime, Unit::Seconds),
                threads: match parse_proc_loadavg_entities(&loadavg_text) {
                    Some((_, total)) => Metric::available(total as f64, Unit::Count),
                    None => Metric::unavailable(Unit::Count),
                },
                kernel_threads: Metric::available(
                    pids.values()
                        .filter(|data| {
                            // Thread entries are not kernel threads:
                            // their parent is the group's own parent.
                            !data.is_thread
                                && data
                                    .status
                                    .as_ref()
                                    .and_then(|status| status.parent)
                                    .is_some_and(|parent| parent == 0 || parent == 2)
                        })
                        .count() as f64,
                    Unit::Count,
                ),
                processes,
                disks,
                net,
                sensors: Sensors {
                    temps,
                    fans,
                    battery,
                    // No unprivileged GPU/system power source is wired up on
                    // Linux yet; hwmon power inputs are future work.
                    gpu_watts: Metric::unavailable(Unit::Watts),
                    system_watts: Metric::unavailable(Unit::Watts),
                },
                pressure,
                apple_silicon: AppleSilicon::default(),
                gpus: crate::linux_gpu::collect(),
            })
        }
    }

    /// Reads and parses the three `/proc/pressure` files; `None` when
    /// any of them is missing or unparseable.
    fn read_pressure() -> Option<Pressure> {
        let cpu = parse_pressure(&fs::read_to_string("/proc/pressure/cpu").ok()?)?;
        let memory = parse_pressure(&fs::read_to_string("/proc/pressure/memory").ok()?)?;
        let io = parse_pressure(&fs::read_to_string("/proc/pressure/io").ok()?)?;
        Some(Pressure { cpu, memory, io })
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
    fn cmdline_joins_the_recorded_argv() {
        // The capture scrubs each argv to one fake word plus the NUL the
        // kernel keeps after it (decision 0007).
        assert_eq!(
            parse_pid_cmdline("proc-a-1\0"),
            Some("proc-a-1".to_string())
        );
        assert_eq!(
            parse_pid_cmdline("ztop\0--watch\0\0"),
            Some("ztop --watch".to_string())
        );
        // Kernel threads have an empty file: no command line, not an
        // empty one.
        assert_eq!(parse_pid_cmdline(""), None);
    }

    #[test]
    fn pid_io_parses_read_and_write_bytes_and_rejects_partial_files() {
        let text = "rchar: 1000\nwchar: 2000\nread_bytes: 4096\nwrite_bytes: 8192\ncancelled_write_bytes: 0\n";
        let io = parse_pid_io(text).expect("io parses");
        assert_eq!(io.read_bytes, 4096);
        assert_eq!(io.write_bytes, 8192);
        // A file missing either counter is unusable, not half-known.
        assert!(parse_pid_io("rchar: 1000\n").is_none());
        assert!(parse_pid_io("read_bytes: not-a-number\nwrite_bytes: 8\n").is_none());
        assert!(parse_pid_io("").is_none());
    }

    #[test]
    fn io_rates_needs_both_samples_and_a_positive_interval() {
        let now = PidIo {
            read_bytes: 3_000_000,
            write_bytes: 2_000,
        };
        let old = PidIo {
            read_bytes: 1_000_000,
            write_bytes: 6_000,
        };
        let (read, write) = io_rates(Some(now), Some(old), Some(2.0));
        assert_eq!(read, Some(1_000_000.0));
        assert_eq!(write, Some(0.0)); // counters never go backwards
        assert_eq!(io_rates(Some(now), None, Some(2.0)), (None, None));
        assert_eq!(io_rates(None, Some(old), Some(2.0)), (None, None));
        assert_eq!(io_rates(Some(now), Some(old), None), (None, None));
        assert_eq!(io_rates(Some(now), Some(old), Some(0.0)), (None, None));
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
            buffers: Some(30 * 1024),
            shared: Some(10 * 1024),
            cache: Some(200 * 1024),
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
    fn pressure_reads_some_and_full_averages() {
        let text = "some avg10=0.12 avg60=0.34 avg300=0.56 total=78901234\n\
                    full avg10=1.23 avg60=4.56 avg300=7.89 total=12345\n";
        let psi = parse_pressure(text).expect("parses");
        assert_eq!(psi.some.ten, 0.12);
        assert_eq!(psi.some.sixty, 0.34);
        assert_eq!(psi.some.three_hundred, 0.56);
        let full = psi.full.expect("full");
        assert_eq!(full.ten, 1.23);
        assert_eq!(full.three_hundred, 7.89);
    }

    #[test]
    fn pressure_cpu_has_no_full_line() {
        let psi =
            parse_pressure("some avg10=3.50 avg60=2.00 avg300=1.00 total=9\n").expect("parses");
        assert_eq!(psi.some.ten, 3.5);
        assert!(psi.full.is_none());
    }

    #[test]
    fn pressure_rejects_truncated_or_unknown_text() {
        // Missing `some` line: the struct has no honest value.
        assert!(parse_pressure("full avg10=1.0 avg60=0.0 avg300=0.0 total=1\n").is_none());
        // A field the parser does not know must not be silently skipped.
        assert!(parse_pressure("some avg10=1.0 avg60=0.0 avgX=0.0 total=1\n").is_none());
        // A value that does not parse.
        assert!(parse_pressure("some avg10=x avg60=0.0 avg300=0.0 total=1\n").is_none());
        // Unknown kind line.
        assert!(parse_pressure("odd avg10=1.0 avg60=0.0 avg300=0.0 total=1\n").is_none());
        // Empty.
        assert!(parse_pressure("").is_none());
    }

    /// The cgroup reader names the common runtimes and nothing else:
    /// each layout parses to the right runtime and id, and host-shaped
    /// paths (services, sessions, the root) stay `None`.
    #[test]
    fn detect_container_names_the_common_runtimes_and_nothing_else() {
        let full = "4a2b1c9d8e7f00112233445566778899aabbccddeeff0011";
        // v1 hierarchy line with the full id under docker/.
        let got = detect_container(&format!("12:pids:/docker/{full}\n")).expect("docker v1");
        assert_eq!(got.runtime, "docker");
        assert_eq!(got.id, "4a2b1c9d8e7f");
        // v2 line with the systemd scope shape.
        let got = detect_container(&format!("0::/system.slice/docker-{full}.scope\n"))
            .expect("docker scope");
        assert_eq!(got.runtime, "docker");
        assert_eq!(got.id, "4a2b1c9d8e7f");
        // Podman's libpod scope.
        let got = detect_container(&format!(
            "0::/user.slice/user-1000.slice/user@1000.service/libpod-{full}.scope\n"
        ))
        .expect("podman");
        assert_eq!(got.runtime, "podman");
        assert_eq!(got.id, "4a2b1c9d8e7f");
        // containerd and cri-o behind Kubernetes.
        let got = detect_container(&format!(
            "0::/kubepods.slice/kubepods-burstable.slice/cri-containerd-{full}.scope\n"
        ))
        .expect("containerd");
        assert_eq!(got.runtime, "containerd");
        let got =
            detect_container(&format!("0::/kubepods.slice/crio-{full}.scope\n")).expect("cri-o");
        assert_eq!(got.runtime, "cri-o");
        // LXC keeps a name, not a hex id.
        let got = detect_container("0::/lxc/web-frontend\n").expect("lxc");
        assert_eq!(got.runtime, "lxc");
        assert_eq!(got.id, "web-frontend");
        // systemd-nspawn machines.
        let got = detect_container("0::/machine.slice/machine-buildvm.scope\n").expect("nspawn");
        assert_eq!(got.runtime, "systemd-nspawn");
        assert_eq!(got.id, "buildvm");
        // Host-shaped paths name nothing.
        assert!(detect_container("12:pids:/system.slice/sshd.service\n").is_none());
        assert!(detect_container("0::/user.slice/user-1000.slice/session-2.scope\n").is_none());
        assert!(detect_container("0::/\n").is_none());
        // An unreadable file never reaches here, but an empty string is
        // the same as nothing.
        assert!(detect_container("").is_none());
    }

    #[test]
    fn diskstats_converts_sectors_to_bytes() {
        let text = "   8       0 sda 18342 630 1474182 10527 7429 6385 7098027 44835 0 12520 55372 \
                    \n   8       1 sda1 154 13 1332 12 2 0 2 8 0 18 20 \
                    \nnot a diskstats line \
                    \n";
        let disks = parse_proc_diskstats(text, &std::collections::HashMap::new());
        assert_eq!(disks.len(), 2);
        assert_eq!(disks[0].name, "sda");
        assert_eq!(disks[0].read_bytes, 1474182 * 512);
        assert_eq!(disks[0].write_bytes, 7098027 * 512);
        assert_eq!(disks[1].name, "sda1");
    }

    #[test]
    fn counter_rate_needs_previous_and_positive_interval() {
        assert_eq!(counter_rate(10, None, Some(1.0)), None);
        assert_eq!(counter_rate(10, Some(0), Some(0.0)), None);
        assert_eq!(counter_rate(10, Some(0), None), None);
        assert_eq!(counter_rate(10, Some(4), Some(2.0)), Some(3.0));
        // A counter that went backwards reports zero, not a negative rate.
        assert_eq!(counter_rate(4, Some(10), Some(2.0)), Some(0.0));
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
        // Kernel stat fields after `)`: state(0) ppid(1) pgrp(2) session(3)
        // tty_nr(4) tpgid(5) flags(6) minflt(7) cminflt(8) majflt(9)
        // cmajflt(10) utime(11) stime(12) cutime(13) cstime(14) priority(15)
        // nice(16) num_threads(17) itrealvalue(18) starttime(19) ...
        // processor at index 36.
        let line = "1 (proc-a-1) S 0 1 1 0 -1 4194560 37747 373471 29 0 151 189 395 371 371 20 0 1 40 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n";
        let stat = parse_pid_stat(line).expect("stat parses");
        assert_eq!(stat.utime_jiffies, 151);
        assert_eq!(stat.stime_jiffies, 189);
        assert_eq!(stat.priority, 371);
        assert_eq!(stat.nice, 20);
        assert_eq!(stat.start_jiffies, 40);
        assert_eq!(stat.processor, 0);
    }

    #[test]
    fn pid_stat_handles_commands_with_parentheses() {
        let line = "7 ((sd-pam) ) S 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 44 70000 100 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n";
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
        assert_eq!(split_pid_entry("proc-1-stat"), Some((1, "stat", None)));
        assert_eq!(
            split_pid_entry("proc-42-cmdline"),
            Some((42, "cmdline", None))
        );
        assert_eq!(split_pid_entry("proc-7-io"), Some((7, "io", None)));
        assert_eq!(split_pid_entry("proc-stat"), None);
        assert_eq!(split_pid_entry("proc-sys-kernel-osrelease"), None);
        assert_eq!(split_pid_entry("proc-1-mounts"), None);
        assert_eq!(split_pid_entry("proc--stat"), None);
        // Task entries carry the thread group and key by tid.
        assert_eq!(
            split_pid_entry("proc-300-task-301-stat"),
            Some((301, "stat", Some(300)))
        );
        assert_eq!(
            split_pid_entry("proc-300-task-301-comm"),
            Some((301, "comm", Some(300)))
        );
        assert_eq!(split_pid_entry("proc-300-task-301-io"), None);
        assert_eq!(split_pid_entry("proc-300-task-x-stat"), None);
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
            command: None,
            io: None,
            statm: None,
            ..Default::default()
        };
        let row = process_row(1, &data, 16366640 * 1024, 0.0, None);
        assert_eq!(row.pid, 1);
        assert_eq!(row.name, "proc-a-1");
        assert_eq!(row.state, "S");
        assert_eq!(row.user, "0");
        assert_eq!(row.parent, Some(0));
        assert_eq!(row.virtual_bytes, 25700 * 1024);
        assert_eq!(row.resident_bytes, 17044 * 1024);
        assert_eq!(row.threads, 1);
        // A parent of 0 is the kernel-thread set the `kthr` metric counts.
        assert!(row.kernel_thread);
        assert!(!row.is_thread);
    }

    /// A task entry is a thread row: it flags `is_thread`, points its
    /// parent at the thread group (a task's own `PPid` is the group's
    /// parent, so the group travels with the entry), and never flags
    /// `kernel_thread` — threads are filtered by the threads toggle.
    #[test]
    fn process_row_marks_thread_entries() {
        let status = PidStatus {
            name: "worker-a".to_string(),
            state: Some("R".to_string()),
            parent: Some(2), // the group's own parent, not the group
            uid: Some(1000),
            vm_size: 0,
            vm_rss: 4096,
            threads: 1,
        };
        let data = PidData {
            status: Some(status),
            comm: Some("worker-a\n".to_string()),
            is_thread: true,
            tgid: Some(300),
            ..Default::default()
        };
        let row = process_row(301, &data, 1000 * 1024, 0.0, None);
        assert!(row.is_thread);
        assert!(!row.kernel_thread);
        assert_eq!(row.parent, Some(300));
    }

    #[test]
    fn process_row_falls_back_to_comm() {
        let data = PidData {
            status: None,
            stat: None,
            comm: Some("worker-a\n".to_string()),
            command: None,
            io: None,
            statm: None,
            ..Default::default()
        };
        let row = process_row(9, &data, 1000 * 1024, 0.0, None);
        assert_eq!(row.name, "worker-a");
        assert_eq!(row.state, "?");
        assert_eq!(row.user, "?");
        assert_eq!(row.parent, None);
    }

    #[test]
    fn process_row_falls_back_when_names_are_missing() {
        let data = PidData::default();
        let row = process_row(42, &data, 0, 0.0, None);
        assert_eq!(row.name, "pid-42");
        assert_eq!(row.state, "?");
        assert_eq!(row.user, "?");
        assert_eq!(row.parent, None);
        assert_eq!(row.mem_percent, 0.0);
    }

    #[test]
    fn core_percents_reports_zero_without_history() {
        let core = CpuTimes {
            user: 10.0,
            system: 2.0,
            nice: 0.0,
            idle: 8.0,
            io_wait: 0.0,
            irq: 0.0,
            soft_irq: 0.0,
            steal: 0.0,
            guest: 0.0,
        };
        let cores = vec![core];
        // No previous sample: nothing to measure against.
        assert_eq!(core_percents(&cores, &[], 10.0), vec![0.0]);
        // A non-positive interval carries no signal either.
        assert_eq!(core_percents(&cores, &cores, 0.0), vec![0.0]);
    }

    #[test]
    fn core_percents_measures_each_core_independently() {
        let idle = || CpuTimes {
            user: 0.0,
            system: 0.0,
            nice: 0.0,
            idle: 10.0,
            io_wait: 0.0,
            irq: 0.0,
            soft_irq: 0.0,
            steal: 0.0,
            guest: 0.0,
        };
        let old = vec![idle(), idle()];
        let new = vec![
            CpuTimes {
                user: 5.0,
                idle: 15.0,
                ..idle()
            },
            CpuTimes {
                idle: 20.0,
                ..idle()
            },
        ];
        let percents = core_percents(&new, &old, 10.0);
        assert_eq!(percents.len(), 2);
        // First core: 5s busy of a 10s interval; second core stayed idle.
        assert!((percents[0] - 50.0).abs() < 1e-9, "got {}", percents[0]);
        assert!((percents[1] - 0.0).abs() < 1e-9, "got {}", percents[1]);
    }

    #[test]
    fn core_percents_clamps_counter_resets() {
        let heavy = CpuTimes {
            user: 10.0,
            system: 2.0,
            nice: 0.0,
            idle: 10.0,
            io_wait: 0.0,
            irq: 0.0,
            soft_irq: 0.0,
            steal: 0.0,
            guest: 0.0,
        };
        let reset = CpuTimes {
            user: 5.0,
            system: 2.0,
            idle: 8.0,
            ..heavy
        };
        // Counters went backwards (reboot or cgroup reset): clamp to 0.
        let percents = core_percents(&[reset], &[heavy], 10.0);
        assert_eq!(percents, vec![0.0]);
    }
}
