// SPDX-License-Identifier: MIT OR Apache-2.0
//! macOS inputs for `ztop capture`: everything the macOS collector reads,
//! recorded as text before any interpretation (decision 0009).
//!
//! Every recorded field is an allowlisted, non-identifying value. Process
//! names and paths are captured and scrubbed out of committed fixtures by
//! `scripts/scrub-fixture.py` (decision 0007).

use crate::fixture::CapturedInput;

/// Read every known macOS input of this host.
pub(crate) fn collect_inputs() -> Vec<CapturedInput> {
    let mut inputs = Vec::new();
    inputs.extend(sysctl_inputs());
    inputs.extend(mach_inputs());
    inputs.push(process_entry());
    inputs.sort_by(|a, b| a.name.cmp(&b.name));
    inputs.dedup_by(|a, b| a.name == b.name);
    inputs
}

/// The sysctls zTop reads, none of which identify the machine beyond its
/// hardware class (model identifiers are not serial numbers).
const SYSCTL_KEYS: &[(&str, Kind)] = &[
    ("kern.ostype", Kind::Text),
    ("kern.osrelease", Kind::Text),
    ("kern.osproductversion", Kind::Text),
    ("kern.version", Kind::Text),
    ("hw.machine", Kind::Text),
    ("hw.model", Kind::Text),
    ("hw.ncpu", Kind::Number),
    ("hw.memsize", Kind::Number),
    ("hw.byteorder", Kind::Number),
    ("hw.pagesize", Kind::Number),
    ("hw.cputype", Kind::Number),
    ("hw.cpusubtype", Kind::Number),
    ("hw.optional.arm64", Kind::Number),
];

/// How to interpret a sysctl value.
#[derive(Debug, Clone, Copy)]
enum Kind {
    /// NUL-terminated string.
    Text,
    /// Unsigned integer of 4 or 8 bytes (native little-endian).
    Number,
}

/// One entry per sysctl: `sysctl-hw_ncpu` -> `12`.
fn sysctl_inputs() -> Vec<CapturedInput> {
    let mut inputs = Vec::new();
    for (key, kind) in SYSCTL_KEYS {
        let name = format!("sysctl-{}", key.replace('.', "_"));
        let input = match kind {
            Kind::Text => sysctl_text(key).map(|t| CapturedInput::text(&name, t)),
            Kind::Number => sysctl_u64(key).map(|v| CapturedInput::text(&name, v.to_string())),
        };
        // A key the host does not have is simply not an input of this host.
        if let Some(input) = input {
            inputs.push(input);
        }
    }
    inputs
}

/// One `hostinfo` entry with the Mach values the collector parses: CPU tick
/// counters, load average, virtual-memory counters, swap and boot time.
fn mach_inputs() -> Vec<CapturedInput> {
    let mut text = String::new();
    // CPU tick counters (raw counts since boot; the collector derives busy
    // percentages between samples).
    if let Some(ticks) = processor_ticks() {
        for (i, t) in ticks.iter().enumerate() {
            text.push_str(&format!(
                "ticks {i} {} {} {} {}\n",
                t.user, t.system, t.idle, t.nice
            ));
        }
    }
    // Load average in kernel units (LOAD_SCALE = 1000), from the same
    // `vm.loadavg` sysctl the collector reads.
    if let Some(raw) = sysctl_raw("vm.loadavg") {
        if raw.len() >= 12 {
            let v = |i: usize| i32::from_le_bytes(raw[i * 4..i * 4 + 4].try_into().unwrap()) as i64;
            text.push_str(&format!("loadavg {} {} {}\n", v(0), v(1), v(2)));
        }
    }
    // Virtual-memory counters (bytes).
    if let Some(vm) = vm_statistics() {
        text.push_str(&format!(
            "vm free {} active {} inactive {} wired {} compressed {}\n",
            vm.free, vm.active, vm.inactive, vm.wired, vm.compressed
        ));
    }
    // Swap from the `vm.swapusage` sysctl: an `xsw_usage` struct of three
    // u64 counters (total, avail, used) in bytes.
    if let Some(raw) = sysctl_raw("vm.swapusage") {
        if raw.len() >= 24 {
            let u = |i: usize| u64::from_le_bytes(raw[i * 8..i * 8 + 8].try_into().unwrap());
            text.push_str(&format!(
                "swap total {} avail {} used {}\n",
                u(0),
                u(1),
                u(2)
            ));
        }
    }
    // Boot time from kern.boottime (a struct timeval recorded as raw bytes).
    if let Some((sec, usec)) = boottime() {
        text.push_str(&format!("boottime {sec} {usec}\n"));
    }
    if text.is_empty() {
        return Vec::new();
    }
    vec![CapturedInput::text("hostinfo", text)]
}

