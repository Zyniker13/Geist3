// SPDX-License-Identifier: MIT OR Apache-2.0
//! Per-process detail reads: the environment and the open files.
//!
//! Both are passive reads of what the OS already tracks, taken live when
//! the overlay opens — they never appear in a sample. What the OS allows
//! decides the outcome: a same-user process works unprivileged, another
//! user's process needs privileges, and the error text is reported in
//! the status line either way.

/// The process's environment, one `KEY=VALUE` line per entry.
///
/// Linux reads `/proc/<pid>/environ` (NUL separated). macOS reads the
/// kernel's `KERN_PROCARGS2` block, which holds argc, the exec path,
/// argv and the environment in one buffer.
///
/// # Errors
///
/// The OS error text when the process is gone or the read is not
/// permitted.
pub fn environment(pid: u32) -> Result<Vec<String>, String> {
    #[cfg(target_os = "macos")]
    {
        macos_environ(pid)
    }
    #[cfg(not(target_os = "macos"))]
    {
        linux_environ(pid)
    }
}

/// The process's open file descriptors, one line per fd, sorted by fd
/// number: `fd N -> target` where the target is the resolved link
/// (Linux) or the vnode path (macOS); descriptors without a path keep
/// their type name.
///
/// # Errors
///
/// The OS error text when the process is gone or the read is not
/// permitted.
pub fn open_files(pid: u32) -> Result<Vec<String>, String> {
    #[cfg(target_os = "macos")]
    {
        macos_files(pid)
    }
    #[cfg(not(target_os = "macos"))]
    {
        linux_files(pid)
    }
}

#[cfg(not(target_os = "macos"))]
fn linux_environ(pid: u32) -> Result<Vec<String>, String> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(format!("/proc/{pid}/environ"))
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .map_err(|e| format!("environ {pid}: {e}"))?;
    Ok(split_nul(&bytes))
}

#[cfg(not(target_os = "macos"))]
fn linux_files(pid: u32) -> Result<Vec<String>, String> {
    let dir = std::fs::read_dir(format!("/proc/{pid}/fd"))
        .map_err(|e| format!("open files {pid}: {e}"))?;
    let mut rows = Vec::new();
    for entry in dir {
        let entry = entry.map_err(|e| format!("open files {pid}: {e}"))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let fd: u32 = name
            .parse()
            .map_err(|_| format!("open files {pid}: unexpected entry {name}"))?;
        let target = match std::fs::read_link(entry.path()) {
            // An fd can close between the readdir and this read; a
            // snapshot that omits it is honest, a hard error is not
            // (a loaded CI runner hit exactly this on its own pid).
            Ok(target) => target,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("open files {pid}: fd {fd}: {e}")),
        };
        rows.push((fd, format!("fd {fd} -> {}", target.to_string_lossy())));
    }
    rows.sort_by_key(|(fd, _)| *fd);
    Ok(rows.into_iter().map(|(_, row)| row).collect())
}

/// Split NUL-separated bytes into lines, dropping empty entries.
fn split_nul(bytes: &[u8]) -> Vec<String> {
    bytes
        .split(|b| *b == 0)
        .filter(|part| !part.is_empty())
        .map(|part| String::from_utf8_lossy(part).into_owned())
        .collect()
}

#[cfg(target_os = "macos")]
const KERN_PROCARGS2: i32 = 49;

/// The kernel's `KERN_PROCARGS2` block: argc, the exec path, argv and
/// the environment, NUL separated, fetched through `sysctl`.
#[cfg(target_os = "macos")]
fn macos_environ(pid: u32) -> Result<Vec<String>, String> {
    let mut mib = [libc::CTL_KERN, KERN_PROCARGS2, pid as i32];
    let mut size: libc::size_t = 0;
    let query = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if query != 0 {
        return Err(format!(
            "environ {pid}: {}",
            std::io::Error::last_os_error()
        ));
    }
    let mut buffer = vec![0u8; size];
    let filled = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if filled != 0 {
        return Err(format!(
            "environ {pid}: {}",
            std::io::Error::last_os_error()
        ));
    }
    buffer.truncate(size);
    parse_procargs2(&buffer)
        .ok_or_else(|| format!("environ {pid}: unexpected KERN_PROCARGS2 layout"))
}

/// Parse the `KERN_PROCARGS2` buffer: a leading `argc`, the exec path,
/// NUL padding, argc argv strings, an empty terminator, then the
/// environment entries to the end of the buffer.
#[cfg(target_os = "macos")]
fn parse_procargs2(buffer: &[u8]) -> Option<Vec<String>> {
    if buffer.len() < 4 {
        return None;
    }
    let argc = u32::from_ne_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
    let mut offset = 4;
    // Skip the exec path.
    offset += buffer[offset..].iter().position(|b| *b == 0)? + 1;
    // Skip the alignment padding.
    while offset < buffer.len() && buffer[offset] == 0 {
        offset += 1;
    }
    // Read argc argv strings, then the empty terminator.
    for _ in 0..=argc {
        let end = offset + buffer[offset..].iter().position(|b| *b == 0)?;
        if end == offset {
            offset = end + 1;
            break;
        }
        offset = end + 1;
    }
    Some(split_nul(&buffer[offset..]))
}

/// One `proc_fdinfo` entry from `PROC_PIDLISTFDS`.
#[cfg(target_os = "macos")]
#[repr(C)]
struct ProcFdInfo {
    fd: i32,
    fdtype: u32,
}

