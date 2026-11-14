// SPDX-License-Identifier: MIT OR Apache-2.0
//! Control actions: signals and renice.
//!
//! The TUI turns the tag set (or the cursor's process) into a [`Plan`]; the
//! event loop executes it here so the real `kill`/`setpriority` calls stay
//! in one platform-neutral place. Signal numbers come from
//! [`common_signals`], which keeps the per-platform numbers together.

use std::io;

/// One control action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// Send this signal number (as returned by [`common_signals`]).
    Signal(i32),
    /// Add this delta to the process's nice value (F7 raises priority,
    /// F8 lowers it).
    Renice(i32),
}

/// One control action applied to a set of processes: the pids to act on
/// (every tagged process, or the cursor's process when nothing is tagged)
/// and the action itself.
#[derive(Debug, Clone, PartialEq, Eq)]
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
/// permission problem — raising another process's priority needs root).
pub fn apply_one(pid: u32, action: Control) -> Result<(), String> {
    match action {
        Control::Signal(sig) => send_signal(pid, sig),
        Control::Renice(delta) => change_nice(pid, delta),
    }
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
}
