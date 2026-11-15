// SPDX-License-Identifier: MIT OR Apache-2.0
//! Control actions: signals and renice.
//!
//! The TUI turns the tag set (or the cursor's process) into a [`Plan`]; the
//! event loop executes it here so the real `kill`/`setpriority` calls stay
//! in one platform-neutral place. Signal numbers come from
//! [`common_signals`], which keeps the per-platform numbers together.

use std::io;

/// One control action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Control {
    /// Send this signal number (as returned by [`common_signals`]).
    Signal(i32),
    /// Add this delta to the process's nice value (F7 raises priority,
    /// F8 lowers it).
    Renice(i32),
    /// Set the Linux I/O priority: the value `ioprio_set` takes, its
    /// class in the high bits (see [`io_priority_options`]).
    IoPriority(u32),
    /// Set the Linux CPU affinity to this mask, bit `i` = core `i` (see
    /// [`affinity_options`]).
    Affinity(u64),
}

/// One control action applied to a set of processes: the pids to act on
/// (every tagged process, or the cursor's process when nothing is tagged)
/// and the action itself.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Plan {
    /// Every pid the action applies to.
    pub pids: Vec<u32>,
    /// The action itself.
    pub action: Control,
}

/// The signals the menu offers, sorted by number, with the per-platform
/// numbers for the names both platforms share.
pub fn common_signals() -> &'static [(&'static str, i32)] {
    #[cfg(target_os = "macos")]
    {
        &[
            ("HUP", 1),
            ("INT", 2),
            ("QUIT", 3),
            ("ABRT", 6),
            ("KILL", 9),
            ("TERM", 15),
            ("STOP", 17),
            ("TSTP", 18),
            ("CONT", 19),
            ("WINCH", 28),
            ("USR1", 30),
            ("USR2", 31),
        ]
    }
    #[cfg(not(target_os = "macos"))]
    {
        &[
            ("HUP", 1),
            ("INT", 2),
            ("QUIT", 3),
            ("ABRT", 6),
            ("KILL", 9),
            ("USR1", 10),
            ("USR2", 12),
            ("TERM", 15),
            ("CONT", 18),
            ("STOP", 19),
            ("TSTP", 20),
            ("WINCH", 28),
        ]
    }
}

/// The signal menu's name for a signal number, or `SIG<n>` when unknown.
pub fn signal_name(number: i32) -> String {
    common_signals()
        .iter()
        .find(|(_, n)| *n == number)
        .map_or_else(|| format!("SIG{number}"), |(name, _)| (*name).to_string())
}

/// Apply one action to one pid.
///
/// # Errors
///
/// Returns the OS error text when the call fails (a vanished pid, or a
/// permission problem — raising another process's priority needs root,
/// and I/O priority or affinity changes on another process need
/// privileges too). The Linux-only actions error on macOS.
pub fn apply_one(pid: u32, action: Control) -> Result<(), String> {
    match action {
        Control::Signal(sig) => send_signal(pid, sig),
        Control::Renice(delta) => change_nice(pid, delta),
        Control::IoPriority(value) => set_io_priority(pid, value),
        Control::Affinity(mask) => set_affinity(pid, mask),
    }
}

/// The I/O priority classes and levels `ioprio_set` takes, flattened
/// into picker rows: best-effort 0..7, realtime 0..7, idle, and the
/// class-less value that clears a custom priority. The value is
/// `class << 13 | level` (`IOPRIO_CLASS_RT` 1, `BE` 2, `IDLE` 3,
/// `NONE` 0); a realtime class needs root, best-effort and idle do not
/// for the process's own priority.
pub fn io_priority_options() -> &'static [(&'static str, u32)] {
    &[
        ("Best-effort 0", 2 << 13),
        ("Best-effort 1", 2 << 13 | 1),
        ("Best-effort 2", 2 << 13 | 2),
        ("Best-effort 3", 2 << 13 | 3),
        ("Best-effort 4", 2 << 13 | 4),
        ("Best-effort 5", 2 << 13 | 5),
        ("Best-effort 6", 2 << 13 | 6),
        ("Best-effort 7", 2 << 13 | 7),
        ("Realtime 0", 1 << 13),
        ("Realtime 1", 1 << 13 | 1),
        ("Realtime 2", 1 << 13 | 2),
        ("Realtime 3", 1 << 13 | 3),
        ("Realtime 4", 1 << 13 | 4),
        ("Realtime 5", 1 << 13 | 5),
        ("Realtime 6", 1 << 13 | 6),
        ("Realtime 7", 1 << 13 | 7),
        ("Idle", 3 << 13),
        ("None (clear)", 0),
    ]
}

