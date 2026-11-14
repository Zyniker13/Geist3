// SPDX-License-Identifier: MIT OR Apache-2.0
//! `ztop capture`: record this host's raw inputs as a fixture.
//!
//! The recorded inputs are exactly what the platform collectors read, saved
//! before any interpretation, so a fixture recorded on one machine drives the
//! collectors' tests on any machine. Recorded keys are an allowlist that
//! excludes anything host-identifying (serial numbers, UUIDs, hostnames).
//! Linux recording also expands glob patterns — per-process files, hardware
//! monitors, power supplies — so one capture covers every collector input.

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

/// Minimal glob matching for capture patterns.
///
/// Patterns are absolute paths whose components may use `*` (any run of
/// characters within one component), `?` (one character), and `[0-9]`-style
/// character classes with ranges. A component never matches across `/`.
#[cfg(any(target_os = "linux", test))]
mod glob {
    /// Match one pattern component against one path component.
    pub(super) fn component_matches(pattern: &str, text: &str) -> bool {
        matches_bytes(pattern.as_bytes(), text.as_bytes())
    }

    fn matches_bytes(pattern: &[u8], text: &[u8]) -> bool {
        if pattern.is_empty() {
            return text.is_empty();
        }
        match pattern[0] {
            b'*' => (0..=text.len()).any(|skip| matches_bytes(&pattern[1..], &text[skip..])),
            b'?' => !text.is_empty() && matches_bytes(&pattern[1..], &text[1..]),
            b'[' => match class_and_rest(pattern) {
                Some((class, rest)) => {
                    !text.is_empty()
                        && class_char_matches(class, text[0])
                        && matches_bytes(rest, &text[1..])
                }
                // No closing bracket: treat `[` as a literal character.
                None => {
                    !text.is_empty() && text[0] == b'[' && matches_bytes(&pattern[1..], &text[1..])
                }
            },
            first => {
                !text.is_empty() && text[0] == first && matches_bytes(&pattern[1..], &text[1..])
            }
        }
    }

    /// Split a leading `[...]` class from the rest of the pattern.
    fn class_and_rest(pattern: &[u8]) -> Option<(&[u8], &[u8])> {
        let close = pattern.iter().position(|&b| b == b']')?;
        Some((&pattern[1..close], &pattern[close + 1..]))
    }

    /// Does one character fall inside a `[...]` class body?
    fn class_char_matches(class: &[u8], c: u8) -> bool {
        let mut i = 0;
        while i < class.len() {
            if i + 2 < class.len() && class[i + 1] == b'-' {
                if class[i] <= c && c <= class[i + 2] {
                    return true;
                }
                i += 3;
            } else {
                if class[i] == c {
                    return true;
                }
                i += 1;
            }
        }
        false
    }

