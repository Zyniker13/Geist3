// SPDX-License-Identifier: MIT OR Apache-2.0
//! Link the macOS frameworks the live collector's FFI needs.
//!
//! Only emitted on macOS targets: `-framework` flags are invalid on Linux,
//! and the IOReport symbols come from `libIOReport.dylib` (a plain `-l`
//! link against the SDK's stub, resolved from the dyld shared cache at
//! runtime), not from a bundle-style framework.

fn main() {
    // Build scripts run on the host: cfg! would describe the host, not the
    // target, so cross-compiles from a Mac would emit -framework for a Linux
    // target. CARGO_CFG_TARGET_OS is cargo's target view.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
    // IOReport ships as a flat dylib stub (libIOReport.tbd in the SDK),
    // not a framework bundle; see docs/decisions/0011-macos-power-freq-smc.md.
    println!("cargo:rustc-link-lib=IOReport");
}
