// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Fuzzing target for the `parse_chip_topology` function.
//
// This target fuzzes the parser for the chip topology data, which is
// a network-facing parser (the agent serves this data over the
// zTop protocol).

#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // The parser should never panic, even on malformed input.
    // Convert the fuzzed data to a string for the brand parameter.
    let brand = String::from_utf8_lossy(data);
    let brand = if brand.is_empty() {
        None
    } else {
        Some(brand.as_ref())
    };
    // Create a dummy levels vector.
    let levels = vec![("L1", 1), ("L2", 2), ("L3", 3)];
    let _ = ztop_core::macos::parse_chip_topology(brand, &levels);
});