    /// Match a whole absolute path against a whole pattern (test helper).
    #[cfg(test)]
    pub(super) fn path_matches(pattern: &str, path: &str) -> bool {
        let pattern_parts: Vec<&str> = pattern.split('/').filter(|p| !p.is_empty()).collect();
        let path_parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        pattern_parts.len() == path_parts.len()
            && pattern_parts
                .iter()
                .zip(&path_parts)
                .all(|(p, t)| component_matches(p, t))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn literals_match_only_themselves() {
            assert!(path_matches("/proc/stat", "/proc/stat"));
            assert!(!path_matches("/proc/stat", "/proc/2/stat"));
            assert!(!path_matches("/proc/stat", "/proc/status"));
        }

        #[test]
        fn digit_classes_match_pids() {
            assert!(path_matches("/proc/[0-9]*/stat", "/proc/2/stat"));
            assert!(path_matches("/proc/[0-9]*/stat", "/proc/12345/stat"));
            assert!(!path_matches("/proc/[0-9]*/stat", "/proc/self/stat"));
            assert!(!path_matches("/proc/[0-9]*/stat", "/proc/stat"));
        }

        #[test]
        fn stars_match_within_components() {
            assert!(path_matches(
                "/sys/class/hwmon/*/temp*_input",
                "/sys/class/hwmon/hwmon0/temp1_input"
            ));
            assert!(path_matches(
                "/sys/class/hwmon/*/temp*_input",
                "/sys/class/hwmon/hwmon1/temp12_input"
            ));
            assert!(!path_matches(
                "/sys/class/hwmon/*/temp*_input",
                "/sys/class/hwmon/hwmon1/fan1_input"
            ));
            assert!(path_matches(
                "/sys/class/power_supply/*/capacity",
                "/sys/class/power_supply/BAT0/capacity"
            ));
        }

        #[test]
        fn question_marks_match_one_character() {
            assert!(path_matches("/proc/?.", "/proc/x."));
            assert!(!path_matches("/proc/?", "/proc/xy"));
        }

        #[test]
        fn component_counts_must_agree() {
            assert!(!path_matches("/proc/[0-9]*/stat", "/proc/2/stat/extra"));
            assert!(!path_matches("/proc/[0-9]*/stat/extra", "/proc/2/stat"));
        }
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use super::CapturedInput;
    use crate::capture_macos::collect_inputs;
    pub(super) use crate::capture_macos::sysctl_text;

    pub(super) fn collect() -> Vec<CapturedInput> {
        collect_inputs()
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::CapturedInput;
    use std::path::PathBuf;

    /// One thing to record: a single fixed file, or a glob of files.
    enum Source {
        /// One fixed path.
        File(&'static str),
        /// A glob pattern expanded over the live filesystem.
        Glob(&'static str),
    }

    /// What a Linux host records: the fixed `/proc` files, the per-process
    /// files, hardware-monitor chips and power supplies. The fixed paths hold
    /// no hostnames or user data; the per-process files do, and committed
    /// fixtures scrub them (decision 0007).
    const SOURCES: &[Source] = &[
        Source::File("/proc/stat"),
        Source::File("/proc/meminfo"),
        Source::File("/proc/loadavg"),
        Source::File("/proc/uptime"),
        Source::File("/proc/version"),
        Source::File("/proc/swaps"),
        Source::File("/proc/net/dev"),
        Source::File("/proc/cpuinfo"),
        Source::File("/proc/self/status"),
        Source::File("/proc/mounts"),
        Source::File("/proc/sys/kernel/osrelease"),
        Source::File("/proc/diskstats"),
        Source::Glob("/proc/[0-9]*/stat"),
        Source::Glob("/proc/[0-9]*/status"),
        Source::Glob("/proc/[0-9]*/cmdline"),
        Source::Glob("/proc/[0-9]*/comm"),
        Source::Glob("/sys/class/hwmon/*/name"),
        Source::Glob("/sys/class/hwmon/*/temp*_input"),
        Source::Glob("/sys/class/hwmon/*/temp*_label"),
        Source::Glob("/sys/class/hwmon/*/fan*_input"),
        Source::Glob("/sys/class/hwmon/*/fan*_label"),
        Source::Glob("/sys/class/power_supply/*/type"),
        Source::Glob("/sys/class/power_supply/*/capacity"),
        Source::Glob("/sys/class/power_supply/*/status"),
        Source::Glob("/sys/class/power_supply/*/energy_now"),
        Source::Glob("/sys/class/power_supply/*/energy_full"),
        Source::Glob("/sys/class/power_supply/*/power_now"),
        Source::Glob("/sys/class/power_supply/*/voltage_now"),
        Source::Glob("/sys/class/power_supply/*/current_now"),
    ];

    /// `/proc/stat` -> `proc-stat`, `/proc/sys/kernel/osrelease` ->
    /// `proc-sys-kernel-osrelease`: slashes become hyphens and dots (none
    /// occur in the recorded paths) become underscores.
    pub(super) fn entry_name(path: &str) -> String {
        path.trim_start_matches('/')
            .replace('/', "-")
            .replace('.', "_")
    }

    /// Expand one glob pattern against the live filesystem, component by
    /// component. Entries that vanish mid-walk are simply skipped.
    fn expand(pattern: &str) -> Vec<String> {
        let components: Vec<&str> = pattern.split('/').filter(|c| !c.is_empty()).collect();
        let mut current: Vec<PathBuf> = vec![PathBuf::from("/")];
        for component in &components {
            let mut next = Vec::new();
            for dir in &current {
                let Ok(entries) = std::fs::read_dir(dir) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let file_name = entry.file_name();
                    let Some(name) = file_name.to_str() else {
                        continue;
                    };
                    if super::glob::component_matches(component, name) {
                        next.push(entry.path());
                    }
                }
            }
            current = next;
        }
        current
            .into_iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect()
    }

    pub(super) fn collect() -> Vec<CapturedInput> {
        let mut inputs = Vec::new();
        for source in SOURCES {
            match source {
                Source::File(path) => {
                    if let Ok(text) = std::fs::read_to_string(path) {
                        inputs.push(CapturedInput::text(entry_name(path), text));
                    }
                }
                Source::Glob(pattern) => {
                    for path in expand(pattern) {
                        if let Ok(text) = std::fs::read_to_string(&path) {
                            inputs.push(CapturedInput::text(entry_name(&path), text));
                        }
                    }
                }
            }
        }
        // Deterministic order: the same host state yields the same fixture.
        inputs.sort_by(|a, b| a.name.cmp(&b.name));
        inputs.dedup_by(|a, b| a.name == b.name);
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
        use crate::capture_macos::sysctl_u64;
        assert_eq!(mac::sysctl_text("kern.ostype").as_deref(), Some("Darwin"));
        let ncpu = sysctl_u64("hw.ncpu").expect("hw.ncpu");
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

    #[test]
    #[cfg(target_os = "linux")]
    fn linux_collect_is_deterministic_and_unique() {
        let inputs = linux::collect();
        let names: Vec<&str> = inputs.iter().map(|i| i.name.as_str()).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        assert_eq!(
            names, sorted,
            "entries must be recorded in a deterministic order"
        );
        let unique: std::collections::BTreeSet<&str> = names.iter().copied().collect();
        assert_eq!(unique.len(), names.len(), "entry names must be unique");
    }
}
