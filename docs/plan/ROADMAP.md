# Roadmap: Phases, Tasks, and Gates

Version 1.0 · 2026-11-15 · The work order for Parlor. Read `CONVENTIONS.md` and `ARCHITECTURE.md` first.

Contents: §0 Product Framing · §1 Phase Map and Gate Summary · §2 Phases P0–P16 · §3 Test Strategy · §4 Risks · §5 Out of Scope · §6 Effort Estimates · §7 Engine Feature Triage · §8 Open Questions for Mahler (with Defaults)

---

## 0. Product Framing

### 0.1 Vision

One app that does for traditional card games what a good reference library, a patient teacher, and a well-run card table do together: look a game up, learn it by playing, and play it with the people in the room, each holding their hand on their own device.

### 0.2 Design Persona

**Ruth and Walter, 84 and 86,** played duplicate bridge for forty years. Walter's arthritis makes holding and fanning thirteen cards painful; Ruth's macular degeneration makes pips hard to read. Their grandson visits with his phone and wants to play Euchre. Every phase's acceptance criteria assume that Ruth and Walter must be able to set up a four-handed bridge game with an iPad on the table and two iPads as hands, without help, in under three minutes, and play a rubber without anyone touching a card they did not mean to play.

Secondary personas: a family on a road trip with no table (phones only, peer-to-peer Wi-Fi); a curious player exploring Skat from the catalogue; a club teacher running a beginner bridge lesson; a VoiceOver user playing Hearts.

### 0.3 Working Title

| Name | For | Against |
| --- | --- | --- |
| **Parlor** (recommended) | Warm, traditional, short; suggests a room where card games are played; works as a module and URL scheme name | Common word; needs a trademark and App Store name search (Mahler) |
| **Common Deck** | Says "every game, one deck"; friendly | Sounds like a utility; weaker for a teaching aid |
| **Long Table** | Evokes family gatherings and the shared-table feature | Less obviously about cards |

"Card Table" is avoided because **The Card Table** is an existing App Store app with the same hand-on-phone concept (`RESEARCH.md` S42). All code uses the placeholder `Parlor`; renaming later touches only display strings and bundle metadata.

### 0.4 Release Scope (Default)

Version 1.0 ships: Wave 1 (10 games) and Wave 2 (14 games) fully playable, Wave 3 tranche A (Skat, Belote, French Tarot, Briscola, Scopa) playable, the full catalogue browsable with rulebook entries for every Wave 1–3 game, local multi-device play, the iPad and Mac table, the house-rules editor (Tiers 1 and 2; Tier 3 marked beta), online play through Game Center, and the accessibility features in `ARCHITECTURE.md` §16. Apple TV ships in 1.0 if G13 passes in time, otherwise in 1.1.

---

## 1. Phase Map and Gate Summary

```mermaid
flowchart LR
  P0[P0 Setup] --> P1[P1 Engine Core] --> P2[P2 Ruleset DSL] --> P3[P3 First Four Games]
  P3 -->|🛑 G3| P4[P4 Single-Device Play + Wave 1]
  P4 --> P5[P5 Library and Rulebook] --> P6[P6 AI Opponents] --> P7[P7 Teaching]
  P7 --> P8[P8 Local Multi-Device]
  P8 -->|🛑 G8| P9[P9 iPad and Mac Table] --> P10[P10 Accessibility and Comfort] --> P11[P11 Waves 2 and 3A]
  P11 -->|🛑 G11 final GLM stop| P12[P12 Custom Rules Editor]
  P12 --> P13[P13 Apple TV] --> P14[P14 Online Play] --> P15[P15 Beta] --> P16[P16 Release]
```

| Phase | Name | Owner | Gate | Sign-Off | Effort (ED) |
| --- | --- | --- | --- | --- | --- |
| P0 | Setup and Tooling | GLM | G0 | GLM-SELF | 4 |
| P1 | Card Model and Engine Core | GLM | G1 | GLM-SELF; ASYNC REVIEW: CLAUDE (API) | 14 |
| P2 | Ruleset DSL, CardExpr, Overlays, Validator | GLM | G2 | GLM-SELF; ASYNC REVIEW: CLAUDE | 16 |
| P3 | First Four Games (Hearts, Euchre, Bridge, Cribbage) | GLM | G3 | **🛑 GLM STOP 1:** REVIEW: CLAUDE + GROK + MAHLER | 20 |
| P4 | Single-Device Play and Wave 1 Completion | GLM | G4 | GLM-SELF; ASYNC REVIEW: GROK (rules) | 24 |
| P5 | Library, Catalogue, and Rulebook | GLM | G5 | GLM-SELF; ASYNC REVIEW: GROK (prose and originality) | 12 |
| P6 | AI Opponents | GLM | G6 | GLM-SELF; ASYNC REVIEW: GROK (strength and feel) | 22 |
| P7 | Teaching: Lessons, Coach, Trainers, Review | GLM | G7 | GLM-SELF; ASYNC REVIEW: GROK (pedagogy) | 16 |
| P8 | Local Multi-Device Hand Mode | GLM | G8 | **🛑 GLM STOP 2:** REVIEW: CLAUDE (security) + MAHLER (real devices) | 20 |
| P9 | iPad Table Surface and Mac Table | GLM | G9 | GLM-SELF; ASYNC REVIEW: GROK (UX) | 10 |
| P10 | Accessibility and Comfort | GLM | G10 | GLM-SELF; ASYNC REVIEW: CLAUDE (accessibility) | 12 |
| P11 | Game Waves 2 and 3A | GLM | G11 | **🛑 GLM FINAL STOP:** REVIEW: CLAUDE + GROK + MAHLER | 45 |
| P12 | Custom Rules Editor (Tiers 1–3) | CLAUDE + GROK | G12 | REVIEW: GROK + MAHLER; CLAUDE security | 24 |
| P13 | Apple TV | CLAUDE | G13 | REVIEW: GROK + MAHLER | 10 |
| P14 | Online Play (Game Center, SharePlay) | CLAUDE | G14 | REVIEW: CLAUDE security + MAHLER | 18 |
| P15 | Beta (TestFlight) | GROK + CLAUDE | G15 | REVIEW: MAHLER (go/no-go) | 15 |
| P16 | Release | CLAUDE + GROK | G16 | MAHLER (Mahler submits) | 6 |
| | **Total** | | | | **288** (range 228–394) |

GLM's share (P0–P11): about 215 ED. See §6 for ranges and assumptions.

---

## 2. Phases

Task notation: **Pn.k Title** · *Deliverable:* what exists when done · *Accept:* objective criteria. Every phase also includes the standard closing task **Pn.Z Gate Run** (run `make gate PHASE=Pn`, record evidence in `docs/STATUS.md`, update `docs/HANDOFF.md` sections 1–3 and 7, tag on pass).

### P0. Setup and Tooling (GLM · 4 ED)

**Goal:** an empty but complete, green, multi-platform project that enforces every convention from the first commit.

- **P0.1 Repository bootstrap.** *Deliverable:* repo layout from `CONVENTIONS.md` §3; `docs/plan/` contains this package verbatim; `docs/` skeleton files (STATUS, DECISIONS, KNOWN_ISSUES, TODO_MAP, OPEN_QUESTIONS, COVERAGE, CONFORMANCE, PERF, SECURITY, ACCESSIBILITY, HANDOFF). *Accept:* `tree -L 2` matches §3; every doc file has a title and purpose line.
- **P0.2 XcodeGen project.** *Deliverable:* `project.yml` with `Parlor-iOS` (iPhone and iPad), `Parlor-macOS`, unit and UI test targets, all 13 local packages wired, bundle ID placeholder `com.zyniker.parlor`, deployment targets 26.0, Swift 6 strict concurrency. *Accept:* `make gen && make build` succeeds for both platforms with zero warnings.
- **P0.3 Packages.** *Deliverable:* 13 SPM packages with `Package.swift`, one placeholder type, and one passing Swift Testing test each. *Accept:* `swift test` passes in each package.
- **P0.4 Tooling.** *Deliverable:* `Makefile` targets (`bootstrap`, `gen`, `build`, `test`, `lint`, `format`, `validate`, `conformance`, `sim`, `fuzz-quick`, `snapshot`, `coverage`, `perf`, `gate`), SwiftLint with custom rules (banned APIs from `CONVENTIONS.md` §5.4 in pure packages), swift-format, `Tools/check-imports.sh` (dependency direction and `@_spi(HostOnly)` allow-list), and `Tools/rules-cli` stub. *Accept:* a deliberately bad commit on a scratch branch (`Date()` in `RulesEngine`, `import SwiftUI` in `CardAI`, `@_spi(HostOnly) import RulesEngine` in `TableUI`) fails lint or import checks; reverted.
- **P0.5 CI.** *Deliverable:* `.github/workflows/ci.yml` per `CONVENTIONS.md` §7 (steps that have nothing to run yet succeed as no-ops with a printed notice). *Accept:* green CI run on `main`; artifacts uploaded.
- **P0.6 ADRs.** *Deliverable:* ADR-0001 (toolchain, exact Xcode and Swift versions) and ADR-0002 through ADR-0020 transcribed from `ARCHITECTURE.md` §21. *Accept:* `docs/DECISIONS.md` lists 20 ADRs with status Accepted.
- **P0.7 Competitor test sheet.** *Deliverable:* `docs/research/COMPETITORS.md`: a structured checklist (setup steps, time-to-first-card, tap counts, accessibility audit notes, network behavior) for The Card Table, Stillwind Table, Play Table, Trickster, BBO, Funbridge, Card Shark, and Accessible Solitaire, to be filled by Mahler or a reviewer on real devices. GLM does not install apps or create accounts. *Accept:* the sheet exists with blank columns and instructions.