/// The CPU affinity picker rows for a host with `cores` cores: one row
/// for every core and one for all of them together. The mask is a
/// `u64`, so cores past 63 cannot be addressed individually; the
/// all-cores row is the full mask.
pub fn affinity_options(cores: usize) -> Vec<(String, u64)> {
    let mut rows = Vec::with_capacity(cores + 1);
    let full = if cores >= 64 {
        u64::MAX
    } else {
        (1 << cores) - 1
    };
    rows.push(("All cores".to_string(), full));
    for core in 0..cores.min(64) {
        rows.push((format!("Core {core}"), 1 << core));
    }
    rows
}

/// Apply a whole plan, keeping each pid's result in order.
pub fn execute(plan: &Plan) -> Vec<(u32, Result<(), String>)> {
    plan.pids
        .iter()
        .map(|pid| (*pid, apply_one(*pid, plan.action)))
        .collect()
}

fn send_signal(pid: u32, sig: i32) -> Result<(), String> {
    let rc = unsafe { libc::kill(pid as libc::c_int, sig) };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!(
            "kill {pid} {}:{}",
            signal_name(sig),
            io::Error::last_os_error()
        ))
    }
}

/// Set the I/O priority (`ioprio_set`, Linux only): the picker's value
/// carries class and level in the `ioprio` encoding.
#[cfg(target_os = "linux")]
fn set_io_priority(pid: u32, value: u32) -> Result<(), String> {
    // IOPRIO_WHO_PROCESS = 1: the pid names one process.
    let rc = unsafe { libc::syscall(libc::SYS_ioprio_set, 1, pid as libc::c_int, value) };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!(
            "ioprio_set {pid} {value:#05x}:{}",
            io::Error::last_os_error()
        ))
    }
}

#[cfg(not(target_os = "linux"))]
fn set_io_priority(_pid: u32, _value: u32) -> Result<(), String> {
    Err("io priority is not available on this platform".to_string())
}

/// Set the CPU affinity mask (`sched_setaffinity`, Linux only): bit `i`
/// of the mask pins the process to core `i`.
#[cfg(target_os = "linux")]
fn set_affinity(pid: u32, mask: u64) -> Result<(), String> {
    let rc = unsafe {
        libc::sched_setaffinity(
            pid as libc::pid_t,
            std::mem::size_of::<u64>(),
            &mask as *const u64 as *const libc::cpu_set_t,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!(
            "sched_setaffinity {pid} {mask:#x}:{}",
            io::Error::last_os_error()
        ))
    }
}

#[cfg(not(target_os = "linux"))]
fn set_affinity(_pid: u32, _mask: u64) -> Result<(), String> {
    Err("cpu affinity is not available on this platform".to_string())
}

fn os_errno() -> i32 {
    #[cfg(target_os = "macos")]
    unsafe {
        *libc::__error()
    }
    #[cfg(not(target_os = "macos"))]
    unsafe {
        *libc::__errno_location()
    }
}

fn clear_errno() {
    #[cfg(target_os = "macos")]
    unsafe {
        *libc::__error() = 0
    }
    #[cfg(not(target_os = "macos"))]
    unsafe {
        *libc::__errno_location() = 0
    }
}

fn get_nice(pid: u32) -> Result<i32, String> {
    clear_errno();
    let nice = unsafe { getpriority_sys(pid) };
    if nice == -1 && os_errno() != 0 {
        return Err(format!(
            "getpriority {pid}: {}",
            io::Error::from_raw_os_error(os_errno())
        ));
    }
    Ok(nice)
}

fn change_nice(pid: u32, delta: i32) -> Result<(), String> {
    let before = get_nice(pid)?;
    let rc = unsafe { setpriority_sys(pid, before + delta) };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!(
            "renice {pid} {before} -> {}:{}",
            before + delta,
            io::Error::last_os_error()
        ))
    }
}

// `getpriority`/`setpriority` take an `id_t` for the pid; on macOS that is
// a `c_int` and on Linux an unsigned id, so cast per platform.
#[cfg(target_os = "macos")]
unsafe fn getpriority_sys(pid: u32) -> i32 {
    unsafe { libc::getpriority(libc::PRIO_PROCESS, pid as libc::id_t) }
}

