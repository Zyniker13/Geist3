#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Runs exactly what CI runs, on this machine.
#
# The Swift and app steps are skipped on hosts without Xcode, which is how
# CI splits the work: the Linux job runs everything above the `if`, the
# macOS job runs all of it.
set -eu
cd "$(dirname "$0")/.."

cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo deny check licenses bans sources

if command -v xcodebuild >/dev/null 2>&1; then
    swift build --package-path swift/ZTopKit
    swift test --package-path swift/ZTopKit
    (cd app && xcodegen generate)
    xcodebuild -project app/ZTop.xcodeproj -scheme ZTop \
        -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
    xcodebuild -project app/ZTop.xcodeproj -scheme ZTop \
        -destination 'generic/platform=macOS' build CODE_SIGNING_ALLOWED=NO
fi
