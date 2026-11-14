#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Scrub and trim a recorded fixture for committing.

A live capture contains a machine's process list: command lines and process
names are not publishable data. This tool copies a fixture directory, replaces
per-process cmdline/comm/status-Name values with obviously fake names
(`proc-a`, `proc-b`, ...), keeps verbatim numeric files, keeps at most a
bounded number of processes, regenerates manifest.json for the surviving
entries, and marks the manifest source with a `-scrubbed` suffix.

The parsers must accept both real and scrubbed text, so the scrub never
becomes parser load-bearing (decision 0007).

Usage: scrub-fixture.py IN_DIR OUT_DIR [--procs N]
"""

import argparse
import json
import re
import shutil
from pathlib import Path

FAKE_NAMES = [f"proc-{c}" for c in "abcdefghijklmnopqrstuvwxyz"]

PROC_PID_RE = re.compile(r"^proc-(\d+)-(cmdline|comm|status|stat)$")


def scrub_pid_name(pid: int, index: int) -> str:
    return FAKE_NAMES[index % len(FAKE_NAMES)] + f"-{pid}"


def scrub_status(text: str, fake: str) -> str:
    """Replace the `Name:` line of a /proc/<pid>/status file."""
    return re.sub(r"(?m)^Name:\t.*$", f"Name:\t{fake}", text, count=1)


def scrub_stat(text: str, fake: str) -> str:
    """Replace the parenthesised comm field (second field) of a stat file."""
    head, sep, tail = text.partition(" (")
    if not sep:
        return text
    _comm, sep2, rest = tail.rpartition(") ")
    if not sep2:
        return text
    return f"{head} ({fake}) {rest}"


def scrub_text(name: str, text: str, fake: str) -> str:
    kind = name.rsplit("-", 1)[-1]
    if kind == "cmdline":
        return fake + "\0"
    if kind == "comm":
        return fake + "\n"
    if kind == "stat":
        return scrub_stat(text, fake)
    return scrub_status(text, fake)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("src", type=Path)
    parser.add_argument("dst", type=Path)
    parser.add_argument("--procs", type=int, default=12)
    args = parser.parse_args()

    manifest = json.loads((args.src / "manifest.json").read_text())

    # Collect per-process entries keyed by pid, and everything else.
    fixed: list[dict] = []
    per_pid: dict[int, list[dict]] = {}
    for entry in manifest["entries"]:
        match = PROC_PID_RE.match(entry["name"])
        if match:
            per_pid.setdefault(int(match.group(1)), []).append(entry)
        else:
            fixed.append(entry)

    # Deterministic choice: the lowest pids survive the trim.
    keep_pids = sorted(per_pid)[: args.procs]
    fake_by_pid = {
        pid: scrub_pid_name(pid, index) for index, pid in enumerate(keep_pids)
    }

    kept = list(fixed)
    for pid in keep_pids:
        kept.extend(per_pid[pid])

    if args.dst.exists():
        shutil.rmtree(args.dst)
    (args.dst / "data").mkdir(parents=True)

    out_entries = []
    for entry in manifest["entries"]:
        name = entry["name"]
        src = args.src / entry["path"]
        if name not in {e["name"] for e in kept}:
            continue
        match = PROC_PID_RE.match(name)
        data = src.read_text()
        if match and match.group(2) in ("cmdline", "comm", "status"):
            data = scrub_text(name, data, fake_by_pid[int(match.group(1))])
        dst = args.dst / entry["path"]
        dst.write_text(data)
        out_entries.append(entry)

    manifest["entries"] = out_entries
    manifest["source"] = manifest["source"] + "-scrubbed"
    (args.dst / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n"
    )
    print(f"kept {len(out_entries)} entries: {len(fixed)} fixed + {len(keep_pids)} processes")


if __name__ == "__main__":
    main()
