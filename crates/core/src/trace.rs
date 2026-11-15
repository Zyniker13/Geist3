// SPDX-License-Identifier: MIT OR Apache-2.0
//! The syscall tracer: attach to one process with `ptrace`, record one
//! line per completed syscall, and hand the lines to the TUI.
//!
//! Linux only, and only where the kernel allows the attach: a child of
//! this process always works, another user's process needs privileges.
//! The tracer runs on its own thread (`PTRACE_SEIZE` +
//! `PTRACE_GET_SYSCALL_INFO`, so no per-architecture register layouts),
//! keeps the newest lines in a capped ring, and stops with
//! `PTRACE_INTERRUPT` + `PTRACE_DETACH` when dropped. Every other
//! platform refuses up front: macOS has no user-space ptrace tracing
//! without special entitlements, so ztop reports unavailable there
//! instead of pretending.

/// How many trace lines the ring keeps: the newest line per completed
/// syscall, older ones dropped as the process works.
#[cfg(target_os = "linux")]
const RING_LINES: usize = 512;

/// One running tracer: the shared ring the TUI drains and the thread
/// that fills it. Dropping the handle stops the thread and detaches.
#[cfg(target_os = "linux")]
pub struct Trace {
    pid: u32,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    lines: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<String>>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

#[cfg(target_os = "linux")]
impl std::fmt::Debug for Trace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Trace").field("pid", &self.pid).finish()
    }
}

