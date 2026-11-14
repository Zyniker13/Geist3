// SPDX-License-Identifier: MIT OR Apache-2.0
//! Live-host checks of the macOS collector, asserted universally so they
//! hold on any macOS machine: bounds every host satisfies, never values
//! specific to the machine that recorded them.
//!
//! Sensors are the one exception to "bounds only": when this machine has
//! an SMC device — probed through IOKit directly, independent of collector
//! code so a collector regression cannot hide behind an absent device —
//! the collector must actually read temperatures, fans and system power
//! from it. A machine without an SMC (a VM) must get empty lists, never
//! faked values (decision 0009).
#[cfg(target_os = "macos")]
mod live {
    use ztop_core::collector::Collector;
    use ztop_core::macos_live::MacOsCollector;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceMatching(name: *const std::ffi::c_char) -> *mut std::ffi::c_void;
        fn IOServiceGetMatchingService(main_port: u32, matching: *mut std::ffi::c_void) -> u32;
        fn IOObjectRelease(object: u32) -> i32;
    }

    /// True when this machine exposes an Apple SMC at all.
    fn smc_device_present() -> bool {
        unsafe {
            let matching = IOServiceMatching(c"AppleSMC".as_ptr());
            if matching.is_null() {
                return false;
            }
            // The call consumes the matching dictionary.
            let service = IOServiceGetMatchingService(0, matching);
            if service == 0 {
                return false;
            }
            IOObjectRelease(service);
            true
        }
    }

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

        let sensors = &second.sensors;
        if smc_device_present() {
            assert!(
                !sensors.temps.is_empty(),
                "an SMC device is present but no temperatures were read"
            );
            assert!(
                !sensors.fans.is_empty(),
                "an SMC device is present but no fan speeds were read"
            );
            for temp in &sensors.temps {
                assert!(
                    temp.celsius.available && (0.0..=150.0).contains(&temp.celsius.value),
                    "temperatures stay within 0..=150 degrees C: {temp:?}"
                );
            }
            for fan in &sensors.fans {
                assert!(
                    fan.rpm.available && (0.0..=20_000.0).contains(&fan.rpm.value),
                    "fan speeds stay within 0..=20000 rpm: {fan:?}"
                );
            }
            assert!(
                sensors.system_watts.available
                    && (0.0..=500.0).contains(&sensors.system_watts.value),
                "system power stays within 0..=500 W: {:?}",
                sensors.system_watts
            );
        } else {
            assert!(
                sensors.temps.is_empty() && sensors.fans.is_empty(),
                "without an SMC device no temperatures or fans are faked"
            );
            assert!(
                !sensors.system_watts.available,
                "without an SMC device system power is not faked"
            );
        }
        if sensors.gpu_watts.available {
            assert!(
                (0.0..=500.0).contains(&sensors.gpu_watts.value),
                "GPU power stays within 0..=500 W: {:?}",
                sensors.gpu_watts
            );
        }
    }
}