#[cfg(not(target_os = "macos"))]
unsafe fn getpriority_sys(pid: u32) -> i32 {
    unsafe { libc::getpriority(libc::PRIO_PROCESS, pid as libc::id_t) }
}

#[cfg(target_os = "macos")]
unsafe fn setpriority_sys(pid: u32, nice: i32) -> i32 {
    unsafe { libc::setpriority(libc::PRIO_PROCESS, pid as libc::id_t, nice) }
}

#[cfg(not(target_os = "macos"))]
unsafe fn setpriority_sys(pid: u32, nice: i32) -> i32 {
    unsafe { libc::setpriority(libc::PRIO_PROCESS, pid as libc::id_t, nice) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signal_zero_reports_liveness_without_side_effects() {
        // Signal 0 performs the permission check but sends nothing, so the
        // real `kill` path runs without disturbing anything.
        let me = std::process::id();
        assert_eq!(apply_one(me, Control::Signal(0)), Ok(()));
        // A pid nothing owns is reported, not swallowed.
        let results = execute(&Plan {
            pids: vec![me, 399_999_999],
            action: Control::Signal(0),
        });
        assert_eq!(results[0].0, me);
        assert_eq!(results[0].1, Ok(()));
        assert!(results[1].1.is_err(), "an absent pid must error");
    }

    #[test]
    fn renice_moves_the_own_process_down_one_step() {
        // Lowering our own priority (raising the nice value) needs no
        // privileges; raising it back is not attempted, so the test leaves
        // the process one step nicer than it started.
        let me = std::process::id();
        assert_eq!(apply_one(me, Control::Renice(1)), Ok(()));
    }

    #[test]
    fn signal_names_come_from_the_platform_list() {
        assert_eq!(signal_name(15), "TERM");
        assert!(
            signal_name(99).starts_with("SIG"),
            "unknown numbers stay readable"
        );
        // The list is sorted by number.
        let numbers: Vec<i32> = common_signals().iter().map(|(_, n)| *n).collect();
        let mut sorted = numbers.clone();
        sorted.sort_unstable();
        assert_eq!(numbers, sorted);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn affinity_and_io_priority_act_on_the_own_process() {
        let me = std::process::id();
        // Reading our own mask and writing it back is allowed without
        // privileges, so the real syscall path runs and must succeed.
        let mut mask: u64 = 0;
        let rc = unsafe {
            libc::sched_getaffinity(
                0,
                std::mem::size_of::<u64>(),
                &mut mask as *mut u64 as *mut libc::cpu_set_t,
            )
        };
        assert_eq!(rc, 0, "the host must report its own affinity");
        assert_eq!(apply_one(me, Control::Affinity(mask)), Ok(()));
        // Best-effort 4 lowers the I/O priority of our own process, which
        // needs no privileges either.
        let best_effort_4 = io_priority_options()[4].1;
        assert_eq!(best_effort_4, 2 << 13 | 4);
        assert_eq!(apply_one(me, Control::IoPriority(best_effort_4)), Ok(()));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_option_lists_keep_their_encoding() {
        // 8 best-effort levels, 8 realtime levels, idle, and the clear
        // value; realtime is class 1, best-effort class 2.
        let options = io_priority_options();
        assert_eq!(options.len(), 18);
        assert_eq!(options[0].1, 2 << 13);
        assert_eq!(options[8].1, 1 << 13);
        assert_eq!(options[16].1, 3 << 13);
        assert_eq!(options[17].1, 0);
        // The affinity rows: all cores first, then one row per core.
        let rows = affinity_options(4);
        assert_eq!(rows[0].0, "All cores");
        assert_eq!(rows[0].1, 0b1111);
        assert_eq!(rows[2], ("Core 1".to_string(), 0b10));
        // Past 63 cores the mask saturates and the list stops at 64 rows.
        assert_eq!(affinity_options(80).len(), 65);
        assert_eq!(affinity_options(80)[64].1, 1 << 63);
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn the_linux_only_actions_refuse_on_this_platform() {
        let me = std::process::id();
        assert!(
            apply_one(me, Control::IoPriority(2 << 13 | 4))
                .unwrap_err()
                .contains("not available"),
            "the picker's value must reach the refusal, not the OS"
        );
        assert!(
            apply_one(me, Control::Affinity(1))
                .unwrap_err()
                .contains("not available")
        );
    }
}