/// Tick counters of one CPU, in Mach `cpu_usage_info` order.
#[derive(Debug, Clone, Copy)]
struct CpuTicks {
    user: u64,
    system: u64,
    idle: u64,
    nice: u64,
}

/// Read the per-CPU tick counters via `host_processor_info`.
fn processor_ticks() -> Option<Vec<CpuTicks>> {
    // `host_processor_info` flavor for `processor_cpu_load_info` (per-CPU
    // tick counters since boot, in CPU_USAGE_MAX = 4 counters per CPU).
    const PROCESSOR_CPU_LOAD_INFO: u32 = 2;
    unsafe {
        let mut count = 0u32;
        let mut cpu_count = 0u32;
        let mut ptr: *mut i32 = std::ptr::null_mut();
        if host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &mut cpu_count,
            &mut ptr,
            &mut count,
        ) != 0
        {
            return None;
        }
        let mut out = Vec::with_capacity(cpu_count as usize);
        // Four i32 counters per CPU: user, system, idle, nice.
        for cpu in 0..cpu_count as usize {
            let base = ptr.add(cpu * 4);
            out.push(CpuTicks {
                user: (*base).max(0) as u64,
                system: (*base.add(1)).max(0) as u64,
                idle: (*base.add(2)).max(0) as u64,
                nice: (*base.add(3)).max(0) as u64,
            });
        }
        // The buffer is allocated by the caller of `host_processor_info`
        // with `vm_deallocate` semantics.
        mach_vm_deallocate(mach_task_self(), ptr as usize, (count as usize) * 4);
        Some(out)
    }
}

/// Selected virtual-memory counters in bytes.
struct VmStats {
    free: u64,
    active: u64,
    inactive: u64,
    wired: u64,
    compressed: u64,
}

/// Read the virtual-memory counters via `host_statistics64`.
fn vm_statistics() -> Option<VmStats> {
    // `host_statistics64` flavor for `vm_statistics64_data_t`.
    const HOST_VM_INFO64: u32 = 4;
    const HOST_VM_INFO64_COUNT: u32 = 60;
    unsafe {
        let mut stats = VmStats64::zeroed();
        let mut count = HOST_VM_INFO64_COUNT;
        if host_statistics64(
            mach_host_self(),
            HOST_VM_INFO64,
            &mut stats as *mut _ as *mut i32,
            &mut count,
        ) != 0
        {
            return None;
        }
        let page = sysctl_u64("hw.pagesize").unwrap_or(4096);
        Some(VmStats {
            free: stats.free_count as u64 * page,
            active: stats.active_count as u64 * page,
            inactive: stats.inactive_count as u64 * page,
            wired: stats.wire_count as u64 * page,
            compressed: stats.compressor_page_count as u64 * page,
        })
    }
}

/// Boot time from the `kern.boottime` sysctl (a `struct timeval`).
fn boottime() -> Option<(i64, i64)> {
    let raw = sysctl_raw("kern.boottime")?;
    if raw.len() < 16 {
        return None;
    }
    let sec = i64::from_le_bytes(raw[..8].try_into().ok()?);
    let usec = i64::from_le_bytes(raw[8..16].try_into().ok()?);
    Some((sec, usec))
}

