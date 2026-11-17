// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_pid_status` function.
//
// This target fuzzes the parser for the `/proc/[pid]/status` file, which is
// a network-facing parser (the agent serves this data over the
// zTop protocol).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // The parser should never panic, even on malformed input.
    let _ = ztop_core::linux::parse_pid_status(data);
});
