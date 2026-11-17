// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_control_reply` function.
//
// This target fuzzes the parser for the control reply, which is
// a network-facing parser (the client uses this to parse the agent's
// response to control commands).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // The parser should never panic, even on malformed input.
    let pids = vec![1u32, 2, 3];
    let _ = ztop_core::client::parse_control_reply(data, &pids);
});
