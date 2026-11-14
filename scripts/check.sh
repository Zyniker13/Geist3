#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Runs exactly what CI runs, on this machine.
#
# The Swift and app steps are skipped on hosts without Xcode, which is how
# CI splits the work: the Linux job runs everything above the `if`, the
# macOS job runs all of it.
#
# Each stage's output is captured; on failure the tail is echoed and also
# emitted as GitHub `::error` annotations, which stay readable on public
# repos without authentication, unlike job logs.
set -eu
cd "$(dirname "$0")/.."

run() {
    stage="$1"
    shift
    log="${TMPDIR:-/tmp}/ztop-check-$stage.log"
    if "$@" >"$log" 2>&1; then
        echo "check: $stage ok"
    else
        code=$?
        echo "check: $stage FAILED (exit $code); last lines:"
        tail -n 30 "$log"
        # Annotations: one per line of the tail, CR-stripped and %-escaped.
        tail -n 12 "$log" | tr -d '\r' | sed 's/%/%25/g' | while IFS= read -r line; do
            printf '::error title=check.sh %s failed::%s\n' "$stage" "$line"
        done
        exit "$code"
    fi
}

run fmt cargo fmt --all -- --check
run clippy cargo clippy --workspace --all-targets -- -D warnings
run test cargo test --workspace
run smoke sh -c '
    set -e
    # Replay both committed fixtures through the production draw path.
    for arch in linux-x86_64 linux-aarch64; do
        frame=$(cargo run -q -p ztop -- replay "tests/fixtures/$arch")
        echo "$frame" | grep -q "$arch" || { echo "header missing $arch"; exit 1; }
        echo "$frame" | grep -Eq "[0-9]+ procs" || { echo "process count missing"; exit 1; }
        echo "$frame" | grep -q "proc-" || { echo "no process rows"; exit 1; }
        echo "$frame" | head -1
    done
'
run deny cargo deny check licenses bans sources

if command -v xcodebuild >/dev/null 2>&1; then
    run swift-build swift build --package-path swift/ZTopKit
    run swift-test swift test --package-path swift/ZTopKit
    run xcodegen sh -c 'cd app && xcodegen generate'
    run xcodebuild-ios xcodebuild -project app/ZTop.xcodeproj -scheme ZTop \
        -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
    run xcodebuild-mac xcodebuild -project app/ZTop.xcodeproj -scheme ZTop \
        -destination 'generic/platform=macOS' build CODE_SIGNING_ALLOWED=NO
fi

echo "check: all stages ok"
