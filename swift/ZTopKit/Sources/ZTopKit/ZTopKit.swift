// SPDX-License-Identifier: MIT OR Apache-2.0

/// The kit's protocol and package version, matching the Rust crates.
///
/// Named `ZTopKitVersion` rather than `ZTopKit` so the module name
/// stays usable for qualified lookups (`ZTopKit.Process`): a type
/// named like its module shadows the module in Swift and would make
/// every Foundation-`Process` collision worse.
public enum ZTopKitVersion {
    /// The protocol and package version, matching the Rust crates.
    public static let version = "0.1.0"
}
