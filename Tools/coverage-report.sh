#!/usr/bin/env bash
# Per-package line coverage from llvm-cov lcov export over one or more test
# binaries. Usage: coverage-report.sh <binary>[:<instrprofile>] ...
# Prints TOTAL per top-level package dir and fails if any package < threshold
# (default 90; override globally with COVERAGE_MIN or per package with
# COVERAGE_THRESHOLDS, e.g. "CardExpr=95,RulesEngine=90").
set -euo pipefail
THRESHOLD="${COVERAGE_MIN:-90}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Merge all lcov exports into one tracefile keyed by absolute source path.
: > "$TMP/all.info"
for spec in "$@"; do
  BIN="${spec%%:*}"
  PROF="${spec#*:}"
  xcrun llvm-cov export "$BIN" -instr-profile="$PROF" -format=lcov >> "$TMP/all.info"
done
python3 - "$TMP/all.info" "$THRESHOLD" "${COVERAGE_THRESHOLDS:-}" <<'PYEOF'
import sys, collections
trace, default_threshold, overrides_arg = sys.argv[1], float(sys.argv[2]), sys.argv[3]
overrides = {}
for pair in overrides_arg.split(',') if overrides_arg else []:
    pkg, _, thr = pair.partition('=')
    if pkg and thr:
        overrides[pkg] = float(thr)
best = {}  # (source file, line) -> max count across all records
cur_file = None
for line in open(trace):
    if line.startswith('SF:'):
        cur_file = line[3:].strip()
    elif cur_file and line.startswith('DA:'):
        ln, cnt = line[3:].strip().split(',')
        key = (cur_file, int(ln))
        c = int(cnt)
        if key not in best or c > best[key]:
            best[key] = c
    elif line.startswith('end_of_record'):
        cur_file = None
pkg_hit, pkg_total = collections.Counter(), collections.Counter()
for (path, _ln), cnt in best.items():
    idx = path.find('/Packages/')
    rel = path[idx + len('/Packages/'):] if idx >= 0 else path
    parts = rel.split('/')
    if len(parts) < 2 or parts[1] not in ('Sources', 'ToyGame'):
        continue  # tests and generated entry points are excluded
    fdir = '/'.join(parts[:2])
    pkg_total[fdir] += 1
    if cnt > 0:
        pkg_hit[fdir] += 1
bad = False
for fdir in sorted(pkg_total):
    if not pkg_total[fdir]:
        continue
    threshold = overrides.get(fdir.split('/')[0], default_threshold)
    pct = 100.0 * pkg_hit[fdir] / pkg_total[fdir]
    flag = '' if pct >= threshold else '  <-- BELOW'
    if pct < threshold:
        bad = True
    print(f"{fdir}: {pkg_hit[fdir]}/{pkg_total[fdir]} lines = {pct:.1f}%{flag}")
sys.exit(1 if bad else 0)
PYEOF
