# HANDOFF

Purpose: the handoff package required at every 🛑 stop (`docs/plan/CONVENTIONS.md` §10): state, what works and what does not, architecture deltas, fragile areas, rule decisions, metrics, next steps, and a 10-minute reviewer script. This edition is the **G3 package** (P3 close, 2026-11-23).

## 1. State

- **Last passed gate:** G2 (merged to `main`, tag `gate-G2-pass`). P3 work is on branch `phase/P3-first-four-games`, head `f91a63d` (gate evidence at `6fa7f41`, CI re-verified green at `7994ece` — run 45654745210, all steps; `docs/STATUS.md` §G3). Only test measurement, CI wiring and docs changed after `4245dfe` (ADR-0040, 0040a, 0041, 0042) — no engine, ruleset or app changes.
- **How to build and run:**
  - Toolchain: Xcode 27.2 (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), xcodegen, SwiftLint 0.65.1, swift-format (see `docs/plan/CONVENTIONS.md` §7). `make bootstrap` verifies.
  - Regenerate the project after editing `project.yml`: `make gen`.
  - Build everything: `make build` (Parlor-iOS on an iPhone + iPad simulator, Parlor-macOS on this Mac).
  - Run the app: open `Parlor.xcodeproj` in Xcode, run the `Parlor-iOS` scheme on a simulator (launcher lists the four base games; each opens the dev play screen). Local bot simulator devices are the Makefile defaults when `~/.hermes/bin/sim-lock` exists; CI keeps the stock names.
  - Everything at once: `make gate PHASE=P3` (~40 min; `make -n gate PHASE=P3` shows the steps).

## 2. What works

- **Host (engine, `Packages/RulesEngine`):** seeded deterministic reducer (`Engine.start/apply/legalIntents/pendingSeats/observation`), zones + knowledge + vars + phase cursor, match lifecycle (dealer rotation, per-deal reset, end conditions, ranking), mechanics for the four games plus the toy: `deal`, `auction.ladder`, `auction.rounds`, `exchange.pass`, `exchange.kitty`, `exchange.discardTo`, `reveal.starter`, `trick-play` (follow/trump/dummy/claims), `count-play`, `show`, `score`; expression evaluation via CardExpr; redaction (`Observation`, knowledge-driven, monotone); replays with SHA-256 final-state hash; perf harness.
- **Rulesets (`Resources/Rulesets/`, 4 base + 4 variants):** hearts.standard, euchre.standard, contract-bridge.rubber, cribbage.six-card; variants chicago, duplicate, canadian-loner, five-card. All validate clean; all pass 500-seed random-legal simulation with termination/conservation/scoring invariants (P3.3, `e43f076`).
- **Rules documents (`docs/rules/RULES-*.md`):** original prose per game, every rule ID cross-checked both ways by `make rules-check` (54/54).
- **Conformance (`docs/CONFORMANCE.md`):** 100% rule-ID coverage per game from stacked-deck suites (hearts 12/12, euchre 14/14, bridge 16/16, cribbage 12/12); deterministic deal override is host-only SPI (ADR-0037).
- **Golden replays:** 20 per game × 4 games, finalStateHash matches on macOS and iOS simulator.
- **Redaction:** game-specific suites (2,000 deals per game): Hearts pass knowledge, Euchre up-card/discard, bridge dummy pre/post opening lead, cribbage crib pre-show — **0 leaks** (ADR-0038 zone-visibility grants land in the engine).
- **Dev play UI (P3.7, `App/`):** launcher (`ParlorApp`) → dev play screen (`DevPlayView` + `PlaySession`): pass-and-play with a random-legal bot per empty seat, event log, observation zones, legal intents as buttons (`intent_N`), violation text for illegal taps. **XCUITest plays one full deal of each of the four games to completion on the iPad simulator** (110 s; screenshots in `docs/screenshots/`).
- **Per-package:** CardModel (decks/seats/faces), CardExpr (lexer/parser/evaluator, 100% coverage), SeededRNG (xoshiro256**), GameLibrary (catalogue), plus placeholders per P0/P1 plan.

