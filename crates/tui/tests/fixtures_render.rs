// SPDX-License-Identifier: MIT OR Apache-2.0
//! The recorded fixtures render end to end through the TUI draw path.
//!
//! These tests run on every OS: fixture replay never touches the live
//! host, so the Linux captures render identically on macOS, in CI and in
//! the local gate.

use std::path::{Path, PathBuf};

use ztop_core::linux::sample_from_fixture;
use ztop_tui::{Ui, draw_lines};

const ARCHES: [&str; 2] = ["linux-x86_64", "linux-aarch64"];

/// The committed fixture directories, one per recorded architecture.
fn fixture_dir(arch: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(arch)
}

#[test]
fn renders_both_recorded_fixtures_at_80x24() {
    for arch in ARCHES {
        let dir = fixture_dir(arch);
        let sample =
            sample_from_fixture(&dir).unwrap_or_else(|err| panic!("{arch} should parse: {err}"));
        let procs = sample.processes.len();
        assert!(procs > 0, "{arch} has no processes");
        assert_eq!(
            sample.cpu.busy_percent.len(),
            sample.cpu.cores.len(),
            "{arch} busy_percent must cover every core"
        );

        let ui = Ui {
            sample: Some(sample),
            ..Ui::new()
        };
        let lines = draw_lines(&ui, 80, 24);
        assert_eq!(lines.len(), 24, "{arch} frame height");

        // The header names the fixture's hostname and process count.
        let title = &lines[0];
        assert!(
            title.contains(arch) && title.contains(&format!("{procs} procs")),
            "{arch} header incomplete: {title:?}"
        );
        // Every recorded process appears in the table (rows 5..=22 hold
        // processes at 80x24, so up to 18 fit).
        assert!(procs <= 18, "{arch} process count exceeds the frame");
        let table = lines.join("\n");
        for name in proc_names(&dir) {
            assert!(
                table.contains(&name),
                "{arch} frame is missing process {name:?}"
            );
        }
    }
}

/// The scrubbed process names of a fixture, read from its `comm` entries.
fn proc_names(dir: &Path) -> Vec<String> {
    let data = dir.join("data");
    let mut names = std::fs::read_dir(&data)
        .expect("fixture data dir")
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| name.starts_with("proc-") && name.ends_with("-comm"))
        .map(|name| {
            let text = std::fs::read_to_string(data.join(&name)).expect("comm text");
            text.trim().to_string()
        })
        .collect::<Vec<_>>();
    names.sort();
    names.dedup();
    names
}
