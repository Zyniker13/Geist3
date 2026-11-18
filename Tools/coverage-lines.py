#!/usr/bin/env python3
"""Print uncovered (count==0) region-start lines per source file from a
SwiftPM codecov JSON. Usage: coverage-lines.py <codecov.json> [pkg ...]"""
import json
import sys

path = sys.argv[1]
d = json.load(open(path))
for f in d['data'][0]['files']:
    name = f['filename'].split('/Geist3/')[-1]
    if '/Tests/' in name or 'DerivedSources' in name:
        continue
    zero = sorted({s[0] for s in f['segments'] if s[2] == 0 and s[1] == 1})
    if zero:
        print(name, zero)