## 3. What does not

See `docs/KNOWN_ISSUES.md`. Summary:

- **KI-1 (major, P0):** macOS UI-test leg is carved out of the gate (ADR-0022) pending a one-time interactive TCC approval on the build host; macOS unit tests and both iOS UI legs pass. Hard requirement again from G9.
- The dev play screen is intentionally plain (P3.7); the real table UI is P4.1–P4.3. No bots beyond random-legal (P4.9), no saves (P4.5), no networking (P8), no library UI (P5).
- `rules-cli sim` currently simulates the toy fixture only (`make sim N=200`); per-game 500-seed simulation ran through the RulesetKit test harness at P3.3 (evidence in `docs/STATUS.md`), not via the CLI target.

## 4. Architecture deltas

`docs/DECISIONS.md` has 39 ADRs; all are deltas from `docs/plan/ARCHITECTURE.md` and remain in force. The ones added since the last handoff (G1):

- ADR-0025 `rummy.melds` field semantics (P2.4) · ADR-0026 DSL baked engine config (P2) · ADR-0027–0029 validation, canonical var access, overlay ordering (P2) · ADR-0030 `trick.number` is 1-based (P3.3) · ADR-0031–0036 mechanic contracts pinned by the four games (P3.3) · ADR-0037 stacked-deck conformance override is host-only SPI (P3.4) · ADR-0038 zone visibility = knowledge grants at card entry (P3.6) · **ADR-0039 the app's host side (`App/Shared/`) may use the HostOnly SPI — the app is a host process like rules-cli; the view layer still consumes `Observation` only** (P3.7).

