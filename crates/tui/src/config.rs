// SPDX-License-Identifier: MIT OR Apache-2.0
//! The user's saved setup: theme and display options, loaded when `ztop`
//! starts and saved when the setup screen (F2) closes.

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Which colors the UI paints with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum Theme {
    /// Bars and highlights in color (the default).
    #[default]
    #[serde(rename = "color")]
    Color,
    /// Plain text, no colors (`--no-color` forces this for one run).
    #[serde(rename = "mono")]
    Mono,
}

/// The saved setup, kept as JSON in the user's config directory.
///
/// Fields default on load, so a config file written by an older version
/// that lacked one still loads.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub theme: Theme,
    /// Open the process table in tree view.
    #[serde(default)]
    pub start_in_tree: bool,
    /// How the header meters draw their fill.
    #[serde(default)]
    pub meter_style: MeterStyle,
}

/// How the header meters draw their fill.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum MeterStyle {
    /// Solid fill: the current rendering (█ over the background).
    #[default]
    #[serde(rename = "bar")]
    Bar,
    /// Numbers only, no fill.
    #[serde(rename = "text")]
    Text,
    /// A history sparkline of recent samples, newest on the right.
    #[serde(rename = "graph")]
    Graph,
    /// An LED strip: `|` where the value has reached, `·` behind it.
    #[serde(rename = "led")]
    Led,
}

impl MeterStyle {
    /// The value shown on the setup screen and in tests.
    pub fn name(self) -> &'static str {
        match self {
            Self::Bar => "bar",
            Self::Text => "text",
            Self::Graph => "graph",
            Self::Led => "led",
        }
    }

    /// The next style in the setup screen's cycle.
    pub fn next(self) -> Self {
        match self {
            Self::Bar => Self::Text,
            Self::Text => Self::Graph,
            Self::Graph => Self::Led,
            Self::Led => Self::Bar,
        }
    }
}

impl Config {
    /// Load the saved setup; a missing or malformed file means defaults.
    ///
    /// A config the user cannot parse must never stop the monitor from
    /// starting; the bad file is left in place for them to fix or delete.
    pub fn load() -> Self {
        match config_path() {
            Some(path) => Self::load_from(&path),
            None => Self::default(),
        }
    }

    /// Load from an explicit path (also the seam tests use).
    pub fn load_from(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    /// Save the setup, creating the config directory if needed. Returns
    /// the file that was written, for the status line.
    pub fn save(&self) -> io::Result<PathBuf> {
        let path = config_path().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "no home directory for the config")
        })?;
        self.save_to(&path)?;
        Ok(path)
    }

    /// Save to an explicit path (also the seam tests use).
    pub fn save_to(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(self).expect("config serializes");
        std::fs::write(path, text)
    }
}

/// The config file's path, or `None` without a home directory.
#[cfg(target_os = "macos")]
pub fn config_path() -> Option<PathBuf> {
    home().map(|home| home.join("Library/Application Support/ztop/config.json"))
}

/// The config file's path, or `None` without a home directory.
///
/// `$XDG_CONFIG_HOME` is honored when it is an absolute path, per the
/// XDG base directory spec; otherwise the default is `~/.config`.
#[cfg(not(target_os = "macos"))]
pub fn config_path() -> Option<PathBuf> {
    if let Some(base) = std::env::var_os("XDG_CONFIG_HOME") {
        let base = PathBuf::from(base);
        if base.is_absolute() {
            return Some(base.join("ztop/config.json"));
        }
    }
    home().map(|home| home.join(".config/ztop/config.json"))
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// The path with the home directory abbreviated to `~`, for showing people:
/// status lines and screens stay free of the machine's real paths.
pub fn display_path(path: &Path) -> String {
    match home() {
        Some(home) if path.starts_with(&home) => {
            let rest = path.strip_prefix(&home).unwrap_or(path);
            // The stripped remainder is relative (`Library/...`), so the
            // separator after `~` has to be put back explicitly.
            format!("~/{}", rest.display())
        }
        _ => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scratch path unique to one test.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ztop-config-{name}"));
        std::fs::remove_dir_all(&dir).ok();
        dir.join("config.json")
    }

    #[test]
    fn config_roundtrips_through_a_file() {
        let path = scratch("roundtrip");
        let config = Config {
            theme: Theme::Mono,
            start_in_tree: true,
            meter_style: MeterStyle::Led,
        };
        config.save_to(&path).expect("saves");
        assert_eq!(Config::load_from(&path), config);
    }

    #[test]
    fn a_missing_config_file_means_defaults() {
        let path = scratch("missing").with_file_name("never-created.json");
        assert_eq!(Config::load_from(&path), Config::default());
    }

    #[test]
    fn a_malformed_config_file_means_defaults() {
        let path = scratch("malformed");
        std::fs::create_dir_all(path.parent().unwrap()).expect("dir");
        std::fs::write(&path, "not json at all").expect("writes");
        assert_eq!(Config::load_from(&path), Config::default());
    }

    #[test]
    fn unknown_fields_and_missing_fields_are_tolerated() {
        let path = scratch("fields");
        std::fs::create_dir_all(path.parent().unwrap()).expect("dir");
        // Written by a future version with an extra field; the theme
        // survives and the missing field defaults.
        std::fs::write(&path, r#"{"theme":"mono","future_option":3}"#).expect("writes");
        let config = Config::load_from(&path);
        assert_eq!(config.theme, Theme::Mono);
        assert!(!config.start_in_tree);
    }

    #[test]
    fn display_path_abbreviates_the_home_directory() {
        // A path under the home directory keeps only `~` plus its tail;
        // anything else passes through untouched.
        if let Some(home) = home() {
            let path = home.join("Library/ztop/config.json");
            assert_eq!(display_path(&path), "~/Library/ztop/config.json");
        }
        let path = PathBuf::from("/tmp/other/ztop/config.json");
        assert_eq!(display_path(&path), "/tmp/other/ztop/config.json");
    }
}
