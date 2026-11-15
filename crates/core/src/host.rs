// SPDX-License-Identifier: MIT OR Apache-2.0
//! This machine's name, for display and service advertisement.

/// The hostname, read the same way the collectors do: `kern.hostname`
/// on macOS, `/proc/sys/kernel/hostname` elsewhere. Never fails — an
/// unreadable name reads as `unknown`.
pub fn hostname() -> String {
    #[cfg(target_os = "macos")]
    {
        crate::capture_macos::sysctl_text("kern.hostname").unwrap_or_else(|| "unknown".to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::fs::read_to_string("/proc/sys/kernel/hostname")
            .map(|name| name.trim().to_string())
            .unwrap_or_else(|_| "unknown".to_string())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_hostname_is_non_empty() {
        // No assertion on the value itself: the fixture rules keep real
        // hostnames out of the repository, so only the shape is checked.
        assert!(!super::hostname().is_empty());
    }
}
