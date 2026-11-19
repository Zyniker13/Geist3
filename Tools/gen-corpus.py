#!/usr/bin/env python3
"""Generates the P2.7 validation corpus: 60 broken rulesets, ten per error
class (schema, reference, type, reachability, termination, fallback), plus
expected.tsv mapping each file to the error code and a message fragment the
validator must produce. Deterministic; re-run to regenerate.

Each case starts from a minimal ruleset that validates clean, then introduces
exactly one defect.
"""

import copy
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "docs", "rulesets", "corpus")

TEMPLATE = {
    "format": "parlor.ruleset/1",
    "id": "test.minimal",
    "game": "test",
    "kind": "standard",
    "version": "1.0.0",
    "name": {"default": "Minimal Test"},
    "players": {"counts": [2, 3, 4], "default": 4, "teams": "none"},
    "deck": {"base": "french-52"},
    "zones": [
        {"id": "stock", "scope": "shared", "visibility": "none"},
        {"id": "hand", "scope": "seat", "visibility": "owner"},
        {"id": "discards", "scope": "shared", "visibility": "public"},
    ],
    "options": [
        {
            "id": "targetScore", "type": "int", "default": 100,
            "min": 10, "max": 500, "label": {"default": "Target score"},
            "rules": []
        }
    ],
    "vars": {
        "target": {"scope": "match", "type": "int", "initial": "100"},
        "score": {"scope": "seatMatch", "type": "int", "initial": "0"},
    },
    "setup": {"firstDealer": "highCut", "dealerRotation": "left"},
    "phases": [
        {"id": "deal", "mechanic": "deal",
         "params": {"packets": [{"to": "hand", "each": 5}]}},
        {"id": "show", "mechanic": "show",
         "params": {"order": [{"zone": "hand", "seat": "seat"}]}},
        {"id": "score", "mechanic": "score",
         "params": {"effects": [
             {"forEach": "seat", "do": [{"set": "match.score[seat]", "to": "1"}]}
         ]}},
    ],
    "end": {
        "check": "afterDeal",
        "when": "seats().exists(s, match.score[s] >= options.targetScore)",
        "rank": "descending(match.score)",
        "ties": "shared",
    },
}

TRICK_PHASE = {
    "id": "play", "mechanic": "trick-play",
    "params": {"tricks": 1, "leadAllowed": {"expr": "true", "otherwise": "any"}},
}


def write(name, doc_or_text, code, fragment):
    path = os.path.join(OUT, name)
    if isinstance(doc_or_text, str):
        text = doc_or_text
    else:
        text = json.dumps(doc_or_text, indent=2, ensure_ascii=False) + "\n"
    with open(path, "w") as f:
        f.write(text)
    return f"{name}\t{code}\t{fragment}"


def base():
    return copy.deepcopy(TEMPLATE)


def with_trick(doc):
    """Swaps the show phase for a trick-play phase (linear, progress ok)."""
    doc["phases"][1] = copy.deepcopy(TRICK_PHASE)
    return doc