#[cfg(target_os = "linux")]
impl Drop for Trace {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        // Wake the waiter so the thread sees the stop flag; an ESRCH or
        // permission failure here just means the tracee is already gone.
        unsafe {
            libc::ptrace(libc::PTRACE_INTERRUPT, self.pid as libc::pid_t, 0, 0);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(target_os = "linux")]
impl Trace {
    /// The pid this tracer follows.
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// Take every line recorded since the last drain, oldest first.
    pub fn drain(&self) -> Vec<String> {
        let mut ring = self.lines.lock().expect("trace ring");
        ring.drain(..).collect()
    }
}

/// The tracer's public name: the running tracer on Linux (aliased so
/// callers need no platform-specific type), the inert stub elsewhere.
#[cfg(target_os = "linux")]
pub type TraceHandle = Trace;

/// The running tracer's public shape on platforms where tracing is
/// refused: never constructed, but keeps signatures platform-neutral
/// (an empty drain, since no tracer ever runs).
#[cfg(not(target_os = "linux"))]
pub struct TraceHandle;

#[cfg(not(target_os = "linux"))]
impl TraceHandle {
    /// Take every line recorded since the last drain: nothing, as no
    /// tracer ever runs on this platform.
    pub fn drain(&self) -> Vec<String> {
        Vec::new()
    }
}

/// Start tracing `pid`: attach, and record one line per completed
/// syscall until the handle is dropped.
///
/// # Errors
///
/// "syscall tracing is not available on this platform" away from Linux;
/// the OS error text when the attach itself fails (gone pid, no
/// permission, or a kernel without `PTRACE_GET_SYSCALL_INFO`).
#[cfg(not(target_os = "linux"))]
pub fn start(pid: u32) -> Result<TraceHandle, String> {
    let _ = pid;
    Err("syscall tracing is not available on this platform".to_string())
}

#[cfg(target_os = "linux")]
pub fn start(pid: u32) -> Result<TraceHandle, String> {
    let pid_t = pid as libc::pid_t;
    // SEIZE with PTRACE_O_TRACESYSGOOD is not needed for
    // GET_SYSCALL_INFO, but seizing is: it attaches without stopping the
    // tracee and marks the tracer as its listener.
    let seized = unsafe { libc::ptrace(libc::PTRACE_SEIZE, pid_t, 0, 0) };
    if seized != 0 {
        return Err(format!("ptrace {pid}: {}", std::io::Error::last_os_error()));
    }
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let lines = std::sync::Arc::new(std::sync::Mutex::new(
        std::collections::VecDeque::with_capacity(RING_LINES),
    ));
    let thread_stop = stop.clone();
    let thread_lines = lines.clone();
    let thread = std::thread::Builder::new()
        .name(format!("ztop-trace-{pid}"))
        .spawn(move || trace_loop(pid_t, thread_stop, thread_lines))
        .map_err(|e| format!("trace thread: {e}"))?;
    Ok(Trace {
        pid,
        stop,
        lines,
        thread: Some(thread),
    })
}

/// The tracer thread: wait for stops, read one syscall-info record per
/// stop, and resume. Exit events become lines; entry events just resume.
#[cfg(target_os = "linux")]
fn trace_loop(
    pid: libc::pid_t,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    lines: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<String>>>,
) {
    // PTRACE_SEIZE stops report through waitpid even though the tracee
    // is not a child; __WALL covers the tracee's threads. Waiting on the
    // tracee's pid specifically — never -1 — so the tracer can never
    // reap another part of the process tree.
    const WALL: libc::c_int = 0x4000_0000;
    loop {
        if stop.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        let mut status: libc::c_int = 0;
        let waited = unsafe { libc::waitpid(pid, &mut status, WALL) };
        if waited < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            // ECHILD: the tracee is gone (or reaped elsewhere).
            break;
        }
        if libc::WIFSTOPPED(status) {
            let mut info = [0u8; 128];
            // A short read means the stop is not a syscall stop; op
            // stays out of the entry/exit range, so the resume below
            // treats it like a signal-delivery stop it knows nothing
            // about and passes the signal through.
            let mut op: u8 = u8::MAX;
            let read = unsafe {
                libc::ptrace(
                    libc::PTRACE_GET_SYSCALL_INFO,
                    pid,
                    0,
                    info.as_mut_ptr() as *mut libc::c_void,
                )
            };
            if read as usize >= 32 {
                // The record: op u8, pad[3], arch u32, two u64 pointers,
                // then the op-specific union (entry: nr + args[6];
                // exit: nr + args[6] + ret + is_error). The offsets are
                // identical on every 64-bit architecture.
                op = info[0];
                let nr = u64::from_ne_bytes(info[32..40].try_into().expect("32 bytes"));
                if op == 2 {
                    // Exit: ret at 88, is_error at 96.
                    let ret = i64::from_ne_bytes(info[88..96].try_into().expect("88 bytes"));
                    let is_error = info[96];
                    let line = if is_error != 0 {
                        format!("{} = -{}", syscall_name(nr), -ret)
                    } else {
                        format!("{} = {ret:#x}", syscall_name(nr))
                    };
                    let mut ring = lines.lock().expect("trace ring");
                    if ring.len() == RING_LINES {
                        ring.pop_front();
                    }
                    ring.push_back(line);
                }
            }
            // Resume: step to the next syscall stop. A stop that is not a
            // syscall stop is a signal-delivery-stop; resuming it with 0
            // would swallow the signal, so real signals are passed back
            // unchanged (SIGTRAP and SIGSTOP belong to the tracer/stop
            // machinery itself). Group-stops resume too — a tracee
            // stopped before the trace continues under the tracer.
            let resume_sig = if op == 0 {
                match libc::WSTOPSIG(status) {
                    libc::SIGTRAP | libc::SIGSTOP => 0,
                    sig => sig,
                }
            } else {
                0
            };
            // Failures here mean the tracee died under us; the next
            // waitpid says so.
            unsafe {
                libc::ptrace(
                    libc::PTRACE_SYSCALL,
                    pid,
                    0,
                    resume_sig as *mut libc::c_void,
                );
            }
        } else if libc::WIFEXITED(status) || libc::WIFSIGNALED(status) {
            break;
        }
    }
    // Detach so the tracee runs free again. The stop flag is set when
    // this runs through Drop; on tracee exit this is a harmless ESRCH.
    unsafe {
        libc::ptrace(libc::PTRACE_DETACH, pid, 0, 0);
    }
}

