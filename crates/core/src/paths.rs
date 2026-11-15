// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shared file locations: where ztop keeps its config and state.

use std::ffi::OsStr;
use std::path::PathBuf;

/// The directory for ztop's own files, or `None` without a home
/// directory.
pub fn state_dir() -> Option<PathBuf> {
    state_dir_with(
        std::env::var_os("HOME").as_deref(),
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
    )
}

/// The directory for ztop's own files, from explicit inputs so tests
/// stay hermetic (no environment mutation, which races between test
/// threads).
///
/// On macOS it is `~/Library/Application Support/ztop`; elsewhere
/// `$XDG_CONFIG_HOME/ztop` when `$XDG_CONFIG_HOME` is an absolute path
/// (per the XDG base directory spec) and `~/.config/ztop` otherwise.
pub fn state_dir_with(home: Option<&OsStr>, xdg: Option<&OsStr>) -> Option<PathBuf> {
    let home = home?;
    #[cfg(target_os = "macos")]
    {
        let _ = xdg;
        Some(PathBuf::from(home).join("Library/Application Support/ztop"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        match xdg {
            Some(base) if PathBuf::from(base).is_absolute() => {
                Some(PathBuf::from(base).join("ztop"))
            }
            _ => Some(PathBuf::from(home).join(".config/ztop")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn without_a_home_there_is_no_state_dir() {
        assert_eq!(state_dir_with(None, None), None);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn an_absolute_xdg_base_wins_and_a_relative_one_does_not() {
        let home = std::ffi::OsStr::new("/home-alice");
        assert_eq!(
            state_dir_with(Some(home), Some(std::ffi::OsStr::new("/tmp-alice/config"))),
            Some(PathBuf::from("/tmp-alice/config/ztop"))
        );
        assert_eq!(
            state_dir_with(
                Some(home),
                Some(std::ffi::OsStr::new("relative/not/absolute"))
            ),
            Some(PathBuf::from("/home-alice/.config/ztop"))
        );
    }
}
