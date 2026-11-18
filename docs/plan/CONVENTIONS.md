# Conventions: Process, Stack, and Standards

Version 1.0 · 2026-11-15 · Applies to every phase of Parlor.

This file is process law. When it disagrees with another file on process, stack, standards, or gates, this file wins (see `README.md` §2).

---

## 1. Roles and Sign-Off Codes

| Code | Who | Responsibility |
| --- | --- | --- |
| `GLM` | Autonomous GLM coding agent | Initial build, P0 through P11. Self-checks gates marked `GLM-SELF`. |
| `CLAUDE` | Claude agent | Architecture, code quality, security and redaction audits, networking, platform integration, accessibility engineering. Leads P12–P14 engineering. |
| `GROK` | Grok agent | Game-rule correctness, AI strength and feel, teaching content, UX and copy review, beta triage. |
| `MAHLER` | Human owner | Taste, feel, and go/no-go. Only Mahler approves or performs anything external: Apple Developer and App Store Connect actions, signing, TestFlight external groups, submission, pricing, spending money, contacting rule-text authors, and posting publicly. |

Gate notation:

- `GLM-SELF`: GLM runs the checks, records evidence in `docs/STATUS.md`, and continues if all pass.
- `REVIEW: CLAUDE`, `REVIEW: GROK`: the named agent reviews and writes a signed entry (`Reviewed-by: CLAUDE, 2026-12-03, PASS` plus findings) in `docs/STATUS.md`.
- `REVIEW: MAHLER`: Mahler plays the build on real hardware and records PASS or FAIL (Claude or Grok may transcribe his verdict).
- `ASYNC REVIEW: <who>`: the named reviewer reviews after the gate passes; GLM continues to the next phase, and every finding becomes a task that must be closed before the next 🛑 stop gate.
- `🛑 GLM STOP`: GLM stops all work, writes or refreshes `docs/HANDOFF.md`, and waits. It does not start the next phase.

### 1.1 Mandatory GLM Stops

1. **G3 (First Four Games):** 🛑 STOP. Resume P4 only after `REVIEW: CLAUDE` and `REVIEW: MAHLER` are PASS.
2. **G8 (Local Multi-Device Hand Mode):** 🛑 STOP. Resume P9 only after `REVIEW: CLAUDE` (security) and `REVIEW: MAHLER` (four real devices) are PASS.
3. **G11 (Game Waves 2 and 3):** 🛑 **FINAL** STOP. GLM's work ends after `docs/HANDOFF.md` is complete.
4. **Unscheduled stops** (write `docs/HANDOFF.md`, then wait):
   - a gate check fails after three consecutive fix attempts;
   - a task needs an Apple Developer, signing, App Store Connect, payment, or third-party account action;
   - a rule ambiguity changes play or scoring and `ROADMAP.md` §8 lists no default (log it in `docs/OPEN_QUESTIONS.md`);
   - a dependency outside §4.4 seems necessary;
   - a redaction test fails and the fix is not obvious within one attempt (security issues are never "worked around").

### 1.2 Who May Change What

| Artifact | GLM | CLAUDE | GROK | MAHLER |
| --- | --- | --- | --- | --- |
| `docs/plan/*` (this package) | Never (log proposals in `docs/OPEN_QUESTIONS.md`) | Propose via ADR | Propose via ADR | Approves |
| `docs/DECISIONS.md` (ADRs) | Adds ADRs for choices the plan leaves open | Adds and amends | Adds | Final say |
| Ruleset meaning (what a rule does) | Only to match the cited primary source; log each change | Yes, with GROK review | Yes | Final say |
| Bundle IDs, capabilities, entitlements | Placeholders only | Yes | No | Approves |

---

## 2. Fixed Technology Stack (Do Not Re-Decide)

