// SPDX-License-Identifier: MIT OR Apache-2.0
//! Live-host checks of the macOS collector, asserted universally so they
//! hold on any macOS machine: bounds every host satisfies, never values
//! specific to the machine that recorded them.
#[cfg(target_os = "macos")]
mod live {
    use ztop_core::collector::Collector;
    use ztop_core::macos_live::MacOsCollector;

    #[test]
    fn two_live_samples_stay_within_universal_bounds() {
        let mut collector = MacOsCollector::default();

        let first = collector.sample().expect("a live sample on macOS");
        assert!(first.timestamp_ms > 0);
        assert!(!first.hostname.is_empty(), "the hostname is readable");
        assert!(!first.cpu.cores.is_empty(), "a live host has CPU cores");
        assert!(
            first.cpu.busy_percent.iter().all(|rate| *rate == 0.0),
            "the first sample has no interval to rate over"
        );
        assert!(
            !first.processes.is_empty(),
            "a live host runs at least one process"
        );
        assert!(
            first
                .processes
                .iter()
                .all(|process| process.cpu_percent == 0.0),
            "the first sample has no interval to rate over"
        );
        assert!(
            first.memory.total.available && first.memory.total.value > 0.0,
            "total memory is readable without root"
        );
        assert!(
            first.uptime.available && first.uptime.value > 0.0,
            "the host booted before now"
        );

        let second = collector.sample().expect("a second live sample on macOS");
        assert_eq!(
            second.cpu.cores.len(),
            first.cpu.cores.len(),
            "the core count does not change between samples"
        );
        assert!(
            second
                .cpu
                .busy_percent
                .iter()
                .all(|rate| (0.0..=100.0).contains(rate)),
            "per-core rates stay within 0..=100 and are never NaN"
        );
        assert!(
            second
                .processes
                .iter()
                .all(|process| (0.0..=100.0).contains(&process.cpu_percent)),
            "per-process rates stay within 0..=100 and are never NaN"
        );
    }
}
