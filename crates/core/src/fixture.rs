// SPDX-License-Identifier: MIT OR Apache-2.0
//! The fixture format: a manifest plus the raw inputs a host exposes.
//!
//! A fixture directory contains `manifest.json` and one file per entry under
//! `data/`. Entries are recorded verbatim — text sources as text, binary
//! sources as bytes — so collectors can be developed against recorded hosts
//! and their tests never depend on the machine that runs them.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Format version of the manifest; bumped only by a recorded decision.
pub const FORMAT_VERSION: u32 = 1;

/// Which kind of payload an entry carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FixtureKind {
    Text,
    Bytes,
}

/// One recorded input inside a fixture directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FixtureEntry {
    /// Stable short name, e.g. `proc_stat` or `sysctl-hw_memsize`.
    pub name: String,
    /// Path inside the fixture directory; always `data/<name>`.
    pub path: String,
    pub kind: FixtureKind,
}

/// Describes a fixture directory; `manifest.json` holds exactly this.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FixtureManifest {
    pub format: u32,
    /// `macos` or `linux`.
    pub platform: String,
    /// Machine architecture the inputs came from.
    pub arch: String,
    /// Kernel version string of the recording host.
    pub kernel: String,
    /// Unix seconds when the capture was taken.
    pub captured_at_unix: u64,
    /// Which tool recorded it, e.g. `ztop 0.1.0`.
    pub source: String,
    pub entries: Vec<FixtureEntry>,
}

/// Fixture errors.
#[derive(Debug, thiserror::Error)]
pub enum FixtureError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("manifest json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("fixture format {found} is not supported (this build reads {expected})")]
    UnsupportedFormat { found: u32, expected: u32 },
    #[error("bad fixture entry {name:?}: {why}")]
    BadEntry { name: String, why: &'static str },
    #[error("entry {name:?} is not valid utf-8")]
    Utf8 { name: String },
}

/// A payload as it was recorded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FixtureData {
    Text(String),
    Bytes(Vec<u8>),
}

/// One raw input captured from a host, before any collector interprets it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedInput {
    pub name: String,
    pub data: FixtureData,
}

impl CapturedInput {
    /// A text input, e.g. the contents of `/proc/meminfo`.
    pub fn text(name: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            data: FixtureData::Text(text.into()),
        }
    }

    /// A binary input, e.g. the raw bytes of a sysctl structure.
    pub fn bytes(name: impl Into<String>, bytes: Vec<u8>) -> Self {
        Self {
            name: name.into(),
            data: FixtureData::Bytes(bytes),
        }
    }
}

/// An open, validated fixture directory.
#[derive(Debug, Clone)]
pub struct Fixture {
    dir: PathBuf,
    manifest: FixtureManifest,
}

impl Fixture {
    /// Open and validate the fixture rooted at `dir`.
    pub fn open(dir: impl Into<PathBuf>) -> Result<Self, FixtureError> {
        let dir = dir.into();
        let manifest: FixtureManifest =
            serde_json::from_reader(fs::File::open(dir.join("manifest.json"))?)?;
        if manifest.format != FORMAT_VERSION {
            return Err(FixtureError::UnsupportedFormat {
                found: manifest.format,
                expected: FORMAT_VERSION,
            });
        }
        for entry in &manifest.entries {
            validate_name(&entry.name)?;
            let expected_path = format!("data/{}", entry.name);
            if entry.path != expected_path {
                return Err(FixtureError::BadEntry {
                    name: entry.name.clone(),
                    why: "path must be data/<name>",
                });
            }
        }
        Ok(Self { dir, manifest })
    }

    /// The validated manifest.
    pub fn manifest(&self) -> &FixtureManifest {
        &self.manifest
    }

    /// Names of all entries, in manifest order.
    pub fn entry_names(&self) -> impl Iterator<Item = &str> {
        self.manifest.entries.iter().map(|e| e.name.as_str())
    }

    /// Raw bytes of one entry.
    pub fn entry_bytes(&self, name: &str) -> Result<Vec<u8>, FixtureError> {
        let entry = self.lookup(name)?;
        fs::read(self.dir.join(&entry.path)).map_err(Into::into)
    }

    /// Text of one entry.
    pub fn entry_text(&self, name: &str) -> Result<String, FixtureError> {
        let entry = self.lookup(name)?;
        if entry.kind != FixtureKind::Text {
            return Err(FixtureError::BadEntry {
                name: name.to_string(),
                why: "entry is not text",
            });
        }
        let bytes = fs::read(self.dir.join(&entry.path))?;
        String::from_utf8(bytes).map_err(|_| FixtureError::Utf8 {
            name: name.to_string(),
        })
    }

    fn lookup(&self, name: &str) -> Result<&FixtureEntry, FixtureError> {
        self.manifest
            .entries
            .iter()
            .find(|e| e.name == name)
            .ok_or_else(|| FixtureError::BadEntry {
                name: name.to_string(),
                why: "not in manifest",
            })
    }
}

