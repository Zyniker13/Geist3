#!/bin/bash
# xcodebuild-retry — run a command (normally "$SIM_LOCK xcodebuild … test"),
# and if it fails with the simulator app-launch timeout, retry it once.
#
# Why: XCUIApplication.launch() gives up after ~60 s. On shared CI runners a
# cold app launch under co-tenancy can exceed that (run 45589664158:
# "Timed out while launching application via Xcode" on the iPad leg, one
# hour after the same test passed in 130 s), and the failure cannot be
# caught or retried from inside the Swift test. A second attempt starts
# against an already-booted simulator with the app bundle cached, so it
# succeeds in the normal case. Any other failure is returned immediately —
# only this one known-flaky infrastructure symptom is retried, and only
# once.
set -u

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/xcodebuild-retry.XXXXXX")" || exit 2

run() {
  "$@" 2>&1 | tee "$LOG"
  return "${PIPESTATUS[0]}"
}

run "$@"
status=$?

if [ "$status" -ne 0 ] \
  && grep -q "Timed out while launching application via Xcode" "$LOG"; then
  echo "xcodebuild-retry: app-launch timeout detected; retrying once" >&2
  run "$@"
  status=$?
fi

rm -f "$LOG"
exit "$status"