/// The syscall number's name, from a curated common-syscall table for
/// the target architecture; anything else reports `syscall N` rather
/// than a guessed name.
#[cfg(target_os = "linux")]
pub fn syscall_name(nr: u64) -> String {
    let table: &[(u64, &str)] = match std::env::consts::ARCH {
        "x86_64" => X86_64_SYSCALLS,
        "aarch64" => AARCH64_SYSCALLS,
        _ => &[],
    };
    table
        .iter()
        .find(|(known, _)| *known == nr)
        .map(|(_, name)| (*name).to_string())
        .unwrap_or_else(|| format!("syscall {nr}"))
}

/// The common x86_64 syscall numbers ztop names; the rest stay numeric.
#[cfg(target_os = "linux")]
const X86_64_SYSCALLS: &[(u64, &str)] = &[
    (0, "read"),
    (1, "write"),
    (2, "open"),
    (3, "close"),
    (4, "stat"),
    (5, "fstat"),
    (7, "poll"),
    (8, "lseek"),
    (9, "mmap"),
    (10, "mprotect"),
    (11, "munmap"),
    (12, "brk"),
    (13, "rt_sigaction"),
    (14, "rt_sigprocmask"),
    (15, "rt_sigreturn"),
    (16, "ioctl"),
    (17, "pread64"),
    (18, "pwrite64"),
    (19, "readv"),
    (20, "writev"),
    (24, "sched_yield"),
    (25, "mremap"),
    (28, "madvise"),
    (32, "dup"),
    (33, "dup2"),
    (35, "nanosleep"),
    (39, "getpid"),
    (41, "socket"),
    (42, "connect"),
    (43, "accept"),
    (44, "sendto"),
    (45, "recvfrom"),
    (46, "sendmsg"),
    (47, "recvmsg"),
    (49, "bind"),
    (50, "listen"),
    (57, "fork"),
    (59, "execve"),
    (60, "exit"),
    (61, "wait4"),
    (62, "kill"),
    (72, "fcntl"),
    (78, "getdents"),
    (79, "getcwd"),
    (87, "unlink"),
    (89, "readlink"),
    (96, "gettimeofday"),
    (98, "getrusage"),
    (101, "ptrace"),
    (102, "getuid"),
    (104, "getgid"),
    (110, "getppid"),
    (131, "tgkill"),
    (186, "gettid"),
    (202, "futex"),
    (218, "set_tid_address"),
    (228, "clock_gettime"),
    (230, "clock_nanosleep"),
    (232, "epoll_wait"),
    (233, "epoll_ctl"),
    (257, "openat"),
    (262, "newfstatat"),
    (263, "unlinkat"),
    (267, "readlinkat"),
    (271, "ppoll"),
    (280, "utimensat"),
    (291, "epoll_create1"),
    (292, "dup3"),
    (293, "pipe2"),
    (295, "preadv"),
    (296, "pwritev"),
    (302, "prlimit64"),
    (309, "getcpu"),
    (318, "getrandom"),
    (332, "statx"),
    (425, "io_uring_setup"),
    (426, "io_uring_enter"),
    (435, "clone3"),
    (436, "close_range"),
    (437, "openat2"),
    (439, "faccessat2"),
];