| Concern | Decision | Rationale |
| --- | --- | --- |
| Language | Swift 6.2 or newer, language mode 6, strict concurrency `complete` | One language everywhere; data-race safety for networking. |
| Toolchain | Latest stable Xcode 26.x; record exact version in ADR-0001. Do not adopt Xcode 27 betas. | Reproducible builds. |
| Deployment targets | iOS and iPadOS 26.0, macOS 26.0; tvOS 26.0 added in P13 | Unlocks the structured-concurrency Network framework API (`NetworkConnection`, `NetworkListener`, `NetworkBrowser`) introduced in the 26 releases. |
| App shell | SwiftUI multiplatform app; one source set, platform folders for entry points and menus | Native Mac menus and windows without Catalyst. |
| Card and table rendering | **SwiftUI views** (`Canvas` only for felt and decorations), `matchedGeometryEffect` and `PhaseAnimator`/`KeyframeAnimator` for motion. **No SpriteKit, RealityKit, or Metal.** | Cards are UI: SwiftUI gives VoiceOver, Dynamic Type, Switch Control, keyboard focus, and pointer support through standard platform behavior. |
| Local multi-device networking | **Network framework, 26-series Swift API** (`NetworkListener` + Bonjour on the host, `NetworkBrowser` on clients, `NetworkConnection` with TLS 1.3 over TCP and a `Coder` for `Codable` messages). **Multipeer Connectivity is forbidden** (deprecated by Xcode 27 per Apple TN3213). | Supported, client-server, works on tvOS. |
| Transport security | Host generates a per-session self-signed P-256 identity with `apple/swift-certificates`; clients pin its SHA-256 fingerprint delivered in the join QR code or confirmed by a 6-digit channel-bound code shown on both screens, followed by host approval. Mutual identity per seat via a seat token. | Meaningful security without PKI, per TN3213 guidance. |
| Online play (P14) | GameKit real-time `GKMatch` (with SharePlay through `GKMatchmaker.startGroupActivity`), host-elected, same protocol and redaction as local. GameKit turn-based is **out of scope** (shared `matchData` cannot hide hands). | No custom servers. |
| Persistence | Codable JSON files in Application Support (`Saves/`, `HouseRules/`, `Profiles/`, `Stats/`); atomic writes; schema version in every file. iCloud sync of house rules and stats in P15 via CloudKit private database. | Debuggable, testable, no migration framework. |
| Ruleset format | JSON files validated by the in-app `RulesetValidator`; a JSON Schema (draft 2020-12) published in `Resources/Schemas/` for tooling only | One format for built-in games, variants, and house rules. |
| Expression language | **CardExpr**, our own non-Turing-complete, integer-only expression language (see `ARCHITECTURE.md` §7), implemented in Swift | Safe for user content; deterministic; App Store guideline 2.5.2-compatible (data, not code). |
| Scripting | **None.** No JavaScriptCore, Lua, WebAssembly, or downloaded code, ever. | Guideline 2.5.2, determinism, and sandboxing. |
| Bridge double-dummy solving | Vendored **DDS** (`dds-bridge/dds`, Apache-2.0) as an SPM C++ target wrapped by `BridgeSolver`, built single-threaded, pinned commit recorded in ADR | Proven speed; licence compatible. GPL code (for example Ben) is forbidden. |
| Speech | `AccessibilityNotification.Announcement` for VoiceOver; `AVSpeechSynthesizer` for the optional "Table Caller" voice | Built in. |
| Haptics | Core Haptics with AHAP files | Turn and trick cues on the hand device. |
| Project generation | XcodeGen (`project.yml`); generated `.xcodeproj` is git-ignored | Agents never hand-edit `project.pbxproj`. |
| Packages | Local SPM packages under `Packages/` | `swift test` on the command line. |
| Tests | Swift Testing for packages; XCTest and XCUITest for UI; `swift-snapshot-testing` for snapshots | Parameterized conformance tests. |
| Lint and format | SwiftLint (`--strict`) and `swift-format` | Three agents, one style. |
| CI | GitHub Actions on the latest `macos-26` runner | Every gate check runs in CI. |
| Monetization (default) | Premium, one price, universal purchase across iPhone, iPad, Mac (and Apple TV); no ads, no subscriptions, no consumables; optional one-time "Game Pack" purchases only if Mahler chooses (open question Q3) | Research: ads are the top complaint in BBO, Trickster, and MobilityWare reviews. |

Bundle identifier placeholder: `com.zyniker.parlor` (Mahler confirms). App group placeholder: `group.com.zyniker.parlor`. Bonjour service type: `_parlor._tcp`. GLM uses placeholders and never registers them.

---

## 3. Repository Layout