/// The path sits in the last `MAXPATHLEN` bytes of the
/// `vnode_fdinfowithpath` record `proc_pidfdinfo` fills.
#[cfg(target_os = "macos")]
const MAXPATHLEN: usize = 1024;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn proc_pidinfo(
        pid: i32,
        flavor: u32,
        arg: u64,
        buffer: *mut core::ffi::c_void,
        buffersize: i32,
    ) -> i32;
    fn proc_pidfdinfo(
        pid: i32,
        fd: i32,
        flavor: i32,
        buffer: *mut core::ffi::c_void,
        buffersize: i32,
    ) -> i32;
}

#[cfg(target_os = "macos")]
const PROC_PIDLISTFDS: u32 = 1;
#[cfg(target_os = "macos")]
const PROC_PIDFDVNODEINFO: i32 = 1;

#[cfg(target_os = "macos")]
fn macos_files(pid: u32) -> Result<Vec<String>, String> {
    // First call asks for the list size, the second fills it.
    let list_size =
        unsafe { proc_pidinfo(pid as i32, PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    if list_size <= 0 {
        return Err(format!(
            "open files {pid}: {}",
            std::io::Error::last_os_error()
        ));
    }
    let mut buffer = vec![0u8; list_size as usize];
    let filled = unsafe {
        proc_pidinfo(
            pid as i32,
            PROC_PIDLISTFDS,
            0,
            buffer.as_mut_ptr().cast(),
            list_size,
        )
    };
    if filled <= 0 {
        return Err(format!(
            "open files {pid}: {}",
            std::io::Error::last_os_error()
        ));
    }
    // Count from what the second call actually filled: an fd can close
    // between the two calls, and counting from the first call's size
    // would read zero-filled tail rows (fd 0, garbage type).
    let count = filled as usize / std::mem::size_of::<ProcFdInfo>();
    let entries: &[ProcFdInfo] =
        unsafe { std::slice::from_raw_parts(buffer.as_ptr().cast(), count) };
    let mut rows = Vec::with_capacity(count);
    for entry in entries {
        let fd = entry.fd;
        let path = vnode_path(pid as i32, fd);
        let row = match path {
            Some(path) => format!("fd {fd} -> {path}"),
            None => format!("fd {fd} (type {})", entry.fdtype),
        };
        rows.push((fd, row));
    }
    rows.sort_by_key(|(fd, _)| *fd);
    Ok(rows.into_iter().map(|(_, row)| row).collect())
}

/// The vnode path of one fd, or `None` when the fd is not a vnode
/// (a socket, a pipe) or the fd vanished.
#[cfg(target_os = "macos")]
fn vnode_path(pid: i32, fd: i32) -> Option<String> {
    let mut buffer = vec![0u8; MAXPATHLEN + 512];
    let filled = unsafe {
        proc_pidfdinfo(
            pid,
            fd,
            PROC_PIDFDVNODEINFO,
            buffer.as_mut_ptr().cast(),
            buffer.len() as i32,
        )
    };
    if filled <= 0 {
        return None;
    }
    // The path is the record's last MAXPATHLEN bytes as a C string.
    let tail = &buffer[buffer.len() - MAXPATHLEN..];
    let len = tail.iter().position(|b| *b == 0)?;
    if len == 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&tail[..len]).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_own_process_environment_reads_back() {
        // Every platform allows a process to read its own environment;
        // the test binary's env is never empty.
        let lines = environment(std::process::id()).expect("own environ");
        assert!(!lines.is_empty(), "the own environment is never empty");
        assert!(
            lines.iter().all(|line| line.contains('=')),
            "env entries are KEY=VALUE: {lines:?}"
        );
    }

    #[test]
    fn the_own_process_open_files_read_back() {
        // The test process holds stdio open, so the list is never empty
        // and comes back sorted by fd.
        let lines = open_files(std::process::id()).expect("own fds");
        assert!(!lines.is_empty(), "stdio is always open");
        let numbers: Vec<u32> = lines
            .iter()
            .map(|line| {
                line.split(' ')
                    .nth(1)
                    .and_then(|word| word.parse().ok())
                    .expect("fd rows start with 'fd N'")
            })
            .collect();
        let mut sorted = numbers.clone();
        sorted.sort_unstable();
        assert_eq!(numbers, sorted, "rows are sorted by fd");
    }

    #[test]
    fn open_files_survives_fd_churn() {
        // An fd can close between the listing and the read of its
        // target; the snapshot must skip it instead of failing. A
        // loaded CI runner hit exactly this on its own pid (Linux,
        // fd 5). Churn pipes on a thread so every run of this test
        // races the list against real closures.
        use std::os::unix::net::UnixStream;
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

        let stop = Arc::new(AtomicBool::new(false));
        let churner_stop = stop.clone();
        let churner = std::thread::spawn(move || {
            while !churner_stop.load(Ordering::Relaxed) {
                let pairs: Vec<_> = (0..32).map(|_| UnixStream::pair()).collect();
                std::thread::yield_now();
                drop(pairs);
            }
        });
        for _ in 0..100 {
            let lines = open_files(std::process::id()).expect("own fds under churn");
            assert!(!lines.is_empty(), "stdio is always open");
        }
        stop.store(true, Ordering::Relaxed);
        churner.join().expect("the churn thread ends");
    }

    #[test]
    fn a_gone_process_reports_an_error() {
        // A pid nothing owns must come back as an error, not a panic or
        // an empty list.
        let absent = 399_999_999u32;
        assert!(environment(absent).is_err());
        assert!(open_files(absent).is_err());
    }
}
