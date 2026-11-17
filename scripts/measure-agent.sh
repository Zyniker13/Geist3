#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Measure the agent's CPU and memory usage against the budget in DESIGN.md.
#
# Budget (steady state, at a 1-second interval):
#   - Under 1% of one core
#   - Under 30 MB resident memory
#
# Usage:
#     ./measure-agent.sh [duration_seconds] [port]
#
# CPU is measured as the CPU time consumed during the measurement window
# (the difference of `ps -o cputime` before and after the window), not as
# a lifetime average: `ps -o %cpu` averages over the process's whole life,
# so the agent's startup cost (certificate generation) would leak into a
# steady-state measurement and fail the budget spuriously.

set -euo pipefail

DURATION="${1:-60}"
PORT="${2:-7102}"
SETTLE=10

echo "Measuring zTop agent resource usage..."
echo "Settle: ${SETTLE}s, window: ${DURATION}s"
echo "Port: ${PORT}"
echo ""

# Start the agent in the background
# Use the release binary if it exists, otherwise use the debug binary
if [[ -f "target/release/ztop" ]]; then
    ZTOP_BIN="target/release/ztop"
elif [[ -f "target/debug/ztop" ]]; then
    ZTOP_BIN="target/debug/ztop"
else
    ZTOP_BIN="ztop"
fi

"$ZTOP_BIN" agent --tls --pair --no-advertise --port "$PORT" &
AGENT_PID=$!

echo "Agent started (PID: ${AGENT_PID})"
echo "Waiting ${SETTLE} seconds for the agent to stabilize..."
sleep "$SETTLE"

if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "FAIL: the agent exited during startup" >&2
    exit 1
fi

CPU0="$(ps -o cputime= -p "$AGENT_PID")"

# Wait for the measurement period
sleep "$DURATION"

if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "FAIL: the agent exited during the measurement window" >&2
    exit 1
fi

CPU1="$(ps -o cputime= -p "$AGENT_PID")"
RSS="$(ps -o rss= -p "$AGENT_PID" | tr -d ' ')"

# Stop the agent
kill "$AGENT_PID" 2>/dev/null || true
wait "$AGENT_PID" 2>/dev/null || true

echo "Results (over the ${DURATION}s window, after ${SETTLE}s settle):"
echo "  CPU time: ${CPU0} -> ${CPU1}"
echo "  Resident memory: ${RSS} KB"
echo ""

# Check against the budget. `cputime` formats differ across platforms
# (macOS prints mm:ss.cc, Linux prints [DD-]hh:mm:ss); the awk parser
# handles both, including an optional day prefix and fractional seconds.
if ! awk -v a="$CPU0" -v b="$CPU1" -v w="$DURATION" -v rss="$RSS" '
    function secs(t,   i, d, f, n, p, k, v) {
        d = 0; f = 0
        if ((i = index(t, "-")) > 0) { d = substr(t, 1, i - 1) + 0; t = substr(t, i + 1) }
        if ((i = index(t, ".")) > 0) {
            f = substr(t, i + 1)
            while (length(f) < 2) f = f "0"
            f = f / 100
            t = substr(t, 1, i - 1)
        }
        n = split(t, p, ":"); v = 0
        for (k = 1; k <= n; k++) v = v * 60 + (p[k] + 0)
        return d * 86400 + v + f
    }
    BEGIN {
        cpu = (secs(b) - secs(a)) / w * 100
        printf "  CPU usage: %.2f%% of one core\n", cpu
        ok = 1
        if (cpu >= 1.0) { printf "  CPU %.2f%% exceeds the budget (1.0%%)\n", cpu; ok = 0 }
        if (rss + 0 >= 30720) { printf "  Memory %d KB exceeds the budget (30720 KB)\n", rss + 0; ok = 0 }
        exit (ok ? 0 : 1)
    }'; then
    echo "FAIL: the agent exceeds the budget"
    exit 1
fi

echo "PASS: the agent is within the budget (CPU < 1%, memory < 30 MB)"