/// One `processes` entry: the libproc snapshot the collector parses.
///
/// Lines are `pid ppid status uid utime stime rss threads name` with an
/// integer status byte and the name last in quotes. `utime` and `stime`
/// are cumulative CPU nanoseconds (mach absolute ticks converted with
/// `mach_timebase_info`), `rss` resident bytes and `threads` the thread
/// count, from `PROC_PIDTASKINFO`; the kernel denies that call for other
/// users' processes, and then those four fields are `-` (decision 0009:
/// unavailable, never faked). The committed fixture scrubs `name`
/// (decision 0007); the live collector reads the real names.
fn process_entry() -> CapturedInput {
    let pids = list_pids();
    let tb = task_timebase();
    let mut text = String::new();
    for pid in pids {
        let Some(bsd) = bsd_info(pid) else {
            continue;
        };
        // Names can contain spaces; keep them in a quoted tail field.
        let name = bsd.comm.replace(['\\', '"'], " ");
        let (utime, stime, rss, threads) = match task_info(pid) {
            Some(task) => (
                ticks_to_ns(task.total_user, tb).to_string(),
                ticks_to_ns(task.total_system, tb).to_string(),
                task.resident_size.to_string(),
                task.threadnum.to_string(),
            ),
            None => (
                UNAVAILABLE.to_string(),
                UNAVAILABLE.to_string(),
                UNAVAILABLE.to_string(),
                UNAVAILABLE.to_string(),
            ),
        };
        text.push_str(&format!(
            "{} {} {} {} {} {} {} {} \"{}\"\n",
            pid, bsd.ppid, bsd.status, bsd.uid, utime, stime, rss, threads, name
        ));
    }
    CapturedInput::text("processes", text)
}

/// Recorded in place of a value the OS would not give us (decision 0009).
const UNAVAILABLE: &str = "-";

/// All pids via `proc_listallpids`.
fn list_pids() -> Vec<u32> {
    unsafe {
        // A NULL buffer and zero size return the count of pids.
        let n = proc_listallpids(std::ptr::null_mut(), 0);
        if n <= 0 {
            return Vec::new();
        }
        // Room for the processes that start between the two calls.
        let slots = (n + 64) as usize;
        let mut pids = vec![0i32; slots];
        let n = proc_listallpids(
            pids.as_mut_ptr().cast(),
            (slots * std::mem::size_of::<i32>()) as i32,
        );
        pids.truncate(n.max(0) as usize);
        // The kernel returns pids in arbitrary (hash) order; sort so the
        // recorded text is deterministic and pid 1 sorts first.
        pids.sort_unstable();
        pids.into_iter().map(|p| p as u32).collect()
    }
}

/// The fields of `proc_bsdshortinfo` zTop records.
struct BsdInfo {
    ppid: u32,
    status: u32,
    uid: u32,
    comm: String,
}

/// `PROC_PIDT_SHORTBSDINFO`: pid, ppid, pgid, status, 16-byte comm, uids,
/// gids and flags.
const PROC_PIDT_SHORTBSDINFO: u32 = 13;

#[repr(C)]
struct ProcBsdShortInfo {
    pid: u32,
    ppid: u32,
    pgid: u32,
    status: u32,
    comm: [u8; 16],
    flags: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu: u32,
}

/// Read the BSD info of one process.
fn bsd_info(pid: u32) -> Option<BsdInfo> {
    unsafe {
        let mut info = std::mem::zeroed::<ProcBsdShortInfo>();
        let n = proc_pidinfo(
            pid as i32,
            PROC_PIDT_SHORTBSDINFO,
            0,
            &mut info as *mut _ as *mut core::ffi::c_void,
            std::mem::size_of::<ProcBsdShortInfo>() as i32,
        );
        if n as usize != std::mem::size_of::<ProcBsdShortInfo>() {
            return None;
        }
        let end = info.comm.iter().position(|&b| b == 0).unwrap_or(16);
        let comm = String::from_utf8_lossy(&info.comm[..end]).into_owned();
        Some(BsdInfo {
            ppid: info.ppid,
            status: info.status,
            uid: info.uid,
            comm,
        })
    }
}

/// Thread count of one process via `PROC_PIDTASKINFO`.
const PROC_PIDTASKINFO: u32 = 4;

/// `struct proc_taskinfo` (96 bytes): byte and microsecond counts are u64,
/// the counters i32, ending at `priority`. Matches the SDK layout; the size
/// assert keeps it pinned to what the kernel actually returns.
#[repr(C)]
struct ProcTaskInfo {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
}
const _: () = assert!(std::mem::size_of::<ProcTaskInfo>() == 96);

