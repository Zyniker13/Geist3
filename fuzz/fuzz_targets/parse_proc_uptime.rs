// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_proc_uptime` function.
//
// This target fuzzes the parser for the `/proc/uptime` file, which is
// a network-facing parser (the agent serves this data over the
// zTop protocol).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // The parser should never panic, even on malformed input.
    let _ = ztop_core::linux::parse_proc_uptime(data);
});