Code deviations to know: `check-imports` allow-list now includes `App/Shared/*` for `@_spi(HostOnly)` (per ADR-0039); `make gate PHASE=P3` case added; `coverage-check` merges the RulesetKit test binary into the engine measurement (the engine's real exercisers live there — see `docs/STATUS.md` §G3).

## 5. Fragile areas

- **Golden-replay hashes** (`Packages/*/Tests/Fixtures/Replays/*.json`): any change to serialized engine state (canonical Codable, RNG JSON keys `s0`–`s3`) breaks 80 fixtures. Regenerate with `Tools/make-golden-replays.sh` and justify the hash change in `docs/STATUS.md`. Guard: `GameReplayTests` (macOS + iOS legs).
- **Redaction** (`Knowledge`, `Redactor`, `Engine.observation`, zone-entry grants ADR-0038): monotone knowledge is the single security boundary; the event-log deal-boundary marking (`firstDealEvent`, `Engine+Match.swift`) is subtle — a stale `.cardPlayed` from the previous deal can leak a reassigned face. Guard: redaction suites (2,000 deals/game) + `observationByteScanNoHiddenFaces`.
- **`pendingSeats` ↔ `legalIntents` ↔ `apply` mirroring:** every mechanic must keep the three consistent — a pending seat with empty legals parks a bot lane forever (the P3.7 hang: claim voters that had already voted). Guard: `pendingClaimWaitsOnlyOnUnvotedVoters`, `DevSessionBotLaneTests` (one full deal per game, euchre seeds 1–64).
- **`@_spi(HostOnly)`** is load-bearing: UI code must never see `GameState`. Guard: `Tools/check-imports.sh` (fails CI); ADR-0039 scopes the app exception to `App/Shared/`.
- **Typed `catch` in tests crashes Swift 6.3.3** (SILGenCleanup, CI): keep the untyped-catch + downcast pattern used in `ConformanceRunner` (see `c03249e`).
- **Makefile sim selection:** `$(if)` sees the string `0` as truthy (GNU Make 3.81); gate on `SIM_LOCK` directly, never a `SIM_LOCKED=0` intermediate (CI run 45243709233).

## 6. Rule decisions

Every ambiguity met during P0–P3 is logged in `docs/OPEN_QUESTIONS.md` (13 entries) with the default applied; none blocks play. Highlights a rules reviewer should sanity-check (full list in the G3 request):

- Hearts: passing schedule left/right/across/hold (3 cards); no points on the first trick (`noPointsFirstTrick` on, including the queen); hearts must be broken before being led (`breakingHearts` on) and the queen of spades breaks them too (`queenBreaksHearts` on); moon = +26 to others (`addToOthers`, jack of diamonds −10 variant off); game to 100.
- Euchre: stick-the-dealer **off** by default; going alone on (lone march = `alonePoints` 4, three-or-four tricks = 1); a euchred maker gives the defenders 2; three-or-four tricks = 1, five tricks = 2; match to 10; bowers follow trump; after a lone declaration the partner sits out and the lead skips them.
- Bridge: honors scoring on; a passed-out deal is re-dealt by the next dealer (`passOut: redealNextDealer`); claims by declarer on, defenders accept; rubber bonus 700/500 per RULES-contract-bridge.
- Cribbage: game to 121, skunks on (loser under 91 in a 121 game), muggins off, manual counting off; continuous scoring (win mid-show ends the match, crib unrevealed); five-card flush in the crib only; his heels 2.

## 7. Metrics

- **Coverage** (`docs/COVERAGE.md`, gate summary `reports/coverage/summary.txt`): CardExpr **100.0%**, CardModel **94.7%**, RulesEngine **92.3%** (RulesetKit binary merged; 84.6% from the engine package alone — measurement note in STATUS), ToyGame 96.5%, RulesetKit 86.8% (threshold 70%), overall ~89%.
- **Conformance:** 54/54 rule IDs covered, `docs/CONFORMANCE.md` all pass, 20 golden replays per game all match.
- **Redaction:** 0 leaks over 2,000 deals × 4 games (>100,000 byte-scan checks per suite).
- **Simulation:** 8 rulesets × 500 seeds clean (P3.3); `make sim N=200` clean.
- **Perf** (`docs/PERF.md`): apply p99 10.8 µs (budget 1 ms), observation p99 13.4 µs (budget 0.5 ms) on the host Mac; the XCTest budgets scale ×5 on shared CI runners (ADR-0040 — run 45560935986 measured 597 µs on a throttled runner). Real-game/device numbers are P4.10.
- **UI:** dev play full-deal UI test 110 s on iPad; app-launch smoke green on iPhone and iPad.
- **Lint:** `make lint` exit 0 (SwiftLint warnings advisory; swift-format strict; check-imports OK).

## 8. Next steps

1. **P3.8 (this package):** reviewers follow `docs/reviews/G3-REQUEST.md`; sign-offs recorded in `docs/STATUS.md` as `REVIEW: CLAUDE`, `REVIEW: GROK`, `REVIEW: MAHLER`.
2. **P4.0:** close every review finding or convert it to an ADR; findings list in `docs/STATUS.md` all marked closed.
3. **P4.1:** `TableUI` foundation — `CardView` (vector faces from `Resources/Decks/`), `HandView` (Fan/Rows/Grid), `TrickView`, `TableView` layouts, matched-geometry motion; snapshot tests at the five device sizes.

Prerequisites from reviewers: the three G3 sign-offs; nothing else.

## 9. How to verify (10-minute reviewer script)

1. `git clone https://github.com/Zyniker13/Geist3 && cd Geist3 && git checkout phase/P3-first-four-games` (or use the existing checkout).
2. `make bootstrap` (~1 min) — prints the toolchain versions.
3. `make lint` (~2 min) — must exit 0.
4. `make validate && make conformance && make rules-check` (~2 min) — "61 passed", "all declared rule ids covered", four "ok" lines.
5. `make sim N=200` (~1 min) — "200 seeds … repeat-seed reproducible".
6. Open `Parlor.xcodeproj`, run the `Parlor-iOS` scheme on an iPad simulator (~4 min): tap each of the four games, play a few legal moves via the `Play #…` buttons, tap an illegal move (a red explanation appears), Back, next game.
7. Full check (optional, ~40 min): `make gate PHASE=P3`.
