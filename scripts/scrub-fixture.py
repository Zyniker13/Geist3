#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Scrub and trim a recorded fixture for committing.

A live capture contains a machine's process list: command lines and process
names are not publishable data. This tool copies a fixture directory, replaces
per-process cmdline/comm/status-Name values with obviously fake names
(`proc-a`, `proc-b`, ...), keeps verbatim numeric files, keeps at most a
bounded number of processes, regenerates manifest.json for the surviving
entries, and marks the manifest source with a `-scrubbed` suffix.

On macOS the capture has a single `processes` entry with one line per pid
(`pid ppid status threads "name"`); the quoted names are replaced with fake
names and the lines trimmed to the lowest pids.

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

# A macOS `processes` line: `pid ppid status uid utime stime rss threads
# "name"`, where task fields the kernel denies an unprivileged read of are
# `-` (decision 0009). Names are identifying and always scrubbed; pids,
# uids and counters are host-local numbers the Linux fixtures also keep.
MAC_PROC_RE = re.compile(
    r'^(?P<pid>\d+) (?P<rest>(?:\d+|-)(?: (?:\d+|-))*) "(?P<name>.*)"$',
    re.MULTILINE,
)


def mac_rows(text: str) -> list[tuple[int, bool, int]]:
    """(pid, has_task_fields, cpu_ns) for each macOS `processes` line."""
    rows = []
    for m in MAC_PROC_RE.finditer(text):
        fields = m["rest"].split(" ")
        has = len(fields) >= 7 and all(f.isdigit() for f in fields[3:7])
        cpu = int(fields[3]) + int(fields[4]) if has else 0
        rows.append((int(m["pid"]), has, cpu))
    return rows


def pick_mac_keep(text: str, want: int) -> list[int]:
    """Deterministic trim: the lowest pids plus the busiest real-field pids.

    The lowest pids are mostly root-owned, so their task fields are `-`;
    the busiest pids that carry task fields are same-user processes. The
    fixture keeps both shapes so parser tests exercise both.
    """
    rows = mac_rows(text)
    lowest = rows[: want // 2]
    kept = {pid for pid, _, _ in lowest}
    busy = sorted(
        (r for r in rows if r[1] and r[0] not in kept),
        key=lambda r: (-r[2], r[0]),
    )[: want - len(lowest)]
    return sorted({pid for pid, _, _ in lowest} | {pid for pid, _, _ in busy})


def scrub_process_entry(text: str, fake_by_pid: dict[int, str]) -> str:
    """Replace the quoted name tail of each `processes` line (macOS)."""
    out = []
    for line in text.splitlines():
        m = MAC_PROC_RE.match(line)
        if m and int(m["pid"]) in fake_by_pid:
            out.append(f'{m["pid"]} {m["rest"]} "{fake_by_pid[int(m["pid"])]}"')
    return "\n".join(out) + ("\n" if out else "")


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

    # A macOS capture has a single `processes` entry with one line per pid:
    # scrub its name tails and trim to a deterministic pid set.
    mac_processes = next(
        (e for e in manifest["entries"] if e["name"] == "processes"), None
    )
    if mac_processes is not None:
        text = (args.src / mac_processes["path"]).read_text()
        keep_pids = pick_mac_keep(text, args.procs)
        fake_by_pid = {
            pid: scrub_pid_name(pid, index) for index, pid in enumerate(keep_pids)
        }
        if args.dst.exists():
            shutil.rmtree(args.dst)
        (args.dst / "data").mkdir(parents=True)
        out_entries = []
        for entry in manifest["entries"]:
            src = args.src / entry["path"]
            data = src.read_text()
            if entry["name"] == "processes":
                data = scrub_process_entry(data, fake_by_pid)
            dst = args.dst / entry["path"]
            dst.write_text(data)
            out_entries.append(entry)
        manifest["entries"] = out_entries
        manifest["source"] = manifest["source"] + "-scrubbed"
        (args.dst / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n"
        )
        print(
            f"kept {len(out_entries)} entries: "
            f"{len(out_entries) - 1} fixed + {len(keep_pids)} processes"
        )
        return

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
        if match:
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