/// Read the task info of one process. Unprivileged callers are denied this
/// for other users' processes; the caller then marks the fields unavailable.
fn task_info(pid: u32) -> Option<ProcTaskInfo> {
    unsafe {
        let mut info = std::mem::zeroed::<ProcTaskInfo>();
        let n = proc_pidinfo(
            pid as i32,
            PROC_PIDTASKINFO,
            0,
            &mut info as *mut _ as *mut core::ffi::c_void,
            std::mem::size_of::<ProcTaskInfo>() as i32,
        );
        if n as usize != std::mem::size_of::<ProcTaskInfo>() {
            return None;
        }
        Some(info)
    }
}

/// `struct mach_timebase_info`: nanoseconds per absolute-time tick is
/// `numer / denom` (this host: 125/3, i.e. 24 MHz ticks). Boot-stable.
#[repr(C)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

/// The mach timebase used to convert absolute ticks to nanoseconds.
fn task_timebase() -> (u32, u32) {
    unsafe {
        let mut tb = std::mem::zeroed::<MachTimebaseInfo>();
        if mach_timebase_info(&mut tb) == 0 && tb.denom != 0 {
            (tb.numer, tb.denom)
        } else {
            (1, 1)
        }
    }
}

/// Convert mach absolute ticks to nanoseconds. Wide math keeps a large
/// cumulative counter from overflowing before the division.
fn ticks_to_ns(ticks: u64, tb: (u32, u32)) -> u64 {
    (u128::from(ticks) * u128::from(tb.0) / u128::from(tb.1)) as u64
}

unsafe extern "C" {
    fn sysctlbyname(
        name: *const libc::c_char,
        oldp: *mut libc::c_void,
        oldlenp: *mut usize,
        newp: *mut libc::c_void,
        newlen: usize,
    ) -> i32;
    fn host_processor_info(
        host: u32,
        flavor: u32,
        out_processor_count: *mut u32,
        out_info: *mut *mut i32,
        out_info_count: *mut u32,
    ) -> i32;
    fn mach_host_self() -> u32;
    fn mach_task_self() -> u32;
    fn mach_vm_deallocate(target: u32, address: usize, size: usize) -> i32;
    fn host_statistics64(host: u32, flavor: u32, stats: *mut i32, count: *mut u32) -> i32;
    fn proc_listallpids(buffer: *mut libc::c_void, buffersize: i32) -> i32;
    fn proc_pidinfo(
        pid: i32,
        flavor: u32,
        arg: u64,
        buffer: *mut core::ffi::c_void,
        buffersize: i32,
    ) -> i32;
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
}

/// The subset of `vm_statistics64` zTop records, in pages.
#[repr(C)]
struct VmStats64 {
    free_count: i32,
    active_count: i32,
    inactive_count: i32,
    wire_count: i32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purgeable_count: u64,
    purges: u64,
    speculative_count: i32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: i32,
    throttled_count: i32,
    file_backed_page_count: i32,
    anonymous_page_count: i32,
    internal_page_count: i32,
    total_uncompressed_pages: i64,
}