```
parlor/
├── project.yml                 # XcodeGen: Parlor-iOS, Parlor-macOS, (P13) Parlor-tvOS, UI test targets
├── Makefile                    # bootstrap | gen | build | test | lint | conformance | fuzz | sim | snapshot | coverage | perf
├── .swiftlint.yml  .swift-format  .github/workflows/ci.yml
├── App/
│   ├── Shared/                 # Scenes, navigation, settings, root views
│   ├── iOS/                    # iOS and iPadOS entry, Info.plist, entitlements
│   ├── macOS/                  # Mac entry, menus/commands, Info.plist, entitlements
│   └── tvOS/                   # (P13) tvOS entry
├── Packages/
│   ├── CardModel/              # Suits, ranks, cards, deck definitions, zones. Pure Swift.
│   ├── CardExpr/               # Expression language: lexer, parser, type checker, evaluator. Pure Swift.
│   ├── RulesEngine/            # GameState, Action, reducer, mechanics library, redaction. Pure Swift.
│   ├── RulesetKit/             # Ruleset schema types, loader, overlay resolver, validator, simulator harness.
│   ├── GameLibrary/            # Built-in rulesets (JSON), rulebook prose (Markdown), lessons, catalogue index.
│   ├── CardAI/                 # Bots: heuristic, PIMC, ISMCTS, game-specific evaluators; BridgeSolver (DDS).
│   ├── Teaching/               # Lesson runner, hint engine, explanation generator, trainers.
│   ├── TableNet/               # Session protocol, host, client, discovery, pairing, reconnect, GameKit adapter.
│   ├── TableUI/                # Card views, hand view, table view, seat badges, animations, themes and decks.
│   ├── Library/                # Catalogue and rulebook UI, search, filters.
│   ├── Accessibility/          # Narration, rotor content, audio cues, large-target layouts, timing settings.
│   ├── Persistence/            # Saves, profiles, stats, house-rules store.
│   └── Platform/               # Haptics, speech, Game Center, iCloud, Handoff adapters behind protocols.
├── Resources/
│   ├── Rulesets/               # *.ruleset.json (source of truth for rules)
│   ├── Rulebook/               # <game-id>/*.md original prose
│   ├── Lessons/                # <game-id>/*.lesson.json
│   ├── Decks/                  # Card face art (vector PDF or SVG assets), back designs
│   ├── Schemas/                # ruleset.schema.json, lesson.schema.json
│   ├── Haptics/  Audio/  Localization/
├── Tools/
│   ├── rules-cli/              # validate | resolve | simulate | replay | conformance | fuzz (Swift executable)
│   ├── check-imports.sh
│   └── net-fuzz/               # Protocol fuzzer harness (Swift executable)
├── Tests/  UITests/  Snapshots/
└── docs/
    ├── plan/                   # This package, verbatim
    ├── STATUS.md  DECISIONS.md  KNOWN_ISSUES.md  TODO_MAP.md  OPEN_QUESTIONS.md
    ├── COVERAGE.md  CONFORMANCE.md  PERF.md  SECURITY.md  ACCESSIBILITY.md  HANDOFF.md
    └── rules/                  # One RULES-<game-id>.md per implemented game: numbered rule IDs and sources
```

### 3.1 Dependency Direction (Enforced by `Tools/check-imports.sh`)

```
CardModel ← CardExpr ← RulesEngine ← RulesetKit ← GameLibrary
                                  ↖ CardAI (RulesEngine, RulesetKit)
                                  ↖ Teaching (RulesEngine, RulesetKit, CardAI)
TableNet (RulesEngine, RulesetKit)        Persistence (RulesEngine, RulesetKit)
TableUI, Library, Accessibility (any of the above) ← Platform ← App
```

`CardModel`, `CardExpr`, `RulesEngine`, `RulesetKit`, `GameLibrary`, `CardAI`, and `Teaching` must not import SwiftUI, UIKit, AppKit, GameKit, Network, or AVFoundation. `TableNet` may import Network and GameKit only. CI fails otherwise.

---

## 4. Coding Standards

### 4.1 Naming
- Types `UpperCamelCase`; functions and properties `lowerCamelCase`; files named for their primary type.
- Game IDs, ruleset IDs, and lesson IDs are lowercase `kebab-case` segments joined by dots, stable forever once shipped: `hearts`, `hearts.standard`, `hearts.l2-passing`. Option IDs, variable names, and def names are `camelCase` because they appear inside CardExpr (`options.jackOfDiamonds`). Rule IDs are `HRT-4.2` style.
- Rule IDs use a three-letter game code plus section and item (`EUC-3.1`), and every rule ID in `docs/rules/RULES-<game>.md` has at least one test tagged with it.