def main():
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        os.remove(os.path.join(OUT, old))
    rows = []

    def case(name, mutate, code, fragment, raw=None):
        doc = base()
        if mutate:
            mutate(doc)
        rows.append(write(name, raw if raw else doc, code, fragment))

    # --- schema (decode/shape/required/vocabulary-of-the-schema) ---
    case("schema-01-missing-players.json", lambda d: d.pop("players"),
         "schema/missing-field", "'players' section is required")
    case("schema-02-missing-end.json", lambda d: d.pop("end"),
         "schema/missing-field", "'end' section is required")
    case("schema-03-missing-phases.json", lambda d: d.pop("phases"),
         "schema/missing-field", "'phases' section is required")
    case("schema-04-missing-deck.json", lambda d: d.pop("deck"),
         "schema/missing-field", "'deck' section is required")
    case("schema-05-phases-not-list.json", lambda d: d.update(phases={"id": "deal"}),
         "schema/wrong-type", "wrong shape")
    case("schema-06-unknown-key.json",
         lambda d: d["phases"][0].update(mood="cheerful"),
         "schema/wrong-type", "unknown keys")
    case("schema-07-bad-json.json", None, "schema/bad-json", "not valid JSON",
         raw=json.dumps(base(), indent=2) + "\n}} trailing garbage\n")
    case("schema-08-format-mismatch.json",
         lambda d: d.update(format="parlor.overlay/1"),
         "schema/format-mismatch", "does not match this document kind")
    case("schema-09-unknown-mechanic.json",
         lambda d: d["phases"][0].update(mechanic="roulette"),
         "schema/unknown-mechanic", "'roulette' is not a mechanic")
    case("schema-10-missing-mechanic.json",
         lambda d: d["phases"][0].pop("mechanic"),
         "schema/missing-field", "'mechanic' is required")

    # --- reference (ids, zones, vars, rules, options, vocabularies) ---
    case("reference-01-unknown-next.json",
         lambda d: d["phases"][0].update(next="'ghost'"),
         "reference/unknown-phase", "'ghost', which is not a phase id")
    case("reference-02-unknown-zone.json",
         lambda d: d["phases"][0]["params"]["packets"][0].update(to="mantelpiece"),
         "reference/unknown-zone", "mantelpiece")
    case("reference-03-unknown-var-write.json",
         lambda d: d["phases"][2]["params"]["effects"][0]["do"][0].update(
             set="match.glory[seat]"),
         "reference/unknown-var", "glory")
    case("reference-04-unknown-rule.json",
         lambda d: d["options"][0].update(rules=["ZZZ-9.9"]),
         "reference/unknown-rule", "ZZZ-9.9")
    case("reference-05-duplicate-phase.json",
         lambda d: d["phases"].append(copy.deepcopy(d["phases"][2])),
         "reference/duplicate-id", "'score' is declared more than once")
    case("reference-06-duplicate-zone.json",
         lambda d: d["zones"].append({"id": "hand", "scope": "shared", "visibility": "none"}),
         "reference/duplicate-id", "'hand' is declared more than once")
    case("reference-07-bad-end-check.json",
         lambda d: d["end"].update(check="whenever"),
         "reference/bad-vocabulary", "'whenever' is not a known end check")
    case("reference-08-bad-visibility.json",
         lambda d: d["zones"][1].update(visibility="everyone"),
         "reference/bad-vocabulary", "'everyone' is not a known zone visibility")
    case("reference-09-bad-teams.json",
         lambda d: d["players"].update(teams="sides"),
         "reference/bad-vocabulary", "'sides' is not a known team layout")
    case("reference-10-option-range.json",
         lambda d: d["options"][0].update(default=1000),
         "reference/option-range", "above the maximum")

    # --- type (expressions fail to parse or check) ---
    case("type-01-var-initial-type.json",
         lambda d: d["vars"]["target"].update(initial="'abc'"),
         "type/type-mismatch", "must produce int")
    case("type-02-phase-when-not-bool.json",
         lambda d: d["phases"][1].update(when="1"),
         "type/type-mismatch", "must produce bool")
    case("type-03-end-when-not-bool.json",
         lambda d: d["end"].update(when="match.score"),
         "type/type-mismatch", "must produce bool")
    case("type-04-set-value-type.json",
         lambda d: d["phases"][2]["params"]["effects"][0]["do"][0].update(to="'hearts'"),
         "type/type-mismatch", "must produce int")
    case("type-05-parse-error.json",
         lambda d: d["phases"][1].update(when="seats(().exists"),
         "type/parse-error", "does not parse")
    case("type-06-unknown-name.json",
         lambda d: d["phases"][1].update(when="noSuchVar > 2"),
         "type/expression-error", "unknown name 'noSuchVar'")
    case("type-07-bad-def-signature.json",
         lambda d: d.update(defs={"broken(": "1"}),
         "type/def-signature", "signature")
    case("type-08-def-body-parse.json",
         lambda d: d.update(defs={"f() -> int": "1 +"}),
         "type/parse-error", "body of 'f() -> int'")
    case("type-09-def-recursion.json",
         lambda d: d.update(defs={"f() -> int": "f()"}),
         "type/expression-error", "recursive")
    case("type-10-index-scope.json",
         lambda d: d["phases"][2]["params"]["effects"][0]["do"][0].update(
             set="match.target[seat]"),
         "type/type-mismatch", "cannot take an index")

    # --- reachability (phases nothing reaches; every case needs an
    #     explicit `next` that skips the unreachable phase) ---
    def ghost(pid):
        return {"id": pid, "mechanic": "show",
                "params": {"order": [{"zone": "hand", "seat": "seat"}]}}

    case("reach-01-middle-skipped.json",
         lambda d: d["phases"][0].update(next="'score'"),
         "reachability/unreachable-phase", "'show' can never run")
    case("reach-02-ghost-between.json",
         lambda d: (d["phases"][0].update(next="'score'"),
                    d["phases"].insert(1, ghost("ghost"))),
         "reachability/unreachable-phase", "'ghost' can never run")
    case("reach-03-ghost-with-when.json",
         lambda d: (d["phases"][0].update(next="'score'"),
                    d["phases"].insert(1, dict(ghost("ghost"), when="false"))),
         "reachability/unreachable-phase", "'ghost' can never run")
    case("reach-04-two-ghosts.json",
         lambda d: (d["phases"][0].update(next="'score'"),
                    d["phases"].insert(1, ghost("ghostA")),
                    d["phases"].insert(2, ghost("ghostB"))),
         "reachability/unreachable-phase", "'ghostA' can never run")
    case("reach-05-ghost-and-show.json",
         lambda d: (d["phases"][0].update(next="'score'"),
                    d["phases"].insert(1, ghost("ghost"))),
         "reachability/unreachable-phase", "'show' can never run")
    case("reach-06-show-jumps-on.json",
         lambda d: (d["phases"][1].update(next="'score'"),
                    d["phases"].insert(2, ghost("ghost"))),
         "reachability/unreachable-phase", "'ghost' can never run")
    case("reach-07-deal-skips-two.json",
         lambda d: (d["phases"][0].update(next="'score'"),
                    d["phases"].insert(1, ghost("ghostA"))),
         "reachability/unreachable-phase", "'ghostA' can never run")
    case("reach-08-deal-skips-to-ghost.json",
         lambda d: (d["phases"][0].update(next="'ghostA'"),
                    d["phases"].insert(2, ghost("ghostA"))),
         "reachability/unreachable-phase", "'show' can never run")
    case("reach-09-loop-orphan.json",
         lambda d: (d["phases"][1].update(next="'deal'"),
                    d["phases"].append(ghost("ghost"))),
         "reachability/unreachable-phase", "'score' can never run")
    case("reach-10-ghost-first-gap.json",
         lambda d: (d["phases"][0].update(next="'show'"),
                    d["phases"].insert(1, ghost("ghost"))),
         "reachability/unreachable-phase", "'ghost' can never run")

    # --- termination (no progress measure / end var never written) ---
    def cycle(doc, phases):
        doc["phases"] = [doc["phases"][0]] + phases

    def show_p(pid, nxt):
        p = {"id": pid, "mechanic": "show",
             "params": {"order": [{"zone": "hand", "seat": "seat"}]}}
        if nxt:
            p["next"] = nxt
        return p

    def score_p(nxt):
        p = {"id": "score", "mechanic": "score",
             "params": {"effects": [
                 {"forEach": "seat", "do": [{"set": "match.score[seat]", "to": "1"}]}
             ]}}
        if nxt:
            p["next"] = nxt
        return p

    case("term-01-show-score-cycle.json",
         lambda d: cycle(d, [show_p("show", "'score'"), score_p("'show'")]),
         "termination/no-progress", "form a loop where nothing changes")
    case("term-02-score-self-loop.json",
         lambda d: cycle(d, [score_p("'score'")]),
         "termination/no-progress", "form a loop where nothing changes")
    case("term-03-empty-score-never-ends.json",
         lambda d: d["phases"][2]["params"].update(effects=[]),
         "termination/end-var-unchanged", "no effect writes")
    case("term-04-when-options-only.json",
         lambda d: d["end"].update(when="options.targetScore > 0"),
         "termination/end-var-unchanged", "no effect writes")
    case("term-05-show-self-loop.json",
         lambda d: d["phases"][1].update(next="'show'"),
         "termination/no-progress", "form a loop where nothing changes")
    case("term-06-three-phase-cycle.json",
         lambda d: cycle(d, [show_p("show", "'score'"), score_p("'tally'"),
                             show_p("tally", "'show'")]),
         "termination/no-progress", "form a loop where nothing changes")
    case("term-07-cycle-and-unchanged.json",
         lambda d: (cycle(d, [show_p("show", "'score'"), score_p("'show'")]),
                    d["end"].update(when="match.target >= 0")),
         "termination/no-progress", "form a loop where nothing changes")
    case("term-08-score-to-show.json",
         lambda d: cycle(d, [score_p("'show'"), show_p("show", "'score'")]),
         "termination/no-progress", "form a loop where nothing changes")
    case("term-09-unchanged-deal-var.json",
         lambda d: d["end"].update(when="deal.dealPoints[s] >= 0"),
         "termination/end-var-unchanged", "no effect writes")
    case("term-10-cycle-no-deal.json",
         lambda d: d.update(phases=[show_p("show", "'score'"), score_p("'show'")]),
         "termination/no-progress", "form a loop where nothing changes")

    # --- fallback (otherwise values outside the vocabulary) ---
    def bad_guard(d, field, value):
        with_trick(d)
        d["phases"][1]["params"][field] = {"expr": "true", "otherwise": value}

    case("fallback-01-lead-pass.json", lambda d: bad_guard(d, "leadAllowed", "pass"),
         "fallback/invalid", "not a valid fallback")
    case("fallback-02-play-pass.json", lambda d: bad_guard(d, "playAllowed", "pass"),
         "fallback/invalid", "not a valid fallback")
    case("fallback-03-lead-empty.json", lambda d: bad_guard(d, "leadAllowed", ""),
         "fallback/invalid", "not a valid fallback")
    case("fallback-04-play-empty.json", lambda d: bad_guard(d, "playAllowed", ""),
         "fallback/invalid", "not a valid fallback")
    case("fallback-05-lead-none.json", lambda d: bad_guard(d, "leadAllowed", "none"),
         "fallback/invalid", "not a valid fallback")
    case("fallback-06-play-none.json", lambda d: bad_guard(d, "playAllowed", "none"),
         "fallback/invalid", "not a valid fallback")
    case("fallback-07-lead-skip.json", lambda d: bad_guard(d, "leadAllowed", "skip"),
         "fallback/invalid", "not a valid fallback")
    case("fallback-08-play-skip.json", lambda d: bad_guard(d, "playAllowed", "skip"),
         "fallback/invalid", "not a valid fallback")
    case("fallback-09-both-guards.json",
         lambda d: (bad_guard(d, "leadAllowed", "maybe"),),
         "fallback/invalid", "not a valid fallback")
    case("fallback-10-lead-again.json", lambda d: bad_guard(d, "leadAllowed", "leadAgain"),
         "fallback/invalid", "not a valid fallback")

    # The canary: the unmodified template must validate clean.
    rows.append(write("_valid-template.json", base(), "-", "-"))

    with open(os.path.join(OUT, "expected.tsv"), "w") as f:
        f.write("# filename\texpected error code\tmessage fragment\n")
        f.write("\n".join(rows) + "\n")
    print(f"wrote {len(rows)} cases + expected.tsv to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
