# G3 Review Request — First Four Games (Hearts, Euchre, Bridge, Cribbage)

Parlor P3 is complete and every automated check passes (`make gate PHASE=P3`
exit 0 at commit `6fa7f41`; CI green at branch head `7994ece` — run
45654745210, every step success). This request asks three
reviewers for the sign-offs ROADMAP.md blocks G3 on: `REVIEW: CLAUDE`,
`REVIEW: GROK`, `REVIEW: MAHLER`. Record each verdict in `docs/STATUS.md`
under `## G3 reviews` as `REVIEW: <name> — PASS` (or FAIL with findings);
GLM resumes only when all three PASS entries exist.

Branch: `phase/P3-first-four-games` · Review head: `4245dfe` · Gate commit: `6fa7f41`

Note: commits after `4245dfe` (up to `7994ece`) touch only test
measurement, CI wiring and docs (ADR-0040, 0040a, 0041, 0042) — the
engine, rulesets, rules documents and app are exactly as reviewed here.

---

## How to run everything

Start from `docs/HANDOFF.md` (the §10 handoff package). The 10-minute script
is its §9; the full battery is `make gate PHASE=P3` (~40 min). Toolchain and
build steps are its §1. Repo: https://github.com/Zyniker13/Geist3.

Quick start:

```sh
git clone https://github.com/Zyniker13/Geist3 && cd Geist3
git checkout phase/P3-first-four-games
make bootstrap         # toolchain check
make lint              # exit 0 required
make validate          # ruleset corpus: 61 passed, 0 failed
make conformance       # 54/54 rule ids covered, writes docs/CONFORMANCE.md
make rules-check       # rule-ID <-> rules-doc cross-check, 4 games
make sim N=200         # random-legal simulation, reproducible
make gate PHASE=P3     # everything (~40 min; CI runs the same steps)
```

## What each reviewer checks

### REVIEW: CLAUDE — engine and DSL architecture

Scope: is the mechanics library general enough for Waves 2–3; are
expressions readable; is redaction structurally sound.

- `Packages/RulesEngine/Sources/` — the reducer (`Engine.swift`,
  `Engine+Match.swift`), the twelve mechanics, `Knowledge`/`Redactor`
  (ADR-0038: zone visibility = knowledge grants at card entry),
  `Observation`.
- `Packages/CardExpr/Sources/` + `Packages/RulesetKit/Sources/Schema/` —
  the expression language, resolver, validator; a sample ruleset
  (`Resources/Rulesets/contract-bridge.rubber.ruleset.json` is the largest).
- ADRs 0031–0039 in `docs/DECISIONS.md` (the mechanic contracts pinned by
  the four games; the app-side SPI exception ADR-0039).
- Known rough edges to judge: `pendingSeats`/`legalIntents`/`apply`
  mirroring per mechanic (the P3.7 hang was a break of this invariant —
  `pendingClaimWaitsOnlyOnUnvotedVoters` guards it); the conformance
  stacked-deck override being SPI rather than a core feature (ADR-0037);
  `coverage-check` including the RulesetKit binary (measurement note in
  `docs/STATUS.md` §G3).

### REVIEW: GROK — rules correctness of the four games

Scope: the rulesets against sources; defaults sensible.

- Read `docs/rules/RULES-hearts.md`, `RULES-euchre.md`,
  `RULES-contract-bridge.md`, `RULES-cribbage.md` next to their rulesets in
  `Resources/Rulesets/` (IDs must line up; `make rules-check` enforces).
- The conformance suites are the behavioral evidence:
  `Packages/RulesetKit/Tests/RulesetKitTests/Conformance{Hearts,Euchre,Bridge,Cribbage}.swift`
  — stacked decks put each rule situation on the table; scoring tables are
  checked against hand-built expectations.
- Every default applied to an ambiguity is in `docs/OPEN_QUESTIONS.md`
  (13 entries); the per-game option defaults are summarized in
  `docs/HANDOFF.md` §6. Flag any default that disagrees with the cited
  source.
- No source text was copied: prose is original, sources are cited by link
  (each RULES page's **Sources** block).

### REVIEW: MAHLER — play one deal of each game on an iPad

Scope: do the rules *feel* right in play.

- Build and run `Parlor-iOS` on an iPad simulator (HANDOFF §1): launcher
  lists hearts, euchre, contract-bridge.rubber, cribbage.six-card; each
  opens the dev play screen where you act through the `Play #…` buttons
  and the bots fill the other seats. A full deal of each game completes
  (the automated proof is `DevPlayUITests.testPlaysOneFullDealOfEachGame`,
  110 s on the iPad simulator).
- Watch for: auction/play order that surprises you, scoring that doesn't
  match the rules documents, and the illegal-tap explanations (tap a card
  when it's not your turn — a red explanation should appear).
- Screenshots of real mid-deal states: `docs/screenshots/p37-dev-*.png`.

## Known gaps (read before reviewing)

- The dev play screen is intentionally plain (P3.7); the real table UI
  lands in P4.1–P4.3. Any UI remark beyond "the rules feel wrong" is
  P4 scope, not a P3 blocker.
- macOS UI-test leg is carved out (ADR-0022, KI-1) — needs a one-time TCC
  approval on the build host; both iOS UI legs and macOS unit tests pass.
- `rules-cli sim` drives the toy fixture; the per-game 500-seed simulation
  evidence lives in the P3.3 STATUS entry (test harness), not the CLI.
- Lint warnings are advisory (P0 policy); swift-format strict and
  check-imports are hard gates.
- The engine measured 84.6% line coverage from its own package tests
  alone; the gate number (92.3%) merges the RulesetKit suites, which are
  the engine's real exercisers (ADR-0037). Measurement note in STATUS.

## Rule defaults chosen (full list, per game)

Hearts (`hearts.standard`): passSchedule left/right/across/hold, passCount 3,
noPointsFirstTrick on (queen included), breakingHearts on, queenBreaksHearts
on, moon addToOthers (+26), jackOfDiamonds off, target 100.
Euchre (`euchre.standard`): stickTheDealer **off**, goingAlone on,
alonePoints 4, target 10 (bowers follow trump; euchre = 2 to defenders;
3–4 tricks = 1, 5 = 2).
Bridge (`contract-bridge.rubber`): honors on, passOut redealNextDealer,
claims on (declarer proposes, defenders accept; rubber bonus 700/500 per
RULES-contract-bridge §4).
Cribbage (`cribbage.six-card`): target 121, muggins off, manualCounting off,
skunks on (under 91 in a 121 game); continuous scoring; five-card flush in
the crib only; his heels 2.
Variants (only where they change the base): chicago/duplicate
(vulnerability, scoring display), canadian-loner (alonePoints ordering),
five-card (11-point game). See each `.variant.json`.