### 4.2 General
- No force unwraps outside tests; no `fatalError` in shipping paths except unreachable `switch` defaults with a message.
- Public package APIs carry `///` doc comments.
- Functions over 60 lines or types over 400 lines need a justification comment or a split.
- Every user-facing string goes through String Catalogs (`.xcstrings`). English (US) ships first; ruleset display names and rulebook prose are localizable from day one (keys, not literals).
- Every interactive control has an accessibility identifier (`hand.card.QS`, `table.trick.seat2`) and an accessibility label.

### 4.3 Concurrency
- Engine types are `Sendable` value types. The host runs the engine inside one `actor GameHost`; nothing else mutates state.
- UI observes `@Observable` view models fed by `Observation` snapshots (see `ARCHITECTURE.md` §9). No Combine.

### 4.4 Dependency Allow-List
Runtime: `apple/swift-collections`, `apple/swift-algorithms`, `apple/swift-certificates` (and its Apple transitive dependencies `swift-crypto` and `swift-asn1`), vendored `dds-bridge/dds` (Apache-2.0). Tests only: `pointfreeco/swift-snapshot-testing`. Tools: XcodeGen, SwiftLint, swift-format. Anything else needs an ADR and `REVIEW: CLAUDE`. GPL, LGPL, AGPL, and unlicensed code is forbidden.

---

## 5. Determinism (Non-Negotiable)

