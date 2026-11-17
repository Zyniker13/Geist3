#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# A short fuzz smoke of every network-facing parser: each target runs a
# small number of executions, enough to prove the target builds and the
# parser survives malformed input without panicking. Long runs stay
# manual: `cargo +nightly fuzz run <target>` from fuzz/ (see
# docs/decisions/0057 for why the targets live outside the workspace).
#
# The runs need the nightly toolchain and cargo-fuzz, and run without a
# sanitizer so the smoke stays fast; libFuzzer's own crash detection and
# the parser panics it catches are what the smoke is for.
set -eu
cd "$(dirname "$0")/../fuzz"

runs="${ZTOP_FUZZ_RUNS:-1000}"
max_len="${ZTOP_FUZZ_MAX_LEN:-8192}"
status=0

for target in $(ls fuzz_targets/*.rs | sed 's|fuzz_targets/||; s|\.rs$||' | sort); do
    printf 'fuzz-smoke: %s (-runs=%s)\n' "$target" "$runs"
    if cargo +nightly fuzz run "$target" --sanitizer none -- \
        -runs="$runs" -max_len="$max_len" >/dev/null 2>&1
    then
        printf 'fuzz-smoke: %s ok\n' "$target"
    else
        # Re-run without the output swallowed so the failure is readable.
        printf 'fuzz-smoke: %s FAILED\n' "$target"
        cargo +nightly fuzz run "$target" --sanitizer none -- \
            -runs="$runs" -max_len="$max_len" || true
        status=1
    fi
done

exit $status
