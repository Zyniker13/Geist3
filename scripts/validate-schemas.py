#!/usr/bin/env python3
"""P2.9: validate the reference rulesets against the exported JSON Schemas.

The schemas themselves must be valid draft 2020-12 documents, and every
ruleset under docs/plan/rulesets/*.ruleset.json must validate against the
ruleset schema (ARCHITECTURE §5.2 line 195). Lesson files are validated
against the lesson schema when they exist (P4).
"""

import glob
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_DIR = ROOT / "Resources" / "Schemas"

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("error: jsonschema not installed (CI: pip install jsonschema)", file=sys.stderr)
    sys.exit(2)


def main() -> int:
    ok = True
    validators = {}
    for name in ("ruleset", "lesson"):
        path = SCHEMA_DIR / f"{name}.schema.json"
        if not path.exists():
            print(f"error: missing {path.relative_to(ROOT)}", file=sys.stderr)
            return 2
        schema = json.loads(path.read_text())
        try:
            Draft202012Validator.check_schema(schema)
        except Exception as exc:  # noqa: BLE001 - report and fail
            print(f"{path.name}: invalid JSON Schema: {exc}")
            ok = False
            continue
        validators[name] = Draft202012Validator(schema)
        print(f"{path.name}: valid draft 2020-12")

    for doc in sorted((ROOT / "docs" / "plan" / "rulesets").glob("*.ruleset.json")):
        validator = validators.get("ruleset")
        if validator is None:
            break
        errors = sorted(validator.iter_errors(json.loads(doc.read_text())), key=str)
        if errors:
            ok = False
            print(f"{doc.relative_to(ROOT)}: FAILED ({len(errors)} error(s))")
            for error in errors[:5]:
                where = "/".join(str(p) for p in error.absolute_path) or "(root)"
                print(f"  - {where}: {error.message}")
        else:
            print(f"{doc.relative_to(ROOT)}: OK")

    for doc in sorted((ROOT / "docs" / "plan" / "rulesets" / "lessons").glob("*.json")):
        validator = validators.get("lesson")
        if validator is None:
            break
        errors = sorted(validator.iter_errors(json.loads(doc.read_text())), key=str)
        if errors:
            ok = False
            print(f"{doc.relative_to(ROOT)}: FAILED ({len(errors)} error(s))")
            for error in errors[:5]:
                where = "/".join(str(p) for p in error.absolute_path) or "(root)"
                print(f"  - {where}: {error.message}")
        else:
            print(f"{doc.relative_to(ROOT)}: OK")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
