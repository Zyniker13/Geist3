// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_pin` function.
//
// This target fuzzes the parser for the certificate pin, which is
// a network-facing parser (the client uses this to pin the agent's
// certificate).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // The parser should never panic, even on malformed input.
    let _ = ztop_core::client::parse_pin(data);
});