**G0 (GLM-SELF):** CI green on both platforms; lint and import checks proven to fail on violations; 20 ADRs recorded; `make gate PHASE=P0` exits 0.

### P1. Card Model and Engine Core (GLM · 14 ED)

**Goal:** a deterministic, redacting game engine that can run a hard-coded toy game (a two-player "High Card Trick" with five tricks) end to end in tests.

- **P1.1 CardModel.** *Deliverable:* `Suit`, `Rank`, `CardFace`, `CardID`, `SuitSystem`, `DeckSpec`, `DeckCatalog` with every deck ID in `ARCHITECTURE.md` §4.2, `Seat`, `Team`, `SeatSet` (bitset). *Accept:* deck sizes and contents tested for every deck ID; `CardFace` IDs round-trip through Codable; duplicate decks produce distinct instances.
- **P1.2 SeededRNG.** *Deliverable:* xoshiro256** with SplitMix64 seeding, Lemire bounded integers, Fisher–Yates shuffle, `Codable` state. *Accept:* published xoshiro256** reference vectors match; 10,000-shuffle chi-square uniformity test on a 10-card deck passes at p > 0.001; serialization round-trips preserve the stream.
- **P1.3 State and zones.** *Deliverable:* `GameState` (`@_spi(HostOnly)`), `ZoneStore`, `KnowledgeStore`, `VarStore`, `PhaseCursor`, version counter. *Accept:* card conservation invariant (every instance in exactly one zone) enforced by `ZoneStore.move` and tested; `GameState` Hashable is order-stable.
- **P1.4 Reducer skeleton.** *Deliverable:* `Engine.start`, `apply`, `legalIntents`, `Transition`, `GameEvent`, `RuleViolation` with rule IDs; mechanic protocol (`ARCHITECTURE.md` §5.6) and the `deal` and `trick-play` mechanics in a minimal Swift-configured form (no JSON yet). *Accept:* the toy game plays to completion with random legal intents for 10,000 seeds; no crash; every illegal intent rejected with a rule ID.
- **P1.5 Card instance IDs.** *Deliverable:* post-shuffle ID assignment per deal. *Accept:* test proves `CardID` is independent of face across 1,000 deals (no face has the same ID more than chance permits: max frequency below 3× expectation).
- **P1.6 Observation and Redactor.** *Deliverable:* `Observation`, `ObservedZone`, `Viewer`, `Redactor`, event redaction. *Accept:* property test over 2,000 toy games: for every step and every viewer, the JSON encoding of the observation contains no face unknown to that viewer (search the encoded bytes for every hidden face's ID string); hidden zones expose counts only.
- **P1.7 Replays.** *Deliverable:* `Replay` type, `Engine.replay`, final-state SHA-256. *Accept:* 20 golden toy replays stored; hashes identical on macOS and iOS simulator in CI.
- **P1.8 Performance harness.** *Deliverable:* XCTest `measure` for `apply` and `observation`. *Accept:* p99 `apply` < 1 ms and observation < 0.5 ms on the CI Mac (record; device numbers come in P4).

**G1 (GLM-SELF; ASYNC REVIEW: CLAUDE on engine API):** coverage ≥ 90% in CardModel and RulesEngine; RNG vectors pass; 0 redaction leaks; 20 golden replays match cross-platform; banned-API lint clean.

### P2. Ruleset DSL, CardExpr, Overlays, and Validator (GLM · 16 ED)

**Goal:** rulesets load from JSON, expressions evaluate safely, overlays resolve with provenance, and the validator catches every error class in `ARCHITECTURE.md` §11.4.

- **P2.1 CardExpr lexer and parser.** *Deliverable:* Pratt parser for the grammar in `ARCHITECTURE.md` §7.1 with source positions. *Accept:* 300+ parser tests including precedence, errors with column numbers, and a fuzz test (10,000 random strings never crash; parse time linear).
- **P2.2 Type checker.** *Deliverable:* types from §7.2, contextual bindings, defs with signatures, optional types, `hostOnly` builtin marking. *Accept:* every builtin and macro has positive and negative type tests; recursive defs rejected; `hostOnly` builtins rejected in AI and UI evaluation contexts.
- **P2.3 Evaluator and fuel.** *Deliverable:* tree-walking evaluator, `Value`, checked integer arithmetic, fuel budgets (§7.4), constant folding, compiled-expression cache. *Accept:* property tests (evaluation deterministic; fuel exhaustion raises a fault rather than hanging; overflow and division by zero raise faults); median 1 µs for `leadAllowed`-sized expressions on CI Mac.
- **P2.4 Native functions.** *Deliverable:* registry and the Wave 1 functions `cribbage.handScore`, `cribbage.pegPoints`, `bridge.score`, `bridge.honors`, `rummy.melds`. *Accept:* table-driven tests: the American Cribbage Congress scoring examples plus 500 hand-computed cases (including 29, 28, 24, and zero hands); every row of rubber bridge scoring for undoubled, doubled, redoubled, vulnerable, and slam cases; rummy meld optimality versus brute force on 10,000 random 10- and 11-card hands.
- **P2.5 Schema types and loader.** *Deliverable:* `RulesetDocument`, `OverlayDocument`, `Phase` with typed mechanic params (each mechanic's `Params` is `Codable`), localizable `Text`, and the effect language (§5.7). *Accept:* the four reference files in `docs/plan/rulesets/` decode without loss (decode → encode → decode is identical in canonical form).
- **P2.6 Resolver.** *Deliverable:* `Resolver` implementing §8 (layers, ID-addressed patch ops, locked paths, canonicalization, SHA-256 hash, provenance map) and `RulesDiff`. *Accept:* the Chicago overlay resolves onto rubber bridge; the Hearts house example resolves; patch conflicts, numeric indexes, locked paths, and version mismatches produce the specified errors; hash stable across runs and platforms.
- **P2.7 Validator.** *Deliverable:* `RulesetValidator` stages B–F (§11.4) with plain-language messages, limits (§11.3), and JSON-pointer locations; `rules-cli validate` and `rules-cli fmt`. *Accept:* a corpus of 60 intentionally broken rulesets (10 per error class: schema, reference, type, reachability, termination, fallback) each yields the expected error code and message.
- **P2.8 Simulator.** *Deliverable:* `Simulator` (random-legal and bot-pluggable runs, invariant checks, stall and nontermination detection, rule-ID exercise report) and `rules-cli simulate`. *Accept:* runs the toy game from JSON for 500 seeds in under 5 s on the CI Mac; seeded runs reproducible.
- **P2.9 JSON Schema export.** *Deliverable:* `Resources/Schemas/ruleset.schema.json` and `lesson.schema.json` generated from the Swift types by a tool. *Accept:* the four reference rulesets validate against it with a standard validator in CI (Python `jsonschema`, CI-only tool dependency).

Note on P2.4: cribbage scoring is also checked against an independent brute-force scorer written separately in the test target; the two implementations must agree on 100,000 random hands.

**G2 (GLM-SELF; ASYNC REVIEW: CLAUDE):** CardExpr coverage ≥ 95%; validator corpus 60/60; resolver tests pass; four reference rulesets decode and validate (mechanic implementations may still be stubs for P3, so simulation of them is not yet required).

### P3. First Four Games: Hearts, Euchre, Contract Bridge, Cribbage (GLM · 20 ED) · 🛑 GLM STOP 1

**Goal:** prove that the data-driven engine can express four structurally different games correctly, with conformance suites, and that a human can play them on an iPad in a plain development UI.

- **P3.1 Mechanics for the four games.** *Deliverable:* JSON-configured implementations of `deal`, `auction.ladder`, `auction.rounds`, `exchange.pass`, `exchange.kitty`, `exchange.discardTo`, `reveal.starter`, `trick-play` (with `suitOf`, `strength`, `activeSeats`, `dummy`, `claims`), `count-play`, `show`, `score`. *Accept:* each mechanic has unit tests for every parameter, including invalid-parameter validation.
- **P3.2 Rules documents.** *Deliverable:* `docs/rules/RULES-hearts.md`, `RULES-euchre.md`, `RULES-contract-bridge.md`, `RULES-cribbage.md`: numbered rules matching the rulesets' rule IDs, every rule with its source citation and any ambiguity resolved with a default (logged in `docs/OPEN_QUESTIONS.md`). *Accept:* every rule ID in each ruleset appears in its document and vice versa.
- **P3.3 Rulesets.** *Deliverable:* the four reference rulesets in `Resources/Rulesets/`, fixed only for schema-level slips (any meaning change logged with reason), plus variants: `contract-bridge.chicago`, `contract-bridge.duplicate`, `euchre.canadian-loner`, `cribbage.five-card`. *Accept:* `rules-cli validate` clean; 500-game simulations pass for all eight.
- **P3.4 Conformance suites.** *Deliverable:* per game, tagged Swift Testing suites from stacked decks: every rule ID ≥ 1 test; Hearts (passing directions over four deals, two of clubs lead, broken hearts edge cases, first-trick fallback when holding only points, moon with and without jack of diamonds); Euchre (bowers in follow and in winning, order-up and dealer discard, going alone with partner skipped and lead adjustment, stick the dealer, all scoring tiers); Bridge (auction sufficiency, double and redouble legality, declarer determination, passed-out deal, dummy reveal timing, declarer controlling dummy, claims, every rubber scoring path including honors, rubber bonus 700 and 500); Cribbage (crib ownership, his heels, pegging go and 31 and last card, pairs royal, runs across pegging, show order, continuous win mid-show, five-card flush in crib only, skunk). *Accept:* 100% rule IDs covered; scoring tables checked against hand-built expectations; `docs/CONFORMANCE.md` generated.
- **P3.5 Golden replays.** *Deliverable:* 20 per game. *Accept:* cross-platform hash match.
- **P3.6 Redaction suites.** *Deliverable:* game-specific redaction property tests (2,000 games each) including Hearts pass knowledge, Euchre up-card and discard, bridge dummy before and after the opening lead, and the cribbage crib before the show. *Accept:* 0 leaks.
- **P3.7 Development play UI.** *Deliverable:* a plain SwiftUI screen (not the final design) that runs any ruleset in pass-and-play with a random-legal bot for empty seats, shows the observation for the current seat, lists legal intents as buttons, and shows explanations for illegal taps. *Accept:* XCUITest plays one full deal of each game to completion on the iPad simulator.
- **P3.8 Review package.** *Deliverable:* `docs/HANDOFF.md` complete (`CONVENTIONS.md` §10) plus `docs/reviews/G3-REQUEST.md`: how to run, what to check, the four rules documents, known gaps, and a list of every rule default chosen. *Accept:* a reviewer can follow it without asking questions (self-check: every command in it runs).

**G3 (🛑 GLM STOP 1):** automated: all P1–P3 checks, conformance 100%, 0 redaction leaks, golden replays match, simulations clean. Reviews: `REVIEW: CLAUDE` (engine and DSL architecture: is the mechanics library general enough for Waves 2–3, are expressions readable, is redaction structurally sound), `REVIEW: GROK` (rules correctness of the four games against sources, defaults sensible), `REVIEW: MAHLER` (plays at least one deal of each on an iPad; confirms the rules feel right). GLM resumes only when all three PASS entries are recorded. Expected review fixes are scheduled as P4.0.

### P4. Single-Device Play and Wave 1 Completion (GLM · 24 ED)

**Goal:** the real game UI for solo and pass-and-play, and all ten Wave 1 games playable on one device.

- **P4.0 G3 review fixes.** *Deliverable:* every finding closed or converted to an ADR. *Accept:* findings list in `docs/STATUS.md` all marked closed.
- **P4.1 TableUI foundation.** *Deliverable:* `CardView` (vector faces from `Resources/Decks/`, standard and four-color packs initially, back designs), `HandView` (Fan, Rows, Grid density modes; grouping by suit; legal raise and illegal dim), `TrickView`, `SeatBadge`, `ScoreSheetView`, `AuctionBoxView`, `TableView` layouts (`fourAround`, `fourAroundPartners`, `bridgeCompass`, `headToHead`), matched-geometry card motion. *Accept:* snapshot tests at the five device sizes in light, dark, and the largest Dynamic Type; 120 fps scroll and play animation on iPad Pro in Instruments (recorded).
- **P4.2 Interaction model.** *Deliverable:* tap-to-select then Play button or second tap; optional one-tap play; optional drag; double-tap guard; "Why not?" sheet for illegal cards; bid grid; prompts as large buttons. *Accept:* UI tests cover each interaction; no gesture is required that lacks a tap alternative (checked by a UI-test script that completes a full deal of each game with taps only).
- **P4.3 Game flow screens.** *Deliverable:* New Game sheet (game, ruleset, variant, players, seats, bots, table options), in-game menu (Rules in Effect, Score Sheet, Last Trick, Pause, Quit, Save), deal-end and match-end summaries with score breakdown by rule. *Accept:* XCUITest: library → new game → finish a deal → summary for each Wave 1 game.
- **P4.4 Pass-and-play.** *Deliverable:* privacy curtain, "Show my hand," optional flip-to-reveal and peek protection (`ARCHITECTURE.md` §12.6). *Accept:* UI test proves the next player's hand is not rendered (no card accessibility elements present) until reveal.
- **P4.5 Saves.** *Deliverable:* `SaveStore` autosave after every action, resume, multiple saved tables, file protection. *Accept:* kill-and-relaunch test resumes the exact state (hash match) for each game.
- **P4.6 Remaining Wave 1 mechanics.** *Deliverable:* `auction.individual` (Spades with nil and blind nil; Oh Hell hook kept for Wave 2), `draw-discard` (Gin: knock, gin, undercut, layoff, big gin option), `shed.match` (Crazy Eights), `ask` (Go Fish), `patience` (Klondike draw 1 and 3, FreeCell with Microsoft deal numbers, auto-move to foundations, unlimited undo in solo). *Accept:* mechanic unit tests; patience solver-backed test that 1,000 known-solvable FreeCell deals are solved by the built-in solver (the solver is also used for hints in P7).
- **P4.7 Remaining Wave 1 rulesets and conformance.** *Deliverable:* rulesets, `RULES-*.md`, conformance suites, 20 golden replays, and redaction suites for Spades, Gin Rummy, Crazy Eights, Go Fish, Klondike, and FreeCell, plus variants `spades.joker`, `gin.oklahoma`, `klondike.vegas-scoring-display` (points only, no wagering language). *Accept:* the same criteria as P3.4–P3.6 for each game.
- **P4.8 Patience layout.** *Deliverable:* `patienceTableau` layout with tap-to-move (tap a card, tap a destination; or tap a card to auto-move to its best destination), drag optional, large-target mode. *Accept:* full Klondike and FreeCell games completed in UI tests by taps only.
- **P4.9 Placeholder bots.** *Deliverable:* `Bot` protocol and a `RandomLegalBot` plus simple per-family heuristics (so solo play is possible before P6). *Accept:* bots use only `Observation` (compile-time, by SPI).
- **P4.10 Device performance.** *Deliverable:* `docs/PERF.md` entries on iPad (A16) and iPhone 15 (or the closest available simulators with a note; real devices are measured by Mahler's reviewer when available). *Accept:* budgets from `CONVENTIONS.md` §8 for reducer, cold start, and animation are met or logged as known issues with a plan.

**G4 (GLM-SELF; ASYNC REVIEW: GROK on the six new games' rules):** all ten Wave 1 games pass conformance, golden replays, redaction, and simulation; UI tests complete a deal of every game with taps only; snapshot suite reviewed; saves resume exactly.

### P5. Library, Catalogue, and Rulebook (GLM · 12 ED)

**Goal:** the app's front door: browse every catalogued game, read original rulebooks, compare variants, and start a game from any page.

- **P5.1 Catalogue data.** *Deliverable:* `GameLibrary/Catalogue.json` with every entry in `CATALOGUE.md` (metadata per §5 of that file), capability badges (Read, Learn, Play, Bots, Local, Online), and source IDs. *Accept:* `rules-cli validate` checks catalogue integrity (every playable entry has a ruleset; every source URL is HTTPS).
- **P5.2 Library UI.** *Deliverable:* home with sections (Continue, Favorites, Wave 1 highlights, By Mechanism, By Country, By Deck, By Players), search with aliases, composable filters, and game pages (overview, quick facts, Play, Learn, Rules, Variants, History, Sources). *Accept:* UI tests for search ("casino" finds Cassino), filters (4 players + partnership + French deck), and navigation on iPhone, iPad, and Mac (sidebar on iPad and Mac).
- **P5.3 Rulebook renderer.** *Deliverable:* Markdown rendering (`AttributedString` with a restricted Markdown subset) for `Resources/Rulebook/<game>/*.md`; automatic sections generated from the ruleset (rule list with IDs and text, options with labels and defaults, scoring tables from rule texts, sources with links); glossary links. *Accept:* every Wave 1 game page renders with generated and authored sections; links open with a confirmation; VoiceOver reads headings as headings.
- **P5.4 Rulebook prose for Wave 1.** *Deliverable:* original prose per game: Overview, Objective, Setup and Deal, Play, Scoring (with worked examples), Variants, Etiquette and Table Talk (for example bridge's unauthorized information in plain words), History (short), Glossary. Written for a reader at roughly an eighth-grade level with expert notes collapsed. *Accept:* `REVIEW: GROK` asynchronously; GLM self-checks: no sentence of 12+ words matches any source page (n-gram script against locally fetched source pages, outside the app), each page ≤ 2,500 words excluding glossary.
- **P5.5 Variant compare.** *Deliverable:* `VariantCompareView` using `RulesDiff` ("How Chicago differs from rubber bridge"). *Accept:* renders for every shipped variant.
- **P5.6 House Options sheet (Tier 1).** *Deliverable:* at game setup and in the game page, a sheet listing the ruleset's options grouped and labeled, with "Save as House Rules" (name, optional description) writing a `.house.json` via `HouseRuleStore`; export and import of `.parlorrules` with validation and diff preview. *Accept:* round-trip export → import on another simulator yields the same resolved hash; malformed files produce friendly errors; locked options are disabled with an explanation.
- **P5.7 Catalogue-only pages.** *Deliverable:* for Waves 2–4 entries not yet playable: a page with overview (short original text), facts, deck, players, and sources, marked "Rules coming" with no Play button. *Accept:* no catalogue-only page has a Play button or a broken link.

**G5 (GLM-SELF; ASYNC REVIEW: GROK on prose and originality):** catalogue validates; every Wave 1 rulebook complete; originality script passes; Tier 1 house rules round-trip; UI tests for library flows pass on three platforms.

### P6. AI Opponents (GLM · 22 ED)

**Goal:** fair, explainable bots at four levels for every Wave 1 game, with bridge bidding and play at a solid club-social level.

- **P6.1 Belief and sampling.** *Deliverable:* `BeliefState` (known cards, voids, passes, shown cards, bid meanings), `DealSampler` with hard constraints and importance weights. *Accept:* sampler produces only consistent deals (100,000-sample checks); 52-card sample < 0.2 ms median on CI Mac.
- **P6.2 Search library.** *Deliverable:* `PIMCSearch` (with pluggable perfect-information solver), `ISMCTS` (single-observer), node-count `ThinkBudget`, deterministic under node budgets. *Accept:* identical decisions for identical seeds; time-budget mode respects the budget within 10%.
- **P6.3 Heuristic policy library.** *Deliverable:* per-mechanic heuristics with `Rationale` tags (trick play, passing, bidding estimators, rummy discards, patience). *Accept:* each heuristic has tests on constructed positions with expected choices.
- **P6.4 DDS integration.** *Deliverable:* vendored DDS (pinned commit, Apache-2.0 `LICENSE` and `NOTICE` included, single-threaded build), `BridgeSolver` Swift wrapper (solve a deal, solve a position mid-trick, par). *Accept:* agreement with 1,000 DDS reference results bundled from the DDS test files; p95 full-deal solve < 250 ms on iPhone 15 (or recorded simulator and Mac numbers with a device follow-up).
- **P6.5 Bridge bidding system.** *Deliverable:* `parlor-standard-sayc.bidding.json` and the `BiddingSystem` engine: openings, responses, rebids, notrump structure with Stayman and Jacoby transfers, weak twos, strong 2♣, Blackwood, takeout doubles, simple overcalls and advances, a competitive fallback ("bid what you would with a reasonable partner"), and a meaning string for every call. *Accept:* 300 curated test auctions (opening and response correctness) pass; bot never makes an illegal call; meaning text available for every bot call; `REVIEW: GROK` asynchronously against standard SAYC references.
- **P6.6 Game profiles.** *Deliverable:* AI profiles for all Wave 1 games: `trick.generic` (Hearts with moon awareness), `trick.euchre` (ordering thresholds, alone decisions), `spades` (bid estimator, nil judgment, bag avoidance), `bridge` (bidding system + DDS PIMC play + opening-lead heuristics), `cribbage` (exact discard EV, pegging minimax), `gin` (deadwood tracking, knock thresholds, discard safety), `crazy-eights`, `go-fish` (memory model by level), and patience hint solvers. *Accept:* per profile, 500 bot-vs-bot games without illegal moves, budget violations, or crashes.
- **P6.7 Difficulty ladder.** *Deliverable:* four levels per `ARCHITECTURE.md` §14.4, a nightly ladder tournament (`make ladder`), and a report. *Accept:* Expert beats Casual in ≥ 60% of 1,000 seeded matches (or deals, for bridge measured by IMPs over 200 boards on the same deals) for Hearts, Spades, Euchre, Bridge, Cribbage, and Gin; Beginner loses to Casual ≥ 60%.
- **P6.8 Bot pacing and presentation.** *Deliverable:* artificial think pauses, bot "personality" names (neutral, no celebrity likenesses), and optional "Show bot's reason" in solo games. *Accept:* settings honored; reasons display for Skilled and Expert decisions.

**G6 (GLM-SELF; ASYNC REVIEW: GROK on strength and feel):** 0 illegal bot actions across all soak runs; ladder holds; budgets met on CI Mac and recorded for devices; DDS agreement 100%; bidding test suite 300/300.

### P7. Teaching: Lessons, Coach, Trainers, and Review (GLM · 16 ED)

**Goal:** a new player can learn any Wave 1 game inside the app, and an experienced player can improve.

- **P7.1 Lesson engine.** *Deliverable:* `Lesson` model (`ARCHITECTURE.md` §15.2), validator, `LessonRunner` (stacked deals, scripted or bot seats, steps with `say`, `expect`, `highlight`, `auto`, `onOther`), progress tracking, and resume. *Accept:* lesson validator rejects incomplete deals, unreachable expectations, and mismatched rulesets; runner tests for each step type.
- **P7.2 Wave 1 lessons.** *Deliverable:* 3–6 lessons per Wave 1 game (about 40 total) with original text. *Accept:* every lesson completes in an automated run using its expected intents; every lesson also completes when the learner takes the `onOther` path; `REVIEW: GROK` asynchronously.
- **P7.3 Coach and explanations.** *Deliverable:* `Explainer` (legality explanations from rule IDs and violation details), `HintEngine` (nudge, highlight, explain from bot rationale), "What does that bid mean?" from the bidding system, table setting for hints. *Accept:* every rule ID in Wave 1 has an `explain` string and a tested explanation path; hints never reveal hidden information (redaction tests extended to hint payloads).
- **P7.4 Trainers.** *Deliverable:* bridge bidding trainer (generated hands by constraint, compare to system, explain), bridge declarer-play problems (curated, DDS-verified), cribbage discard trainer (EV ranking with percent of best) and counting drill, euchre order-up trainer, hearts passing trainer, spades bid estimator, gin knock trainer. *Accept:* each trainer has 50+ generated or curated items, scoring, streaks, and stats persistence.
- **P7.5 Post-deal review.** *Deliverable:* replay any finished deal (step through with all hands visible), key moments (largest evaluation swings by the bot evaluator), and for bridge the double-dummy par and per-card trick cost, labeled "all-cards-visible analysis." *Accept:* review available for every Wave 1 game; bridge review numbers match DDS.
- **P7.6 Interactive rulebook examples.** *Deliverable:* single-step lessons embedded in rulebook pages ("Which card wins?"). *Accept:* at least one per scoring rule in Wave 1.

**G7 (GLM-SELF; ASYNC REVIEW: GROK on pedagogy):** all lessons pass automated runs; trainers populated; hint redaction tests 0 leaks; review screens match engine and DDS results.

### P8. Local Multi-Device Hand Mode (GLM · 20 ED) · 🛑 GLM STOP 2

**Goal:** the headline feature: one host, any mix of hand devices, private hands, shared state of play, robust on real networks.

- **P8.1 Transport layer.** *Deliverable:* `NetworkTransport` on `NetworkListener`/`NetworkBrowser`/`NetworkConnection` with TLS 1.3 and the `Coder` framing (`ARCHITECTURE.md` §12.3), peer-to-peer Wi-Fi enabled, `LoopbackTransport` with identical semantics. *Accept:* integration tests on macOS (two processes) exchange 10,000 messages in order with no loss; loopback and network transports pass the same contract test suite.
- **P8.2 Identity and pairing.** *Deliverable:* per-session P-256 identity with `swift-certificates`, fingerprint pinning, QR join URL, 6-digit channel-bound confirmation, host approval by default ("Let in"), seat tokens in Keychain, `parlor://join` URL handling. *Accept:* tests: wrong fingerprint refused; reused token from another session refused; token theft across devices simulated and refused when the original holder is connected unless the host approves.
- **P8.3 SessionHost and SessionClient.** *Deliverable:* lobby (seats, names, ready, bots for empty seats, game and rules selection by host, Rules in Effect broadcast), per-seat observation streams, intent handling with versions and nonces, prompts, emotes, take-back votes, pause and resume, seed commitment and reveal. *Accept:* four-client simulated sessions (in-process network) play 200 full matches of each Wave 1 multiplayer game with random-legal clients and compare the final state hash with single-device replays of the same actions.
- **P8.4 Hand screen.** *Deliverable:* the hand device UI per `ARCHITECTURE.md` §13.3 (top state-of-play strip, expandable mini table, prompts, hand density modes, dummy display for declarer, "Sitting out" state, turn haptic, lock-screen-safe notifications). *Accept:* snapshot tests on iPhone 6.1" and 6.9" and iPad 11"; VoiceOver reads the state-of-play strip as one summary element plus details.
- **P8.5 Table screen (first version).** *Deliverable:* `Viewer.table` rendering on iPad and Mac with seat names around the table, join QR code, connection status per seat, host controls. *Accept:* table never renders hidden faces (UI test inspects accessibility elements and rendered card IDs).
- **P8.6 Reconnect and presence.** *Deliverable:* behaviors in `ARCHITECTURE.md` §12.5, including bot takeover with consent and host resume after relaunch. *Accept:* scripted tests: drop a client mid-trick and reconnect; background the host for 20 s; kill and relaunch the host; switch a client between Wi-Fi networks; in each case the game resumes with identical state and no duplicated actions.
- **P8.7 Phones-only and mixed configurations.** *Deliverable:* configurations C3, C4, and C5 (`ARCHITECTURE.md` §13.2): host + hand on one iPhone, iPad as hand, touch seat at the table edge. *Accept:* each configuration completes a full Euchre game in a multi-simulator UI test.
- **P8.8 Protocol fuzzing and malicious clients.** *Deliverable:* `Tools/net-fuzz` (mutates, truncates, reorders, duplicates, and floods messages; sends intents for other seats; replays old nonces; sends oversized payloads) and a malicious-client test suite. *Accept:* 30-minute fuzz run with no host crash, no state corruption (invariants checked), no hidden information sent to the wrong seat, and correct disconnects for abusive clients.
- **P8.9 Redaction audit pack.** *Deliverable:* `docs/SECURITY.md` describing every outbound path, the SPI boundary, tests, and fuzz results; a packet capture tool for debug builds that logs every outbound payload per seat for manual inspection. *Accept:* the capture of a complete bridge rubber shows no hidden faces for any seat (automated scan) and is attached to the review request.
- **P8.10 Real-device test script.** *Deliverable:* `docs/reviews/G8-DEVICE-SCRIPT.md`: a 45-minute script for four real devices (one iPad table, two iPhones, one iPad hand) covering setup by a non-technical player, a full rubber of bridge, a Hearts game, Wi-Fi loss, phone lock, and host backgrounding, with a latency measurement procedure. *Accept:* script reviewed by GLM against every P8 acceptance criterion.

**G8 (🛑 GLM STOP 2):** automated: P8.1–P8.9 checks pass; latency p95 < 150 ms on the macOS loopback-over-network test. Reviews: `REVIEW: CLAUDE` (security audit of redaction, transport, pairing, and fuzz results; must read `docs/SECURITY.md` and spot-check captures), `REVIEW: MAHLER` (runs the device script with real devices, ideally with a non-technical player; records latency and setup time). GLM resumes only after both PASS.

### P9. iPad Table Surface and Mac Table (GLM · 10 ED)

**Goal:** the shared table is beautiful, legible across a room, and useful as a touch surface.

- **P9.0 G8 review fixes.** *Accept:* all findings closed.
- **P9.1 Table design pass.** *Deliverable:* felt and wood themes, seat plates with names and turn glow, trick area sized for legibility at 1.5 m on iPad 13" and on a Mac connected to a TV, auction box, score sheets (bridge rubber and Chicago sheets, cribbage board, running scores), last-trick and history drawer. *Accept:* legibility test: card index height ≥ 9 mm on iPad 13" in the trick area (measured from snapshot pixels and device PPI).
- **P9.2 Table orientation and seating.** *Deliverable:* seats arranged relative to physical positions (host drags seat plates to match where people sit), optional "rotate toward current player," landscape and portrait. *Accept:* UI tests for seat arrangement persistence.
- **P9.3 Touch-at-table actions.** *Deliverable:* table-side controls for a touch seat (C5) and for declarer playing dummy from the table; table host menu (pause, settings, rules in effect, end game). *Accept:* a full bridge deal with declarer playing dummy from the table in UI tests.
- **P9.4 Mac specifics.** *Deliverable:* menu commands (New Table, Join, Rules in Effect, Score Sheet), keyboard shortcuts, resizable window and full-screen table mode, pointer hover affordances. *Accept:* macOS UI tests for menus and shortcuts.
- **P9.5 Headless host harness.** *Deliverable:* host runs without any table UI in a test target (prerequisite for tvOS). *Accept:* headless host completes 100 four-client matches in CI.
- **P9.6 Handoff.** *Deliverable:* NSUserActivity for "viewing game X" and "at table Y" so a player can move from Mac to iPad; Handoff never transfers a seat token silently (it opens the Join screen with the table preselected). *Accept:* unit tests for activity payloads; manual check recorded.

**G9 (GLM-SELF; ASYNC REVIEW: GROK on UX):** snapshot suite updated and reviewed; legibility checks pass; headless harness green; Mac UI tests pass.

### P10. Accessibility and Comfort (GLM · 12 ED)

**Goal:** everything in `ARCHITECTURE.md` §16 is complete, tested, and documented.

- **P10.1 Comfort preset and settings.** *Deliverable:* all settings in §16.1 with the one-switch Comfort preset on first run. *Accept:* each setting covered by a UI test that verifies its effect.
- **P10.2 VoiceOver completeness.** *Deliverable:* labels, values, hints, custom actions, rotors (Suits, Playable cards), magic tap summary, narration queue with verbosity levels, announcement priorities. *Accept:* `performAccessibilityAudit()` clean on every screen; scripted VoiceOver test plays a full Hearts deal and a full bridge deal using only accessibility actions (UI test drives `accessibilityActivate` and custom actions).
- **P10.3 Switch Control, Voice Control, and keyboard.** *Deliverable:* grouping, scan order, visible labels for Voice Control, Full Keyboard Access, Mac keyboard play. *Accept:* manual test scripts written in `docs/ACCESSIBILITY.md` and executed on simulator where possible; keyboard-only UI test completes a Euchre game on Mac.
- **P10.4 Vision features.** *Deliverable:* four-color, high-contrast, and jumbo-index face packs; suit letters option; color-independent cues verified with a color-filter snapshot pass (protanopia, deuteranopia, tritanopia, grayscale). *Accept:* snapshots reviewed; every suit distinguishable in grayscale by glyph.
- **P10.5 Motor features.** *Deliverable:* targets ≥ 60 pt in Comfort; spacing ≥ 8 pt; double-tap guard; no-drag guarantee; adjustable timing; auto-play forced moves; undo window in solo. *Accept:* an automated layout audit computes the minimum target size and spacing for every interactive element in Comfort mode on each device size.
- **P10.6 Hearing and cognitive features.** *Deliverable:* visual equivalents for sounds, captions for narration on the table, "What can I do now?" button, Gentle mode. *Accept:* UI tests.
- **P10.7 Privacy of spoken hands.** *Deliverable:* a one-time notice that VoiceOver or narration on a hand device speaks your cards aloud (suggest headphones); the Table Caller voice on the table speaks only public events. *Accept:* test confirms the table narrator never receives `Viewer.seat` observations.
- **P10.8 Accessibility documentation.** *Deliverable:* `docs/ACCESSIBILITY.md` (features, tests, known gaps) and the App Store Accessibility Nutrition Label answers draft for Mahler. *Accept:* every claim maps to a test or a manual script.

**G10 (GLM-SELF; ASYNC REVIEW: CLAUDE on accessibility):** audits clean; scripted VoiceOver and keyboard games complete; layout audit passes; documentation complete. (Human tests with older adults and assistive-technology users happen in P15.)

### P11. Game Waves 2 and 3A (GLM · 45 ED) · 🛑 GLM FINAL STOP

**Goal:** expand to 24 fully playable games plus five regional proof games, proving the engine across duplicate decks, melds, hidden teams, Latin and German suits, and tarot.

Per game, the **game onboarding checklist** (`CATALOGUE.md` §4) is mandatory: source dossier, `RULES-<game>.md`, ruleset, options, variants, conformance (100% rule IDs), 20 golden replays, 500 random-legal and 500 bot simulations, 2,000-game redaction suite, AI profile (generic ISMCTS at minimum; tuned heuristics for the starred games), three lessons, rulebook prose, catalogue badges.

- **P11.1 New mechanics.** *Deliverable:* `auction.raise`, `meld.declare`, `layout.build`, `choose`, `specialCards` for `trick-play` (tarot Excuse), hidden dynamic teams, `capture` (needed for Scopa in 3A), and native functions `pinochle.meld`, `skat.gameValue`, `tarot.contractScore`. *Accept:* unit tests per parameter; validator support.
- **P11.2 Wave 2 games (14):** Spider, Whist, Oh Hell, Bid Whist, Rummy, 500 Rummy, Canasta★, Pinochle★, Double-Deck Pinochle, Sevens (Fan Tan), Golf, President, Durak, Pitch (Setback). *Accept:* onboarding checklist complete for each.
- **P11.3 Wave 3A games (5):** Skat★ (ISkO), Belote★, French Tarot★ (FFT, four players first), Briscola, Scopa. *Accept:* onboarding checklist complete; Skat and Tarot validated against official scoring tables with at least 100 worked deals each.
- **P11.4 Regional face packs.** *Deliverable:* German (Bavarian-style), Swiss, Spanish, Italian (one northern and one southern pattern), and tarot faces drawn originally or from verified public-domain designs, plus "show with French faces" option. *Accept:* rights ledger entry per pack in `docs/ART_RIGHTS.md`; snapshot review.
- **P11.5 Library completion for Waves 1–3.** *Deliverable:* rulebook pages for every Wave 3 game (including those not yet playable), marked "Rules coming" where not implemented. *Accept:* every Wave 1–3 entry has a page; originality script passes.
- **P11.6 Final handoff.** *Deliverable:* `docs/HANDOFF.md` complete with every section of `CONVENTIONS.md` §10, `docs/TODO_MAP.md` (every TODO in code mapped to a phase), `docs/KNOWN_ISSUES.md`, metrics, and a recorded 10-minute demo script. *Accept:* `REVIEW` requests written for CLAUDE, GROK, and MAHLER.

Federation games (Skat, French Tarot, and later Doppelkopf) and Wave 1's bridge and cribbage keep their public Play badge behind a build flag until a human expert approves them in P15.3 (`CATALOGUE.md` §4 step 6); internal and TestFlight builds may play them.

★ = tuned AI profile required (others may ship with the generic ISMCTS profile at Casual and Skilled only).

**G11 (🛑 GLM FINAL STOP):** automated: all suites green for 29 playable games; ladder holds for starred games; nightly sims clean for 7 consecutive nights. Reviews: `REVIEW: CLAUDE` (architecture health, debt, readiness for P12–P14), `REVIEW: GROK` (rules and AI for new games), `REVIEW: MAHLER` (plays at least five new games). **GLM's work ends here.**

### P12. Custom Rules Editor (CLAUDE + GROK · 24 ED)

**Goal:** families can write down and play their own rules safely.

- **P12.1 Overridable path annotations.** *Deliverable:* every built-in ruleset annotates which parameters are `overridable` for Tier 2, with labels and allowed ranges. *Accept:* every Wave 1–2 game exposes at least five meaningful tweaks (Grok-reviewed list).
- **P12.2 Tier 2 editor.** *Deliverable:* guided forms per mechanic (trick rules, card points, bonuses, scoring), an expression builder (pick-from-lists blocks that produce CardExpr, with a text view for advanced users), live validation, and a "Test these rules" button that runs the simulator and shows results in plain words. *Accept:* usability test with three non-programmers creating a house rule from a written description (Mahler arranges); validator and simulator integrated.
- **P12.3 Tier 3 editor (beta).** *Deliverable:* "Start from a game" templates, deck builder, zone and phase editor, mechanic parameter forms, generic bot assignment. *Accept:* Grok recreates Sevens and Go Fish from scratch in the editor and they pass the onboarding simulation checks.
- **P12.4 Explanations for user rules.** *Deliverable:* user rules get rule IDs automatically (`USR-n`) and the author writes `explain` text; the coach uses it. *Accept:* "Why not?" works for user restrictions.
- **P12.5 Sharing polish.** *Deliverable:* share sheet, file type registration, Quick Look preview of `.parlorrules`, diff preview, versioning of house rules. *Accept:* import of 1,000 fuzzed `.parlorrules` files never crashes and never results in a playable invalid ruleset.
- **P12.6 Security review of user content.** *Deliverable:* `docs/SECURITY.md` section on user content (limits, sandbox, plain-text rendering, URL confirmation). *Accept:* `REVIEW: CLAUDE`.

**G12:** `REVIEW: GROK` (editor UX and rule expressiveness) + `REVIEW: MAHLER` (creates "Grandma's Hearts" himself) + Claude's security sign-off.

### P13. Apple TV (CLAUDE · 10 ED)

- **P13.1 tvOS target.** *Deliverable:* `Parlor-tvOS` per `ARCHITECTURE.md` §18. *Accept:* builds and runs the headless host plus table UI.
- **P13.2 Ten-foot table layout.** *Accept:* legibility at 3 m on a 55" TV (index height ≥ 25 mm), safe areas respected, 4K and 1080p snapshots.
- **P13.3 Focus-driven host controls.** *Accept:* every host function reachable with the Siri Remote; Back opens a pause menu.
- **P13.4 Joining and storage.** *Deliverable:* QR join, Bonjour, DeviceDiscoveryUI convenience path for the owner's devices, CloudKit and phone-mirrored saves. *Accept:* TV cache purge simulation followed by resume from the phone-held save.
- **P13.5 Performance.** *Accept:* Casual and Skilled bots meet budgets on Apple TV 4K (2nd generation).

**G13:** `REVIEW: GROK` + `REVIEW: MAHLER` (a family game on the TV).

### P14. Online Play (CLAUDE · 18 ED)

- **P14.1 GameKit transport.** *Deliverable:* `GameKitTransport` (`ARCHITECTURE.md` §12.7), host election, chunking, per-player sends. *Accept:* the transport contract suite passes; redaction captures clean.
- **P14.2 Invitations and SharePlay.** *Deliverable:* friend invites, SharePlay start through `GKMatchmaker.startGroupActivity`, lobby parity with local play. *Accept:* a four-person remote bridge rubber completed by testers.
- **P14.3 Host loss online.** *Deliverable:* if the host leaves, the match pauses and the host can rejoin within 5 minutes; otherwise the match is saved for the host. *Accept:* scripted tests.
- **P14.4 Hybrid table (stretch).** *Deliverable:* a local table with one remote player. *Accept:* if not complete, deferred to 1.1 with an ADR.
- **P14.5 Abuse controls.** *Deliverable:* emotes only (no free text), block and report via Game Center, leave-penalty off by default. *Accept:* Grok review.

**G14:** `REVIEW: CLAUDE` security (online redaction, malicious peers, GameKit data paths) + `REVIEW: MAHLER`.

### P15. Beta (GROK + CLAUDE · 15 ED)

- **P15.1 TestFlight internal and external.** Mahler creates the App Store Connect record, signing, and groups; agents prepare builds and notes only.
- **P15.2 Structured tests with older adults and assistive-technology users** (at least 8 participants including at least 2 VoiceOver users and 2 with limited dexterity), recruited by Mahler; script and consent form drafted by Grok. *Accept:* every severity-1 issue fixed.
- **P15.3 Rules expert review** for bridge, cribbage, euchre, Skat, and Tarot by experienced players (Mahler recruits). *Accept:* findings fixed or documented as named variants.
- **P15.4 Telemetry-free feedback** via an in-app "Send feedback" that composes an email with an optional anonymized replay attachment (user-initiated only).
- **P15.5 iCloud sync** for house rules, profiles, and stats (CloudKit private database). *Accept:* conflict tests.
- **P15.6 Performance, energy, and stability** on real devices across the matrix; crash-free sessions ≥ 99.5%.

**G15:** `REVIEW: MAHLER` go/no-go with the beta report (issues, fixes, metrics, quotes from testers).

### P16. Release (CLAUDE + GROK · 6 ED)

- **P16.1 Store materials:** screenshots for iPhone, iPad, Mac (and Apple TV), description copy (no fleet internals, no public email addresses), keywords, Accessibility Nutrition Labels, privacy label ("Data Not Collected"), age rating answers from the current App Store Connect questionnaire.
- **P16.2 Legal:** EULA and privacy policy drafted through the account's legal-document workflow; third-party notices (DDS Apache-2.0, swift-certificates, swift-collections, swift-algorithms).
- **P16.3 Release checklist:** version `v1.0.0` per the account's va.b.c versioning scheme, release notes, tag.
- **P16.4 Submission:** **Mahler submits**; agents never press submit.

**G16:** `MAHLER` approval and submission.

---

## 3. Test Strategy

### 3.1 Test Pyramid

| Layer | What | Where | When |
| --- | --- | --- | --- |
| Unit | Types, mechanics, CardExpr, scorers, resolver, validator | Each package | Every commit |
| Conformance | One or more tests per rule ID from stacked decks, per game | `GameLibrary` tests, tag `.conformance` | Every commit |
| Property | Invariants over random seeds (below) | `RulesEngine`, `GameLibrary`, `TableNet` | Every commit (quick) and nightly (long) |
| Golden replay | Recorded matches with final-state hashes | `GameLibrary/Tests/Replays` | Every commit, both platforms |
| Simulation | 500 random plus 100 bot games per ruleset and variant, invariant checks | `rules-cli simulate` | Every commit (quick: 50) and nightly (full) |
| Network | Contract tests per transport, multi-client sessions, reconnect scripts | `TableNet` | Every commit |
| Fuzz | Protocol fuzz, ruleset import fuzz, CardExpr fuzz | `Tools/net-fuzz`, test targets | Nightly (30 min) and before 🛑 gates |
| UI | XCUITest flows, taps-only play, accessibility audits | App UI test targets | Every commit (smoke) and nightly (full) |
| Snapshot | Views at five sizes, themes, Dynamic Type, color filters | `TableUI` tests | Every commit |
| Performance | Reducer, observation, AI budgets, cold start, frame time | `Tools/perf` and Instruments | Nightly and at gates |
| Human | Rules experts, older adults, assistive-technology users | P3, P8, P11, P15 reviews | Gates |

### 3.2 Engine Property Tests

For every playable ruleset, over at least 2,000 seeds nightly (200 per commit):

1. **Conservation:** the multiset of card faces across all zones equals the deck at every step.
2. **Legality closure:** every intent returned by `legalIntents` is accepted by `apply`; a random sample of other well-formed intents is rejected with a rule ID.
3. **Progress:** every game terminates within the ruleset's declared bounds (`limits.maxSteps`); no state repeats with the same pending actor in a non-patience game.
4. **Determinism:** replaying the action log from the seed reproduces the final hash.
5. **Scoring sanity:** declared invariants hold (Hearts: points per deal sum to 26 or moon equivalent; bridge: exactly one side scores per deal; cribbage: no hand scores over 29).
6. **Turn integrity:** exactly the seats in `pendingActors` may act; no other seat's intent is accepted.
7. **Option coverage:** each Tier 1 option toggled on and off still satisfies 1–6.

### 3.3 Redaction Tests

1. **Byte scan:** for each step and each viewer, encode the `Observation` and every redacted event to JSON and search for the face identifier of every card the viewer does not know. Any match fails.
2. **Knowledge model:** a separate, simpler oracle tracks who has seen what from first principles (deals, passes, reveals, shows) and is compared to `KnowledgeStore` at every step.
3. **Identifier independence:** card instance IDs and zone ordering in observations are independent of hidden faces (statistical tests over 1,000 deals: chi-square on ID-to-face and position-to-face).
4. **Count-only zones:** hidden zones expose only counts and already-known cards.
5. **Hints and explanations:** hint and "Why not?" payloads for a seat are scanned like observations.
6. **Bots:** bots compile against `Observation` only; a test target that attempts `@_spi(HostOnly) import RulesEngine` from `CardAI` must fail `check-imports`.
7. **Wire capture:** in network tests every outbound frame per seat is captured and scanned.
8. **End of match:** reveal of the seed and full replay happens only after match end, never mid-match (test sends a reveal request mid-match and expects refusal).

### 3.4 Network Testing

- **Transport contract suite** run against `LoopbackTransport`, `NetworkTransport` (two processes on macOS), and later `GameKitTransport`: ordering, at-most-once intent handling, size cap, snapshot and delta reconciliation, version gaps.
- **Session scenarios:** joins, rejoins, seat swaps, bots taking over, take-backs, pause, host relaunch, network change, a client with a wrong version (refused with an upgrade message).
- **Fuzzing (`Tools/net-fuzz`):** a malicious client that mutates fields, truncates frames, floods, sends out-of-turn and other-seat intents, replays nonces and tokens, sends 10 MB payloads, and opens 50 connections. The host must stay responsive, keep invariants, never leak, and disconnect abusers.
- **Latency harness:** timestamps from tap to table render on loopback and across two Macs; p95 recorded in `docs/PERF.md`.
- **Real devices:** the G8 script (P8.10) and the beta matrix (P15).

### 3.5 Rules Correctness

- Every rule in `RULES-<game>.md` cites a source and has a rule ID; every rule ID has at least one conformance test.
- Scoring functions have independent second implementations in tests (cribbage brute force, bridge scoring tables, Skat game value tables, tarot contract tables).
- Rules experts review at G3, G11, and P15.
- Disagreements between sources become named variants or table options rather than silent choices; the chosen default and alternatives are logged.

### 3.6 AI Testing

- Bots must never produce an illegal intent (soak: 500 games per profile per commit at Casual, 5,000 nightly across levels).
- Ladder tournament nightly; regression alarm if Expert's win rate over Casual drops by more than 5 points.
- Position tests with expected choices for heuristics.
- Budget tests: no decision exceeds its budget by more than 10%.
- Fairness tests: bot code cannot import host state (compile-time), and bot decision traces are reproducible from the observation and seed alone.

### 3.7 Accessibility Testing

`performAccessibilityAudit()` on every screen in UI tests; scripted VoiceOver-action games; keyboard-only games; layout audit of target sizes; color-filter snapshots; Dynamic Type at the largest accessibility size; human sessions at P15.

### 3.8 Coverage Targets

CardModel, CardExpr, and RulesEngine ≥ 90% lines; RulesetKit, GameLibrary, TableNet ≥ 85%; CardAI ≥ 75%; UI packages measured but not gated (snapshot and UI tests instead).

---

## 4. Risks

| # | Risk | Likelihood | Impact | Mitigation | Owner |
| --- | --- | --- | --- | --- | --- |
| R1 | The mechanics library cannot express a later game cleanly | Medium | High | P3 chooses four structurally different games; G3 architecture review; §7 triage path; native functions as escape hatch | CLAUDE |
| R2 | Hidden information leaks through a path nobody thought of (identifiers, ordering, timing, hints) | Medium | Critical | SPI boundary, single Redactor, post-shuffle IDs, byte-scan tests, wire captures, Claude audits at G8 and G14 | CLAUDE |
| R3 | Rules errors in long-tail regional games undermine trust | High | Medium | Source dossiers, rule IDs, expert review, named variants, "Report a rules issue" | GROK |
| R4 | Copyright claim over rulebook text or card art | Low | High | Original prose, originality script, art rights ledger, no Pagat or Hoyle text, cite by link (`ARCHITECTURE.md` §17) | GROK |
| R5 | Trademark conflict with a game or app name | Medium | Medium | Exclude trademarked games (`CATALOGUE.md` §6); name search before release (Q1) | MAHLER |
| R6 | Local networking flakiness (Wi-Fi isolation in hotels, local network permission denied) | High | High | Peer-to-peer Wi-Fi, clear permission education, phone hotspot guidance, pass-and-play fallback, reconnect logic | GLM then CLAUDE |
| R7 | New Network framework API changes or bugs (the 26-series API is recent) | Medium | Medium | `Transport` protocol isolates it; contract suite; fallback to `NWConnection` APIs if needed (ADR) | CLAUDE |
| R8 | Bridge AI quality disappoints serious players | Medium | Medium | DDS-based play, data-driven bidding, honest level labels, focus on social play, later improvement path | GROK |
| R9 | App Review rejects the house-rules feature as executable code | Low | High | Data-only, non-Turing-complete rules, no scripts, documented in review notes (guideline 2.5.2) | CLAUDE |
| R10 | App Review treats casino games as simulated gambling | Medium | Medium | Off by default, play money only, no purchasable chips, separate rating answers (Q4) | MAHLER |
| R11 | GLM drifts from conventions over a long run | Medium | High | Machine-checked conventions, gate scripts, three 🛑 stops, handoff package | CLAUDE |
| R12 | Scope creep (94 catalogue entries) | High | Medium | Waves; catalogue-only pages; release scope fixed in §0.4 | MAHLER |
| R13 | Performance on older iPhones (AI and animation) | Medium | Medium | Budgets, node limits, lower levels by default on older devices | GLM |
| R14 | Older users struggle with joining by QR | Medium | High | Host-side "Let in" button, 6-digit code alternative with host approval, large-type join screen, setup test in G8 and P15 | GLM |
| R15 | DDS build or licensing issue | Low | Medium | Apache-2.0 confirmed; vendored at a pinned commit; notices in P16 | CLAUDE |

---

## 5. Out of Scope (Version 1.0)

- Real-money gambling, purchasable chips, or any wagering. Casino games are play-money only and optional.
- Dealer-less cryptographic shuffling ("mental poker"). The seed commitment gives auditability; a malicious host is a social problem at a family table.
- Host migration (another device taking over as host) for local play.
- A public gallery or marketplace for house rules; sharing is file-based only.
- General scripting (JavaScript, Lua, or WebAssembly) in rulesets.
- Game Center turn-based matches (`GKTurnBasedMatch`), because match data is visible to all participants.
- Ben, WBridge5, or any GPL or proprietary bridge engine.
- Licensed or trademarked games (`CATALOGUE.md` §6), collectible card games, and proprietary-deck games.
- Ranked online ladders, ratings, chat, and voice chat (emotes only).
- Duplicate bridge tournament features beyond a simple two-table duplicate mode (no club scoring software import, no ACBL or EBU masterpoints).
- Android, Windows, and web clients.
- Multipeer Connectivity in any form.
- Physical card recognition by camera (a possible later feature).
- Ads and third-party analytics SDKs.

---

## 6. Effort Estimates

Units are engineer-days (ED) of focused work by a capable agent with review (`CONVENTIONS.md` §11). Ranges reflect uncertainty in rules research and UI polish.

| Phase | Low | Expected | High | Main Uncertainty |
| --- | --- | --- | --- | --- |
| P0 | 3 | 4 | 6 | Toolchain quirks |
| P1 | 11 | 14 | 18 | Redaction design detail |
| P2 | 13 | 16 | 22 | CardExpr type checker |
| P3 | 16 | 20 | 28 | Bridge auction and claims |
| P4 | 20 | 24 | 32 | Patience UI and Gin |
| P5 | 10 | 12 | 16 | Prose volume |
| P6 | 17 | 22 | 32 | Bridge bidding system |
| P7 | 13 | 16 | 22 | Lesson authoring volume |
| P8 | 16 | 20 | 28 | Real-network behavior |
| P9 | 8 | 10 | 14 | Table design iteration |
| P10 | 10 | 12 | 16 | VoiceOver narration |
| P11 | 36 | 45 | 60 | Skat and Tarot scoring; Canasta |
| P12 | 19 | 24 | 32 | Editor UX |
| P13 | 8 | 10 | 14 | tvOS focus and storage |
| P14 | 14 | 18 | 26 | GameKit edge cases |
| P15 | 10 | 15 | 20 | Tester recruitment and fixes |
| P16 | 4 | 6 | 8 | Review feedback |
| **Total** | **228** | **288** | **394** | |

Calendar time is not estimated here: it depends on agent throughput, parallelism, failed gates, and how quickly reviews and real-device sessions return.

---

## 7. Engine Feature Triage (New Mechanics)

When a game in a later wave needs something the engine does not express:

1. **Try options and parameters.** Can an existing mechanic express it with a new parameter? Add the parameter with tests (minor engine change, logged).
2. **Try expressions.** Can a `def` or `restrict` in CardExpr express it within fuel limits? Prefer this for single-game rules.
3. **Try a native function.** If the rule is a pure, game-specific calculation (a scoring table, a meld detector), add a whitelisted native function with an independent test implementation.
4. **New mechanic.** If the game's structure is new (for example, a layout capture game), write an ADR proposing the mechanic, its parameters, its observation shape, and its redaction rules. GLM may implement new mechanics only in P11 and only with the ADR recorded; architecture-level changes (new viewer kinds, new zone visibility kinds, schema version bumps) wait for a Claude review.
5. **Defer.** If none of the above is proportionate, mark the game "Rules coming" in the catalogue and record why in `docs/OPEN_QUESTIONS.md`.

Each step records the decision in `docs/DECISIONS.md` and keeps the schema version policy (`ARCHITECTURE.md` §5.1).

---

## 8. Open Questions for Mahler (with Defaults)

GLM proceeds with the default unless Mahler has answered. Answers are recorded in `docs/OPEN_QUESTIONS.md` and, when they change scope, as ADRs.

| # | Question | Default If Unanswered | Needed By |
| --- | --- | --- | --- |
| Q1 | Final app name (Parlor, Common Deck, Long Table, or other)? Trademark search? | Code name `Parlor`; display name decided at P15 | P15 |
| Q2 | Bundle ID prefix and developer account (`com.zyniker.parlor`)? | Placeholder until P15; signing set up by Mahler | P15 |
| Q3 | Monetization: paid upfront, free with one unlock, or subscription? | Paid upfront (about $9.99), no ads, no subscriptions, Family Sharing on; every game included, no game packs at 1.0 | P15 |
| Q4 | Include casino games (poker, blackjack, baccarat) at all? | Yes, as Wave C: play money only, behind an off-by-default "Casino Games" setting, shipped in 1.1, not 1.0 | P11 |
| Q5 | Seek permission from John McLeod (Pagat) to link deeply and credit, or ask to quote? | Link and credit only; no quotation; send a courtesy note before launch (draft by Grok for Mahler's approval) | P15 |
| Q6 | Bridge bidding system default: SAYC-style or 2/1-style? | SAYC-style (`parlor-standard-sayc`), 2/1 later | P6 |
| Q7 | Which regional games matter most to Mahler's family and audience (prioritize in Wave 3)? | Skat, Belote, French Tarot, Briscola, Scopa (tranche A) | P11 |
| Q8 | Should Apple TV block 1.0 if it is late? | No; ship in 1.1 | P13 |
| Q9 | Card art direction: classic and traditional, or modern? Commission an artist? | Classic, original vector faces produced in-house; four-color option; commission later if budget allows | P4 |
| Q10 | Localization languages for 1.0? | English (US) only, with all strings localizable; German, French, Italian, and Spanish in 1.1 to match regional games | P15 |
| Q11 | Who are the beta testers (older adults, VoiceOver users, rules experts)? | Mahler recruits 8+ participants and 3 rules experts | P15 |
| Q12 | Online play at 1.0, or local only first? | Online in 1.0 if G14 passes; otherwise 1.1 | P14 |
| Q13 | Repository location and name? | New private repository chosen by Mahler; nothing is committed until he names it | P0 |
| Q14 | Allow optional Game Center achievements and leaderboards? | Achievements yes (learning milestones); no leaderboards | P15 |
| Q15 | Religious or family-content sensitivities for themes and names (for example tarot imagery)? | Tarot uses the traditional French tarot nouveau trumps (genre scenes), not occult imagery; label as "French Tarot (the card game)" | P11 |
