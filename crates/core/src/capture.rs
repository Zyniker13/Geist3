// SPDX-License-Identifier: MIT OR Apache-2.0
//! `ztop capture`: record this host's raw inputs as a fixture.
//!
//! The recorded inputs are exactly what the platform collectors read, saved
//! before any interpretation, so a fixture recorded on one machine drives the
//! collectors' tests on any machine. Recorded keys are an allowlist that
//! excludes anything host-identifying (serial numbers, UUIDs, hostnames).

use std::path::Path;

use crate::fixture::{CapturedInput, write_fixture};

/// Capture errors.
#[derive(Debug, thiserror::Error)]
pub enum CaptureError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("fixture: {0}")]
    Fixture(#[from] crate::fixture::FixtureError),
    #[error("capturing is not supported on this platform")]
    UnsupportedPlatform,
}

/// Record every known input of this host into `dir`; returns the entry count.
pub fn capture_to(dir: &Path) -> Result<usize, CaptureError> {
    let inputs = collect()?;
    let kernel = kernel_version()?;
    write_fixture(dir, platform_name(), &kernel, &inputs).map_err(Into::into)
}

/// The platform name used in fixture manifests.
pub fn platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unknown"
    }
}

/// Kernel version string of this host.
pub fn kernel_version() -> Result<String, CaptureError> {
    #[cfg(target_os = "macos")]
    {
        Ok(mac::sysctl_text("kern.osrelease").unwrap_or_else(|| "unknown".to_string()))
    }
    #[cfg(target_os = "linux")]
    {
        Ok(std::fs::read_to_string("/proc/sys/kernel/osrelease")?
            .trim()
            .to_string())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        Err(CaptureError::UnsupportedPlatform)
    }
}

/// Read every known input of this host.
pub fn collect() -> Result<Vec<CapturedInput>, CaptureError> {
    #[cfg(target_os = "macos")]
    {
        Ok(mac::collect())
    }
    #[cfg(target_os = "linux")]
    {
        Ok(linux::collect())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        Err(CaptureError::UnsupportedPlatform)
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use super::CapturedInput;
    use std::ffi::CString;

    /// How to interpret a sysctl value.
    #[derive(Debug, Clone, Copy)]
    enum Kind {
        /// NUL-terminated string.
        Text,
        /// Unsigned 64-bit integer (little-endian bytes from the kernel).
        Number,
        /// Opaque bytes, recorded verbatim.
        Raw,
    }

    /// The sysctls zTop reads, none of which identify the machine beyond its
    /// hardware class (model identifiers are not serial numbers).
    const KEYS: &[(&str, Kind)] = &[
        ("kern.ostype", Kind::Text),
        ("kern.osrelease", Kind::Text),
        ("kern.osproductversion", Kind::Text),
        ("kern.version", Kind::Text),
        ("kern.boottime", Kind::Raw),
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

    pub(super) fn collect() -> Vec<CapturedInput> {
        let mut inputs = Vec::new();
        for (key, kind) in KEYS {
            // Names in fixtures avoid dots: `kern.osrelease` -> `sysctl-kern_osrelease`.
            let name = format!("sysctl-{}", key.replace('.', "_"));
            let input = match kind {
                Kind::Text => sysctl_text(key).map(|t| CapturedInput::text(&name, t)),
                Kind::Number => sysctl_u64(key).map(|v| CapturedInput::text(&name, v.to_string())),
                Kind::Raw => sysctl_raw(key).map(|b| CapturedInput::bytes(&name, b)),
            };
            // A key the host does not have is simply not an input of this host.
            if let Some(input) = input {
                inputs.push(input);
            }
        }
        inputs
    }

    fn sysctl_raw(name: &str) -> Option<Vec<u8>> {
        let cname = CString::new(name).ok()?;
        // SAFETY: `sysctlbyname` only reads the NUL-terminated name and writes
        // into buffers we own. The size probe and the read are two calls; the
        // values here are stable kernel constants, so a size change between
        // calls is not a concern in practice, and we re-truncate to the
        // returned length afterwards.
        unsafe {
            let mut len: usize = 0;
            if libc::sysctlbyname(
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
            if libc::sysctlbyname(
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

    pub(super) fn sysctl_text(name: &str) -> Option<String> {
        let raw = sysctl_raw(name)?;
        let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
        Some(String::from_utf8_lossy(&raw[..end]).into_owned())
    }

    /// Parse a sysctl integer of 4 or 8 bytes (macOS uses native-endian
    /// little-endian integers of whatever width the key defines; `hw.ncpu`
    /// is 4 bytes, `hw.memsize` 8).
    pub(super) fn sysctl_u64(name: &str) -> Option<u64> {
        let raw = sysctl_raw(name)?;
        match raw.len() {
            4 => Some(u32::from_le_bytes(raw[..4].try_into().ok()?) as u64),
            8 => Some(u64::from_le_bytes(raw[..8].try_into().ok()?)),
            _ => None,
        }
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::CapturedInput;

    /// The proc files zTop reads. None contain hostnames or user data; they
    /// are the same files every process monitor reads.
    const PATHS: &[&str] = &[
        "/proc/stat",
        "/proc/meminfo",
        "/proc/loadavg",
        "/proc/uptime",
        "/proc/version",
        "/proc/swaps",
        "/proc/net/dev",
        "/proc/cpuinfo",
        "/proc/self/status",
        "/proc/mounts",
        "/proc/sys/kernel/osrelease",
    ];

    /// `/proc/stat` -> `proc-stat`, `/proc/sys/kernel/osrelease` ->
    /// `proc-sys-kernel-osrelease`: slashes become hyphens and dots (none
    /// occur in the recorded paths) become underscores.
    pub(super) fn entry_name(path: &str) -> String {
        path.trim_start_matches('/')
            .replace('/', "-")
            .replace('.', "_")
    }

    pub(super) fn collect() -> Vec<CapturedInput> {
        let mut inputs = Vec::new();
        for path in PATHS {
            let name = entry_name(path);
            if let Ok(text) = std::fs::read_to_string(path) {
                inputs.push(CapturedInput::text(name, text));
            }
        }
        inputs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn this_host_yields_entries_and_a_kernel_name() {
        let inputs = collect().expect("collect");
        assert!(
            !inputs.is_empty(),
            "every supported platform has at least one input"
        );
        let kernel = kernel_version().expect("kernel");
        assert!(!kernel.is_empty());
        assert!(matches!(platform_name(), "macos" | "linux"));
        // Names fit the fixture rules: no slashes, no dots beyond the
        // underscore mapping, no empty names.
        for input in &inputs {
            assert!(
                input
                    .name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.'),
                "entry name {:?} contains a forbidden byte",
                input.name
            );
        }
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn mac_sysctl_reads_strings_and_numbers() {
        assert_eq!(mac::sysctl_text("kern.ostype").as_deref(), Some("Darwin"));
        let ncpu = mac::sysctl_u64("hw.ncpu").expect("hw.ncpu");
        assert!(ncpu > 0);
        assert!(mac::sysctl_text("no.such.key.ztop").is_none());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn entry_names_map_slashes_and_dots() {
        assert_eq!(linux::entry_name("/proc/stat"), "proc-stat");
        assert_eq!(
            linux::entry_name("/proc/sys/kernel/osrelease"),
            "proc-sys-kernel-osrelease"
        );
    }
}