impl VmStats64 {
    fn zeroed() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

/// Read a sysctl as raw bytes.
fn sysctl_raw(name: &str) -> Option<Vec<u8>> {
    let cname = std::ffi::CString::new(name).ok()?;
    // SAFETY: `sysctlbyname` only reads the NUL-terminated name and writes
    // into buffers we own. The size probe and the read are two calls; the
    // values here are stable kernel constants, so a size change between
    // calls is not a concern in practice, and we re-truncate to the
    // returned length afterwards.
    unsafe {
        let mut len: usize = 0;
        if sysctlbyname(
            cname.as_ptr(),
            std::ptr::null_mut(),
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
            || len == 0
        {
            return None;
        }
        let mut buf = vec![0u8; len];
        if sysctlbyname(
            cname.as_ptr(),
            buf.as_mut_ptr().cast::<libc::c_void>(),
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        buf.truncate(len);
        Some(buf)
    }
}

/// Read a sysctl as text up to the first NUL.
pub(crate) fn sysctl_text(name: &str) -> Option<String> {
    let raw = sysctl_raw(name)?;
    let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
    Some(String::from_utf8_lossy(&raw[..end]).into_owned())
}

/// Parse a sysctl integer of 4 or 8 bytes (macOS uses native-endian
/// little-endian integers of whatever width the key defines; `hw.ncpu`
/// is 4 bytes, `hw.memsize` 8).
pub(crate) fn sysctl_u64(name: &str) -> Option<u64> {
    let raw = sysctl_raw(name)?;
    match raw.len() {
        4 => Some(u32::from_le_bytes(raw[..4].try_into().ok()?) as u64),
        8 => Some(u64::from_le_bytes(raw[..8].try_into().ok()?)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture::FixtureData;

    /// The live hostinfo entry records load, vm, swap and boottime.
    #[test]
    fn hostinfo_records_swap_loadavg_vm_and_boottime() {
        let inputs = collect_inputs();
        let host = inputs
            .iter()
            .find(|i| i.name == "hostinfo")
            .expect("hostinfo entry");
        let FixtureData::Text(text) = &host.data else {
            panic!("hostinfo is text");
        };
        assert!(text.contains("loadavg "), "loadavg line: {text}");
        assert!(text.contains("vm free "), "vm line: {text}");
        assert!(text.contains("swap total "), "swap line: {text}");
        // A real host has a positive swap total and a boot time in the past.
        let swap: u64 = text
            .lines()
            .find(|l| l.starts_with("swap total "))
            .and_then(|l| l.split_whitespace().nth(2))
            .and_then(|v| v.parse().ok())
            .expect("swap total");
        assert!(swap > 0, "swap total positive: {swap}");
        assert!(text.contains("boottime "), "boottime line: {text}");
    }

    /// The live processes entry is ascending and lists pid 0 (kernel_task).
    #[test]
    fn processes_lists_pid_zero_first() {
        let inputs = collect_inputs();
        let procs = inputs
            .iter()
            .find(|i| i.name == "processes")
            .expect("processes entry");
        let FixtureData::Text(text) = &procs.data else {
            panic!("processes is text");
        };
        let first = text.lines().next().expect("at least one process");
        let pid: u32 = first
            .split_whitespace()
            .next()
            .expect("pid field")
            .parse()
            .expect("pid is a number");
        // Pids are ascending after the sort; pid 0 (kernel_task) comes first.
        assert_eq!(pid, 0, "first listed process is pid 0");
        assert!(text.lines().count() > 10, "many processes: {text}");
        // launchd (pid 1) is always present.
        assert!(
            text.lines().any(|l| l.starts_with("1 ")),
            "pid 1 present: {text}"
        );
        // Name tail field is quoted.
        assert!(first.contains(" \""), "quoted name tail: {first}");
    }

    /// The processes entry has eight numeric-or-`-` fields before the
    /// quoted name; pid 0 (kernel_task) runs as root, so its task fields
    /// are `-`, and at least one same-user process has real values.
    #[test]
    fn processes_record_taskinfo_fields() {
        let inputs = collect_inputs();
        let procs = inputs
            .iter()
            .find(|i| i.name == "processes")
            .expect("processes entry");
        let FixtureData::Text(text) = &procs.data else {
            panic!("processes is text");
        };
        let first = text.lines().next().expect("at least one process");
        let fields: Vec<&str> = first.split(' ').collect();
        assert_eq!(
            fields.len(),
            9,
            "pid ppid status uid utime stime rss threads name: {first}"
        );
        assert_eq!(fields[0], "0", "first line is pid 0");
        for f in &fields[4..8] {
            assert_eq!(*f, "-", "root-owned kernel_task has no taskinfo: {first}");
        }
        // A same-user process (this test binary among them) has values.
        assert!(
            text.lines().any(|l| l
                .split(' ')
                .skip(4)
                .take(4)
                .all(|f| f.bytes().all(|b| b.is_ascii_digit()))),
            "some process carries taskinfo values: {text}"
        );
    }

    /// Absolute ticks convert to nanoseconds with the host timebase.
    #[test]
    fn ticks_to_ns_uses_timebase() {
        assert_eq!(super::ticks_to_ns(12_000_000, (125, 3)), 500_000_000);
        assert_eq!(super::ticks_to_ns(3, (1, 1)), 3);
        assert_eq!(super::ticks_to_ns(0, (125, 3)), 0);
    }
}
