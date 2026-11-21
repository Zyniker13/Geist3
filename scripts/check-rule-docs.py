#!/usr/bin/env python3
"""Check that each rules document covers exactly the rule IDs of its ruleset.

For every pair (ruleset JSON, RULES markdown) the script extracts rule IDs
(``ABC-n.m``) two ways and requires the sets to be equal:

* the ruleset: values of ``rule``/``ruleId``/``*Rule`` keys and entries of
  option ``rules`` arrays anywhere in the JSON document;
* the document: every ``ABC-n.m`` token in the markdown text.

Usage: check-rule-docs.py [ruleset.doc ...]  (defaults to all four)
"""

import json
import re
import sys
from pathlib import Path

ID = re.compile(r"\b([A-Z]{3}-\d+\.\d+)\b")

PAIRS = [
    ("hearts.standard", "docs/plan/rulesets/hearts.standard.ruleset.json", "docs/rules/RULES-hearts.md"),
    ("euchre.standard", "docs/plan/rulesets/euchre.standard.ruleset.json", "docs/rules/RULES-euchre.md"),
    ("contract-bridge.rubber", "docs/plan/rulesets/contract-bridge.rubber.ruleset.json", "docs/rules/RULES-contract-bridge.md"),
    ("cribbage.six-card", "docs/plan/rulesets/cribbage.six-card.ruleset.json", "docs/rules/RULES-cribbage.md"),
]


def ruleset_ids(path: Path) -> set[str]:
    ids: set[str] = set()
    doc = json.loads(path.read_text())

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if isinstance(value, str) and (
                    key in ("rule", "ruleId") or key.endswith("Rule")
                ):
                    match = ID.search(value)
                    if match:
                        ids.add(match.group(1))
                elif key == "rules" and isinstance(value, list):
                    for item in value:
                        if isinstance(item, str):
                            match = ID.search(item)
                            if match:
                                ids.add(match.group(1))
                        elif isinstance(item, dict) and isinstance(item.get("id"), str):
                            match = ID.search(item["id"])
                            if match:
                                ids.add(match.group(1))
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(doc)
    return ids


def doc_ids(path: Path) -> set[str]:
    return set(ID.findall(path.read_text()))


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parent.parent
    failures = 0
    for name, ruleset, doc in PAIRS:
        want = ruleset_ids(root / ruleset)
        have = doc_ids(root / doc)
        missing = want - have
        extra = have - want
        if missing or extra:
            failures += 1
            print(f"FAIL {name}: doc {doc}")
            for ident in sorted(missing):
                print(f"  missing from document: {ident}")
            for ident in sorted(extra):
                print(f"  not in ruleset: {ident}")
        else:
            print(f"ok {name}: {len(want)} rule IDs covered in both directions")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
