// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_processes` function.
//
// This target fuzzes the parser for the `ps` command output, which is
// a network-facing parser (the agent serves this data over the
// zTop protocol).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // The parser should never panic, even on malformed input.
    let _ = ztop_core::macos::parse_processes(data);
});