1. `GameState` is a `struct` that is `Codable`, `Equatable`, `Hashable`, and `Sendable`.
2. Every state change goes through one pure reducer: `func apply(_ action: Action, to state: GameState) throws(RuleViolation) -> Transition` where `Transition` holds the new state and `[GameEvent]`. Randomness lives in the state (`state.rng`), never outside it.
3. RNG: `SeededRNG` = xoshiro256** seeded through SplitMix64 from a 64-bit seed. Shuffles use Fisher–Yates with unbiased bounded integers (Lemire's method). Per-deal seeds derive from `SplitMix64(sessionSeed ^ dealIndex)`.
4. Banned in `CardModel`, `CardExpr`, `RulesEngine`, `RulesetKit`, `CardAI`, and `Teaching` (SwiftLint custom rules plus `check-imports.sh`): `Date()`, `UUID()`, `SystemRandomNumberGenerator`, `.random(in:)` without an explicit `using:` generator, `Float`, `Double`, `CGFloat`, `Dictionary` iteration where order affects results (use `OrderedDictionary` or sorted keys), and `Set` iteration where order affects results.
5. AI search may use wall-clock budgets only through an injected `ThinkBudget` (node counts in tests and CI; time budgets only in the app). With a node budget, AI output is bit-identical for a given seed.
6. Every game has golden replays: `Replay { rulesetHash, seed, actions }` that reproduce a stored final-state SHA-256 on every platform and in CI.

---

## 6. Testing Requirements (Summary; Full Strategy in `ROADMAP.md` §3)

| Layer | Requirement | Gate Threshold |
| --- | --- | --- |
| CardModel, CardExpr, RulesEngine | Unit tests; property tests over ≥ 1,000 seeds for invariants | ≥ 90% line coverage |
| Conformance | Per game: every numbered rule in `docs/rules/RULES-<game>.md` has ≥ 1 tagged test; scenario tests from stacked decks; scoring tables checked against worked examples | 100% rule IDs covered; 100% pass |
| Golden replays | ≥ 20 per game | 100% pass on iOS simulator, macOS, and Linux-free `swift test` on macOS |
| Redaction | For every game and every phase: no observation for seat *s* contains any card identity hidden from *s* | 0 leaks across ≥ 2,000 simulated games per game |
| Ruleset validation | Every built-in ruleset and variant validates and passes a 500-game random-legal-move simulation with termination, conservation, and scoring invariants | 0 errors |
| AI | No illegal actions; budgets respected; strength ladder holds (Expert beats Casual ≥ 60% over 1,000 deals where measurable) | Per `ROADMAP.md` P6 |
| Network | Protocol fuzzing, reconnect scenarios, and malicious-client tests | Per `ROADMAP.md` P8 |
| UI | XCUITest smoke flows per role; snapshots at iPhone 6.1", iPhone 6.9", iPad 11", iPad 13", Mac 1440×900; light, dark, largest Dynamic Type, high contrast | No unreviewed diffs |
| Accessibility | Automated audit (`XCUIApplication.performAccessibilityAudit()`) on every screen; manual VoiceOver and Switch Control scripts | 0 audit failures; scripts pass |
| Overall | Line coverage | ≥ 70% overall |

---

## 7. CI Expectations

`.github/workflows/ci.yml` runs on every push and pull request:
1. `make bootstrap` (Homebrew XcodeGen, SwiftLint, swift-format; cached).
2. `make lint` (zero warnings) and `Tools/check-imports.sh`.
3. `swift test --parallel --enable-code-coverage` in every package.
4. `make conformance` (all rule-ID-tagged tests plus golden replays; writes `docs/CONFORMANCE.md`).
5. `make validate` (`rules-cli validate` on every ruleset, variant, and lesson).
6. `make sim N=200` (random-legal and bot-vs-bot games for every implemented game; fails on crash, illegal action, invariant break, nontermination, or determinism mismatch).
7. `make fuzz-quick` (P8 onward: 60 seconds of protocol fuzzing).
8. `make gen && xcodebuild build` for iOS (iPad and iPhone simulators) and macOS, warnings as errors.
9. `xcodebuild test` for UI and snapshot tests on iPad Pro 13" simulator, iPhone 17 simulator, and macOS.
10. Upload coverage, conformance, sim, and fuzz reports as artifacts.

Nightly (P6 onward): `make sim N=5000`, `make fuzz` (30 minutes), AI ladder tournament.

Branching: `main` is always green. GLM works on `phase/Pn-short-name`, merges by PR when the phase's tests pass, and tags `gate-GN-pass`. Conventional Commits (`feat(engine): add follow-suit constraint EUC-3.1`).

---

## 8. Performance and Quality Budgets

| Metric | Target | Device |
| --- | --- | --- |
| Frame rate during card animation | 120 fps on ProMotion, never below 60 fps | iPad Pro (M4); floor iPad (A16), iPhone 15 |
| Cold start to library | < 1.5 s | iPad (A16) |
| Tap on a card to its appearance on the table device (local network) | p95 < 150 ms, p99 < 300 ms | Two devices on home Wi-Fi |
| Reducer `apply` | p99 < 1 ms | iPhone 15 |
| Ruleset load, resolve, and validate | < 50 ms per game | iPhone 15 |
| Bot think time | Casual p95 < 400 ms; Expert p95 < 2.0 s (configurable) | iPhone 15 |
| Bridge double-dummy solve, full deal | p95 < 250 ms | iPhone 15 |
| Memory | < 300 MB resident | iPad (A16) |
| Download size | < 120 MB | — |
| Energy | A two-hour session on a hand device uses < 25% battery on iPhone 15 | Real device |
| Crash-free sessions (beta) | ≥ 99.5% | TestFlight |

Record measurements in `docs/PERF.md` with device, OS, build, and date.

---

## 9. Gate Protocol

1. At phase end, run `make gate PHASE=Pn` (added in P0); it runs every automated check that phase lists and prints a summary.
2. Paste the summary into `docs/STATUS.md` under `## Gn` with date, commit SHA, and each check's PASS or FAIL.
3. For manual checks, record steps and observations.
4. If any check fails: fix and rerun. After three consecutive failures of the same check, 🛑 stop (unscheduled stop).
5. On PASS for `GLM-SELF` gates: merge, tag `gate-Gn-pass`, start the next phase.
6. On `REVIEW` gates: write the review request in `docs/STATUS.md` (what to look at, how to run it, known issues), refresh `docs/HANDOFF.md`, and stop until the reviewer's signed PASS appears.

---

## 10. Handoff Package (Required at Every 🛑 Stop)

`docs/HANDOFF.md` must contain:
1. **State:** last passed gate, current branch, commit SHA, how to build and run on each platform.
2. **What works:** a bullet list per role (host, table, hand) and per game.
3. **What does not:** `docs/KNOWN_ISSUES.md` summary with severity.
4. **Architecture deltas:** every ADR added since the last handoff and every place the code deviates from `ARCHITECTURE.md`, with reasons.
5. **Fragile areas:** files and functions most likely to break, with the test that guards each.
6. **Rule decisions:** every ambiguity resolved with a default and its source.
7. **Metrics:** coverage, conformance counts, sim results, perf numbers, redaction-test totals.
8. **Next steps:** the first three tasks of the next phase and any prerequisites the reviewer must provide.
9. **How to verify:** a 10-minute script a reviewer can follow on real devices.

---

## 11. Effort Units

Estimates use **engineer-days (ED)**: one focused day of a competent senior engineer. Agent wall-clock time differs; use ED for relative sizing and review planning only.
