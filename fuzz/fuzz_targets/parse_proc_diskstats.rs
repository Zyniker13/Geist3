// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_proc_diskstats` function.
//
// This target fuzzes the parser for the `/proc/diskstats` file, which is
// a network-facing parser (the agent serves this data over the
// zTop protocol).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // The parser should never panic, even on malformed input. The
    // mount table is the collector's second input; an empty one means
    // every disk keeps its device name.
    let mounts = std::collections::HashMap::new();
    let _ = ztop_core::linux::parse_proc_diskstats(data, &mounts);
});
