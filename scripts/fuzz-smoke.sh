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
# If the script dies for any reason (including a set -e kill inside the
# annotation path itself), say in which phase, so the failure is visible
# in the run's annotations even where the step log is not readable.
where="setup"
trap 'rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "::error title=fuzz-smoke::script exited %s in %s\n" "$rc" "$where"
  fi' EXIT

for target in $(ls fuzz_targets/*.rs | sed 's|fuzz_targets/||; s|\.rs$||' | sort); do
    where="target $target"
    printf 'fuzz-smoke: %s (-runs=%s)\n' "$target" "$runs"
    if cargo +nightly fuzz run "$target" --sanitizer none -- \
        -runs="$runs" -max_len="$max_len" >/dev/null 2>&1
    then
        printf 'fuzz-smoke: %s ok\n' "$target"
    else
        printf 'fuzz-smoke: %s FAILED\n' "$target"
        # Re-run with the output captured, and surface the reason as a
        # workflow command so it survives in the run's annotations even
        # where the step log itself is not readable.
        out="$(cargo +nightly fuzz run "$target" --sanitizer none -- \
            -runs="$runs" -max_len="$max_len" 2>&1 || true)"
        printf '%s\n' "$out"
        # Join the tail of the output into one workflow-command message
        # (newlines as %0A). awk, not sed: the label-loop idiom is GNU
        # only, and the macOS runner's BSD sed would fail it, killing
        # the script under set -e before the annotation is printed.
        msg="$(printf '%s\n' "$out" \
            | tr -d '\r' \
            | sed 's/%/%25/g' \
            | tail -c 1400 \
            | awk 'NR>1{printf "%%0A"} {printf "%s", $0}')"
        printf '::error title=fuzz target %s::%s\n' "$target" "$msg"
        status=1
    fi
done

exit $status