/// Write a fixture directory from captured inputs; returns the entry count.
pub fn write_fixture(
    dir: &Path,
    platform: &str,
    kernel: &str,
    inputs: &[CapturedInput],
) -> Result<usize, FixtureError> {
    fs::create_dir_all(dir.join("data"))?;
    let mut entries = Vec::with_capacity(inputs.len());
    for input in inputs {
        validate_name(&input.name)?;
        let path = format!("data/{}", input.name);
        let kind = match &input.data {
            FixtureData::Text(text) => {
                fs::write(dir.join(&path), text)?;
                FixtureKind::Text
            }
            FixtureData::Bytes(bytes) => {
                fs::write(dir.join(&path), bytes)?;
                FixtureKind::Bytes
            }
        };
        entries.push(FixtureEntry {
            name: input.name.clone(),
            path,
            kind,
        });
    }
    let manifest = FixtureManifest {
        format: FORMAT_VERSION,
        platform: platform.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        kernel: kernel.to_string(),
        captured_at_unix: unix_now(),
        source: format!("ztop {}", env!("CARGO_PKG_VERSION")),
        entries,
    };
    serde_json::to_writer_pretty(fs::File::create(dir.join("manifest.json"))?, &manifest)?;
    Ok(inputs.len())
}

/// Entry names are path components under `data/`; keep them boring and safe.
fn validate_name(name: &str) -> Result<(), FixtureError> {
    let ok = !name.is_empty()
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-');
    if ok {
        Ok(())
    } else {
        Err(FixtureError::BadEntry {
            name: name.to_string(),
            why: "names use [A-Za-z0-9._-] and may not start with a dot",
        })
    }
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ztop-fixture-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn write_then_open_roundtrips_text_and_bytes() {
        let dir = tempdir("roundtrip");
        let inputs = [
            CapturedInput::text("proc_meminfo", "MemTotal: 1000 kB\n"),
            CapturedInput::bytes(
                "sysctl-kern_boottime",
                vec![0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
            ),
        ];
        let count = write_fixture(&dir, "linux", "6.1.0-test", &inputs).expect("write");
        assert_eq!(count, 2);

        let fixture = Fixture::open(&dir).expect("open");
        assert_eq!(fixture.manifest().platform, "linux");
        assert_eq!(fixture.manifest().kernel, "6.1.0-test");
        assert_eq!(
            fixture.entry_names().collect::<Vec<_>>(),
            vec!["proc_meminfo", "sysctl-kern_boottime"]
        );
        assert_eq!(
            fixture.entry_text("proc_meminfo").unwrap(),
            "MemTotal: 1000 kB\n"
        );
        assert_eq!(
            fixture.entry_bytes("sysctl-kern_boottime").unwrap(),
            (0..16).collect::<Vec<u8>>()
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn open_rejects_an_unknown_format() {
        let dir = tempdir("format");
        fs::create_dir_all(dir.join("data")).unwrap();
        let manifest = r#"{"format": 2, "platform": "linux", "arch": "x86_64", "kernel": "k", "captured_at_unix": 0, "source": "s", "entries": []}"#;
        fs::write(dir.join("manifest.json"), manifest).unwrap();
        let err = Fixture::open(&dir).expect_err("must reject");
        assert!(matches!(
            err,
            FixtureError::UnsupportedFormat {
                found: 2,
                expected: FORMAT_VERSION
            }
        ));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn open_rejects_paths_that_escape_data() {
        let dir = tempdir("escape");
        fs::create_dir_all(dir.join("data")).unwrap();
        let manifest = r#"{"format": 1, "platform": "linux", "arch": "x86_64", "kernel": "k", "captured_at_unix": 0, "source": "s", "entries": [{"name": "x", "path": "../escape", "kind": "text"}]}"#;
        fs::write(dir.join("manifest.json"), manifest).unwrap();
        let err = Fixture::open(&dir).expect_err("must reject");
        assert!(matches!(err, FixtureError::BadEntry { .. }));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn entry_names_are_restricted() {
        for bad in ["", ".hidden", "a/b", "a b", ".."] {
            assert!(validate_name(bad).is_err(), "{bad:?} must be rejected");
        }
        for good in ["proc_stat", "sysctl-hw_memsize", "a.b-c_d0"] {
            assert!(validate_name(good).is_ok(), "{good:?} must be accepted");
        }
    }

    #[test]
    fn reading_text_from_a_bytes_entry_is_an_error() {
        let dir = tempdir("kinds");
        let inputs = [CapturedInput::bytes("blob", vec![0xff, 0xfe])];
        write_fixture(&dir, "linux", "k", &inputs).unwrap();
        let fixture = Fixture::open(&dir).unwrap();
        let err = fixture.entry_text("blob").expect_err("must reject");
        assert!(matches!(err, FixtureError::BadEntry { .. }));
        fs::remove_dir_all(&dir).unwrap();
    }
}
