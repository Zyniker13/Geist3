// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_iflist2` function.
//
// This target fuzzes the parser for the `NET_RT_IFLIST2` sysctl data, which is
// a network-facing parser (the agent serves this data over the
// zTop protocol).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // The parser should never panic, even on malformed input.
    let _ = ztop_core::macos_io::parse_iflist2(data, |_| None);
});
