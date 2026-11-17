#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Measure the agent's CPU and memory usage against the budget in DESIGN.md.
#
# Budget (at a 1-second interval):
#   - Under 1% of one core
#   - Under 30 MB resident memory
#
# Usage:
#     ./measure-agent.sh [duration_seconds]
#
# The script starts the agent, measures its CPU and memory usage over the
# specified duration (default: 60 seconds), and reports the results.

set -euo pipefail

DURATION="${1:-60}"
PORT="${2:-7102}"

echo "Measuring zTop agent resource usage..."
echo "Duration: ${DURATION}s"
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

"$ZTOP_BIN" agent --tls --pair --port "$PORT" &
AGENT_PID=$!

echo "Agent started (PID: ${AGENT_PID})"
echo "Waiting 10 seconds for the agent to stabilize..."
sleep 10

# Measure CPU and memory usage
echo "Measuring resource usage for ${DURATION} seconds..."
echo ""

# Use ps to measure CPU and memory usage
# On macOS, ps -o %cpu,rss shows CPU% and resident memory in KB
# On Linux, ps -o %cpu,rss shows CPU% and resident memory in KB

# Get the initial CPU time
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: use ps -o %cpu,rss
    INITIAL_CPU=$(ps -o %cpu= -p "$AGENT_PID" 2>/dev/null || echo "0")
    INITIAL_RSS=$(ps -o rss= -p "$AGENT_PID" 2>/dev/null || echo "0")
else
    # Linux: use ps -o %cpu,rss
    INITIAL_CPU=$(ps -o %cpu= -p "$AGENT_PID" 2>/dev/null || echo "0")
    INITIAL_RSS=$(ps -o rss= -p "$AGENT_PID" 2>/dev/null || echo "0")
fi

# Wait for the measurement period
sleep "$DURATION"

# Get the final CPU time
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: use ps -o %cpu,rss
    FINAL_CPU=$(ps -o %cpu= -p "$AGENT_PID" 2>/dev/null || echo "0")
    FINAL_RSS=$(ps -o rss= -p "$AGENT_PID" 2>/dev/null || echo "0")
else
    # Linux: use ps -o %cpu,rss
    FINAL_CPU=$(ps -o %cpu= -p "$AGENT_PID" 2>/dev/null || echo "0")
    FINAL_RSS=$(ps -o rss= -p "$AGENT_PID" 2>/dev/null || echo "0")
fi

# Kill the agent
kill "$AGENT_PID" 2>/dev/null || true
wait "$AGENT_PID" 2>/dev/null || true

echo "Results:"
echo "  CPU usage: ${FINAL_CPU}%"
echo "  Resident memory: ${FINAL_RSS} KB"
echo ""

# Check against the budget (awk: bc is not everywhere)
CPU_BUDGET=1.0
MEM_BUDGET=30720  # 30 MB in KB

if awk -v cpu="$FINAL_CPU" -v mem="$FINAL_RSS" 'BEGIN {
    exit (cpu < 1.0 && mem < 30720) ? 0 : 1
}'; then
    echo "PASS: Agent is within the budget (CPU < 1%, memory < 30 MB)"
    exit 0
else
    echo "FAIL: Agent exceeds the budget"
    awk -v cpu="$FINAL_CPU" 'BEGIN { if (cpu >= 1.0) print "  CPU usage (" cpu "%) exceeds the budget (1.0%)" }'
    awk -v mem="$FINAL_RSS" 'BEGIN { if (mem >= 30720) print "  Memory usage (" mem " KB) exceeds the budget (30720 KB)" }'
    exit 1
fi