/// The common generic (aarch64) syscall numbers ztop names.
#[cfg(target_os = "linux")]
const AARCH64_SYSCALLS: &[(u64, &str)] = &[
    (19, "eventfd2"),
    (20, "epoll_create1"),
    (21, "epoll_ctl"),
    (22, "epoll_pwait"),
    (23, "dup"),
    (24, "dup3"),
    (25, "fcntl"),
    (26, "inotify_init1"),
    (29, "ioctl"),
    (33, "mknodat"),
    (34, "mkdirat"),
    (35, "unlinkat"),
    (36, "symlinkat"),
    (37, "linkat"),
    (38, "renameat"),
    (43, "statfs"),
    (44, "fstatfs"),
    (45, "truncate"),
    (46, "ftruncate"),
    (48, "faccessat"),
    (49, "chdir"),
    (50, "fchdir"),
    (51, "chroot"),
    (52, "fchmod"),
    (53, "fchmodat"),
    (54, "fchownat"),
    (55, "fchown"),
    (56, "openat"),
    (57, "close"),
    (59, "pipe2"),
    (61, "getdents64"),
    (62, "lseek"),
    (63, "read"),
    (64, "write"),
    (65, "readv"),
    (66, "writev"),
    (67, "pread64"),
    (68, "pwrite64"),
    (73, "ppoll"),
    (78, "readlinkat"),
    (79, "newfstatat"),
    (80, "fstat"),
    (82, "fsync"),
    (83, "fdatasync"),
    (93, "exit"),
    (94, "exit_group"),
    (96, "set_tid_address"),
    (98, "futex"),
    (99, "set_robust_list"),
    (101, "nanosleep"),
    (113, "clock_gettime"),
    (114, "clock_getres"),
    (115, "clock_nanosleep"),
    (116, "syslog"),
    (117, "ptrace"),
    (124, "sched_yield"),
    (129, "kill"),
    (131, "tgkill"),
    (132, "sigaltstack"),
    (134, "rt_sigaction"),
    (135, "rt_sigprocmask"),
    (139, "rt_sigsuspend"),
    (160, "uname"),
    (172, "getpid"),
    (173, "getppid"),
    (174, "getuid"),
    (176, "getgid"),
    (178, "gettid"),
    (179, "sysinfo"),
    (214, "brk"),
    (215, "munmap"),
    (216, "mremap"),
    (220, "clone"),
    (221, "execve"),
    (222, "mmap"),
    (226, "mprotect"),
    (233, "madvise"),
    (260, "wait4"),
    (261, "prlimit64"),
    (278, "getrandom"),
    (279, "memfd_create"),
    (283, "statx"),
    (286, "io_uring_setup"),
    (287, "io_uring_enter"),
    (291, "epoll_pwait2"),
    (435, "clone3"),
    (436, "close_range"),
    (437, "openat2"),
    (439, "faccessat2"),
];

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    /// A child ztop may trace without privileges (yama's default allows
    /// tracing your own children), kept alive for the test's duration.
    fn traceable_child() -> std::process::Child {
        std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .expect("spawn the traced child")
    }

    #[test]
    fn the_tracer_records_syscalls_of_a_child() {
        let mut child = traceable_child();
        let pid = child.id();
        let trace = start(pid).expect("trace the child");
        // The child is in nanosleep; the entry stop arrives first, the
        // exit stop completes the line. Wait long enough for both.
        std::thread::sleep(std::time::Duration::from_millis(500));
        let lines = trace.drain();
        assert!(
            lines.iter().any(|line| line.contains("nanosleep")),
            "expected a nanosleep line, got {lines:?}"
        );
        drop(trace);
        child.kill().expect("kill the traced child");
        let _ = child.wait();
    }

    #[test]
    fn the_tracer_refuses_a_gone_pid() {
        // A pid nothing owns: the SEIZE fails with an OS error rather
        // than starting a thread that spins.
        assert!(start(399_999_999).is_err());
    }

    #[test]
    fn syscall_names_cover_the_hot_path() {
        // Spot checks on both architectures' tables, plus the numeric
        // fallback for a number no table carries.
        assert_eq!(syscall_name(0), "read");
        assert_eq!(syscall_name(1), "write");
        if std::env::consts::ARCH == "x86_64" {
            assert_eq!(syscall_name(257), "openat");
            assert_eq!(syscall_name(228), "clock_gettime");
        } else if std::env::consts::ARCH == "aarch64" {
            assert_eq!(syscall_name(56), "openat");
            assert_eq!(syscall_name(63), "read");
        }
        assert_eq!(syscall_name(999_999), "syscall 999999");
    }
}
