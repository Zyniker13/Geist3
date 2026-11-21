# DECISIONS — Architecture Decision Records

Purpose: every decision made during the build as a numbered ADR (context, decision, consequences). ADR numbers are never reused; superseded ADRs are marked, not deleted. P0.6 transcribes ADR-0001–ADR-0020 from `docs/plan/ARCHITECTURE.md` §21.

## Index

| ADR | Title | Status |
| --- | --- | --- |
| 0001 | Toolchain: Xcode 27.2, Swift 6.4.2, language mode 6 | Accepted |
| 0002 | Rules as data: rulesets + mechanics library + CardExpr, no scripting | Accepted |
| 0003 | CardExpr: CEL-like, integer-only, non-Turing-complete, fuel-bounded | Accepted |
| 0004 | Overlays: ID-addressed restricted JSON Patch; canonicalized, hashed resolved rulesets | Accepted |
| 0005 | Host-authoritative star topology; redaction at one choke point | Accepted |
| 0006 | `GameState` is `@_spi(HostOnly)`; bots and UI consume `Observation` only | Accepted |
| 0007 | Card instance IDs assigned post-shuffle per deal; hidden zones expose counts plus known cards | Accepted |
| 0008 | xoshiro256** + SplitMix64; Fisher–Yates; Lemire bounded integers; no floats in rules | Accepted |
| 0009 | Network framework 26-series API, Bonjour, TLS 1.3 with per-session self-signed identity; no Multipeer Connectivity | Accepted |
| 0010 | Seed commitment and reveal for verifiable shuffles | Accepted |
| 0011 | SwiftUI for all card rendering; no SpriteKit | Accepted |
| 0012 | DDS vendored (Apache-2.0) for bridge; no GPL code (Ben, CardStock) | Accepted |
| 0013 | Bots: heuristics, PIMC, SO-ISMCTS, exact tables; observation-only | Accepted |
| 0014 | GameKit real-time for online; turn-based excluded (shared match data) | Accepted |
| 0015 | Tap-to-select-then-play as the universal interaction; drag optional | Accepted |
| 0016 | No turn timers by default | Accepted |
| 0017 | Original rulebook prose only; sources cited by link | Accepted |
| 0018 | Apple TV is host + table only; Bonjour + QR for guests | Accepted |
| 0019 | Premium universal purchase, no ads (pending Mahler, Q3) | Accepted (default applied) |
| 0020 | JSON files for persistence with schema versions; CloudKit private DB for sync | Accepted |
| 0021 | Rename `Accessibility` package to `A11yKit` | Accepted |
| 0022 | Gate G0 excludes the macOS UI-test leg; required again from G9 | Accepted |
| 0025 | Standard native scoring semantics (P2.4) | Accepted |
| 0026 | Schema shapes are closed; unknown keys fail decode | Accepted |
| 0027 | JSON Schema export is a structural mirror, freshness-checked | Accepted |
| 0028 | Score choices pend per seat, in any order | Accepted |
| 0029 | Show `cards` binds the pile's own cards; `with` zone revealed | Accepted |
| 0030 | `trick.number` is 1-based; trick record bound at every trick-context eval | Accepted |
| 0031 | Claim legal branches mirror `applyClaim` gates exactly | Accepted |
| 0032 | `PhaseOutcome.autoStep` lets a mechanic expose internal automatic steps | Accepted |
| 0033 | Engine retains the completed trick record for score-phase expressions | Accepted |
| 0034 | Host-side dealt record backs `dealtHands()`; scalar Int keys | Accepted |
| 0035 | `otherwise: "any"` fallback when guards empty the candidate set | Accepted |
| 0036 | Auction param calls bind the value canonically as `param` | Accepted |

## ADR-0001 — Toolchain: Xcode 27.2, Swift 6.4.2, language mode 6

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** CONVENTIONS §2 (fixed stack) requires the latest stable Xcode and recording the exact version in ADR-0001. The build machine has Xcode 27.2 (Swift 6.4.2) installed. CONVENTIONS §2's "latest stable Xcode 26.x" wording predates the plan's own references to Xcode 27 (e.g. Multipeer Connectivity deprecation per Apple TN3213, CONVENTIONS §2 networking row), so the latest stable 27.x is the intended "latest stable". Logged in OPEN_QUESTIONS.
- **Decision:** Xcode 27.2, Swift 6.4.2, Swift language mode 6, strict concurrency `complete`. Tools: XcodeGen 2.46.0, SwiftLint 0.65, swift-format (Xcode 27.2). Package manifests use `swift-tools-version: 6.0` with string platform versions (`.iOS("26.0")`, `.macOS("26.0")`); the `.v26` platform constants require PackageDescription 6.2 and are not used.
- **Consequences:** Reproducible builds on the build machine; CI (`macos-latest`) must match this Xcode major. Any toolchain bump is a new ADR. Deployment targets remain iOS 26.0 / macOS 26.0 per CONVENTIONS §2.

## ADR-0002 — Rules as data: rulesets + mechanics library + CardExpr, no scripting

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §5 (Ruleset Format and Schema), §7.
- **Decision:** Game rules are JSON ruleset data interpreted by a fixed mechanics library, with conditional logic expressed in CardExpr. There is no general scripting language in rulesets.
- **Consequences:** Rulesets are validatable, diffable, and safe to ship as content; user-authored rules stay inside the same sandboxed tier system (ARCHITECTURE §11).

## ADR-0003 — CardExpr: CEL-like, integer-only, non-Turing-complete, fuel-bounded

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §7 (CardExpr, the Expression Language).
- **Decision:** CardExpr is a CEL-like expression language: integer-only arithmetic, no unbounded loops, non-Turing-complete, with a per-evaluation fuel budget.
- **Consequences:** Evaluation is total and fast enough for AI search; no float nondeterminism (supports ADR-0008); malformed or runaway expressions fail validation, not at runtime.

## ADR-0004 — Overlays: ID-addressed restricted JSON Patch; canonicalized, hashed resolved rulesets

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §8 (Variant and Override Layering).
- **Decision:** Variants and house rules are ID-addressed restricted JSON Patch documents applied to a base ruleset. The resolved ruleset is canonicalized (stable key order, no whitespace) and hashed; the hash is part of session identity and replays.
- **Consequences:** Two devices can prove they are playing the same rules; overlay conflicts are detectable at validation time.

## ADR-0005 — Host-authoritative star topology; redaction at one choke point

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §12 (Networking: Host-Authoritative Sessions).
- **Decision:** One device is the authoritative host; all other devices connect to it in a star. The host runs the engine and produces per-viewer `Observation`s; redaction happens at that single choke point.
- **Consequences:** No device ever holds another player's hidden information; the security boundary is one code path with redaction tests (gate checks from P1).

## ADR-0006 — `GameState` is `@_spi(HostOnly)`; bots and UI consume `Observation` only

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §9 (Engine Runtime, Observations, and Redaction), §3 (Module Layout SPI rule).
- **Decision:** The full `GameState` type is exported only under `@_spi(HostOnly)`. Bots, UI, and all non-host code consume `Observation` types. `Tools/check-imports.sh` enforces the allow-list (RulesEngine tests, RulesetKit simulator, TableNet `SessionHost`, Persistence `SaveStore`, `Tools/rules-cli`, test targets).
- **Consequences:** Hidden information is a compile-time boundary, not a convention; violations fail CI.

## ADR-0007 — Card instance IDs assigned post-shuffle per deal; hidden zones expose counts plus known cards

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §4 (Card Model and Decks), §9 (redaction).
- **Decision:** Card instance IDs are assigned after the shuffle, per deal, so IDs carry no information about deck order. Observations of hidden zones expose card counts plus any cards that viewer legitimately knows.
- **Consequences:** No information leaks through ID assignment; redaction tests can assert exact hidden-zone contents per viewer.

## ADR-0008 — xoshiro256** + SplitMix64; Fisher–Yates; Lemire bounded integers; no floats in rules

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §10 (Determinism, Seeded RNG, and Replays); CONVENTIONS §5 (determinism).
- **Decision:** `SeededRNG` is xoshiro256** (Blackman–Vigna) seeded via SplitMix64, a `Codable` struct of four `UInt64`s. Shuffles use Fisher–Yates from the top; bounded integers use Lemire's nearly-divisionless method. No `Float`/`Double`/`CGFloat` in rules or engine state.
- **Consequences:** Bit-identical play across platforms and processes from a seed; golden replays verify cross-platform identity in CI (ARCHITECTURE §10.7).

## ADR-0009 — Network framework 26-series API, Bonjour, TLS 1.3 with per-session self-signed identity; no Multipeer Connectivity

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §12; CONVENTIONS §2 (networking row).
- **Decision:** Local networking uses the Network framework 26-series Swift API: `NetworkListener` + Bonjour on the host, `NetworkBrowser` on clients, `NetworkConnection` with TLS 1.3 over TCP and a `Coder` for `Codable` messages. Each session uses a self-signed identity (certificate) generated per session. Multipeer Connectivity is forbidden (deprecated by Xcode 27 per Apple TN3213).
- **Consequences:** Client-server semantics match the star topology; TLS protects against on-path tampering on shared networks; works on tvOS.

## ADR-0010 — Seed commitment and reveal for verifiable shuffles

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §10.3 (fairness commitment), §12.
- **Decision:** At session start the host publishes `SHA-256(sessionSeed ‖ rulesetHash ‖ sessionID)` to every device. At match end the host reveals `sessionSeed`; any device can verify the commitment and replay the match. Hand devices show "Shuffle verified" in results.
- **Consequences:** Stops a host changing the deck mid-match and lets players audit; does not stop a malicious host from choosing the seed (dealer-less mental poker is out of scope, ROADMAP §5).

## ADR-0011 — SwiftUI for all card rendering; no SpriteKit

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §3 (Module Layout: TableUI, Library, A11yKit (plan: Accessibility) all on SwiftUI), §16 (Accessibility Architecture).
- **Decision:** All card and table rendering is SwiftUI. SpriteKit (and other scene-graph frameworks) are not used.
- **Consequences:** One rendering stack across iPhone, iPad, Mac (and tvOS in P13); accessibility, Dynamic Type, and keyboard interaction come from the platform; card faces are rendered by `CardFaceRenderer` into SwiftUI views.

## ADR-0012 — DDS vendored (Apache-2.0) for bridge; no GPL code (Ben, CardStock)

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §14 (AI Opponents: `BridgeSolver` DDS wrapper); CONVENTIONS §4.4 (allow-list: vendored `dds-bridge/dds`, Apache-2.0; GPL/LGPL/AGPL/unlicensed code forbidden).
- **Decision:** The double-dummy solver for bridge is the DDS port from `dds-bridge/dds` (Apache-2.0), vendored. GPL solvers (Ben, CardStock) are not used.
- **Consequences:** Expert bridge play and post-deal par review are possible without license contamination of the app.

## ADR-0013 — Bots: heuristics, PIMC, SO-ISMCTS, exact tables; observation-only

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §14 (AI Opponents).
- **Decision:** Bot levels use, as appropriate: heuristic policies, PIMC (determinize + perfect-information solve), sample-based ISMCTS (SO-ISMCTS), and exact endgame tables. Bots consume `Observation` only (never `GameState`), maintaining a `BeliefState` over hidden information.
- **Consequences:** Bots are fair opponents (they cannot see hidden cards) and stay inside the determinism rules (search uses seeded sampling).

## ADR-0014 — GameKit real-time for online; turn-based excluded (shared match data)

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §12 (`GameKitTransport` adapts the session protocol onto `GKMatch`).
- **Decision:** Online play uses GameKit real-time matches (`GKMatch`, reliable messages, `chooseBestHostingPlayer` for host election). GameKit turn-based matches are excluded because `matchData` is shared with every participant and would break the redaction boundary.
- **Consequences:** Online sessions keep the same host-authoritative, redacted-observation model as local play.

## ADR-0015 — Tap-to-select-then-play as the universal interaction; drag optional

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §13 (device roles, play interaction), §16 (accessibility play confirmation).
- **Decision:** The universal play interaction is tap-to-select (card lifts, shows a "Play" affordance) then tap again or the button to play. One-tap play is an optional setting for experienced players; drag-to-play is supported but never required.
- **Consequences:** Every game is playable by touch, keyboard, and Switch Control; no game depends on a gesture that accessibility cannot perform.

## ADR-0016 — No turn timers by default

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §16 (accessibility table: turn timer off by default, adjustable 30 s–10 min only if a table explicitly enables it).
- **Decision:** Turn timers are off by default. A table may enable them explicitly (30 s–10 min, adjustable).
- **Consequences:** Casual and accessibility-first play is the default; timed play is opt-in per table.

## ADR-0017 — Original rulebook prose only; sources cited by link

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §17 (Rule Content, Licensing, and Citation).
- **Decision:** All in-app rule text is written originally for Parlor. External sources (Pagat, Hoyle, Bicycle, federation rulebooks, etc.) are cited by link, never copied.
- **Consequences:** No copyright exposure from rulebook text; citations are verifiable.

## ADR-0018 — Apple TV is host + table only; Bonjour + QR for guests

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §18 (Apple TV (tvOS) Plan).
- **Decision:** Apple TV runs the host and the table view only; it never shows a hand. Discovery is Bonjour + full-screen join QR code (primary path for guests); DeviceDiscoveryUI is a convenience for the owner's iCloud family only. The `Parlor-tvOS` target lands in P13, after the host role is proven separable from UI (P9 headless-host acceptance).
- **Consequences:** TV storage limits are handled by CloudKit private-DB saves plus a streamed host save to the owner's phone.

## ADR-0019 — Premium universal purchase, no ads (pending Mahler, Q3)

- **Status:** Accepted with default applied (2026-11-17, P0.6); final pricing pending Mahler (open question Q3)
- **Context:** CONVENTIONS §2 (monetization default); ROADMAP §8 Q3 (default: paid upfront about $9.99, no ads, no subscriptions, Family Sharing on, every game included, no game packs at 1.0); RESEARCH.md (ads are the top complaint in competitor reviews).
- **Decision:** Parlor is a premium, one-price, universal purchase across iPhone, iPad, Mac (and Apple TV). No ads, no subscriptions, no consumables. Optional one-time "Game Pack" purchases only if Mahler chooses. The Q3 default (about $9.99 upfront, Family Sharing on, all games at 1.0) is applied until Mahler decides.
- **Consequences:** No IAP infrastructure at 1.0; pricing decision is deferred to P15 and does not block the build.

## ADR-0020 — JSON files for persistence with schema versions; CloudKit private DB for sync

- **Status:** Accepted (2026-11-17, P0.6)
- **Context:** ARCHITECTURE §19 (Persistence, Stats, and Sync).
- **Decision:** Local persistence is JSON files (`Saves/`, `HouseRules/`, `Profiles/`, `Stats/`, `Replays/`), each with a `schemaVersion`; loaders migrate forward with tested migrations and refuse unknown future versions. Sync (P15) uses the CloudKit private database. Host saves use `NSFileProtectionComplete`.
- **Consequences:** Saves are inspectable and diffable; migration tests are part of the gate checks; no server infrastructure is required.

## ADR-0021 — Rename `Accessibility` package to `A11yKit`

- **Status:** Accepted (2026-11-17, P0.Z)
- **Context:** Apple's `Accessibility.framework` ships a Swift interface (`arm64-apple-ios-simulator.swiftinterface`). Our SPM package named `Accessibility` collides with it: during the explicit-module build of `XCUIAutomation`'s Swift interface (target iOS 17.0), the compiler resolves `import Accessibility` to our module (min deployment iOS 26.0) instead of Apple's (min deployment iOS 17.0), failing the deployment-target check. Disabling explicit modules on the UI-test targets does not help because the implicit module build also resolves `import Accessibility` to our module.
- **Decision:** Rename the package from `Accessibility` to `A11yKit`. Update `Package.swift`, `project.yml`, `Makefile`, `check-imports.sh`, `.swiftlint.yml`, and all import statements. The plan's verbatim copy in `docs/plan/` retains the original name `Accessibility`.
- **Consequences:** The build no longer collides with Apple's framework. The module provides the same functionality (narration, comfort settings, audio cues, table summary). The plan's ARCHITECTURE.md references are documented in ADR-0011 as "A11yKit (plan: Accessibility)".

## ADR-0022 — Gate G0 excludes the macOS UI-test leg; the leg is required again from G9

- **Status:** Accepted (2026-11-18, P0.Z)
- **Context:** The macOS UI-test runner cannot complete its automation handshake on this build host. Evidence: three runs, three failure signatures — (1) pre-reboot 03:22: "Timed out while enabling automation mode" (XCTFuture Code=1000); (2) post-reboot 04:21 in `make gate PHASE=P0`: same timeout; unified-log analysis shows no TCC request for the runner and the app-under-test launched only after the runner gave up (first-launch Gatekeeper/AppIntents work exceeded the 60 s handshake window); (3) post-priming 04:26: runner reaches "Running tests…" then hangs indefinitely and is killed. macOS unit tests pass, both iOS simulator legs (iPhone 17, iPad Pro 13-inch M5) pass including UI tests, and the placeholder UI test has no signal the iOS legs do not already cover. The handshake needs a one-time interactive TCC automation approval, which only the machine's owner can make.
- **Decision:** `test-apps` in the gate runs the two iOS simulator legs only. The macOS UI-test leg moves to a separate target `test-apps-macos-ui`, not part of `gate PHASE=P0`. It returns to the gate when the automation prompt is approved on the host, and macOS UI tests are a hard requirement from G9 onward, so this carve-out cannot silently persist past G8.
- **Consequences:** G0 can go green on this host. If the prompt is never approved, G9's gate will fail on this leg, forcing resolution then. The gap is visible in `docs/STATUS.md` and `docs/KNOWN_ISSUES.md`, not hidden.

## ADR-0023 — Phase branches land on `main` via merge push; no pull requests

- **Status:** Accepted (2026-11-18, P1.Z)
- **Context:** `CONVENTIONS.md` §7 asks for phase branches (`phase/Pn-name`) and gates recorded per phase. The repository's deploy key is limited to read/write on refs and cannot open or merge pull requests, so the PR step of that flow is unavailable to the coding agent. History protection is active: `main` rejects force pushes and `v*` tags, and gate tags (`gate-GN-pass`) are created after evidence is recorded.
- **Decision:** Work happens on `phase/Pn-*` branches pushed to origin. When a phase's gate passes (evidence in `docs/STATUS.md`, tag `gate-GN-pass`), the branch is merged into `main` locally with a regular merge (fast-forward where possible, merge commit otherwise) and pushed — never force-pushed, no history rewrite, `main` kept green. CI runs on every push, so a red `main` blocks the next phase until fixed.
- **Consequences:** The review-branch workflow is effectively "async review after landing" for gates marked GLM-SELF/ASYNC (G1, G2, …), which matches the plan's own sign-off column; blocking reviews (G3, G8) still stop work before their next phase regardless of what has landed.

## ADR-0024 — CardExpr type-checker typing rules (P2.2)

- **Status:** Accepted (2026-11-18, P2.2)
- **Context:** `ARCHITECTURE.md` §7.2/§7.3 list the types, contextual bindings, and builtins, but leave open how optionals, string literals against enum-typed values, def-body scoping, and a few builtin signatures behave. The four reference rulesets pin down the answers (e.g. euchre `colorOf(deal.trump)` passes a `suit?` where `suit` is expected; cribbage `['J','Q','K'].exists(r, r == c.rank)` compares a string literal to a `rank`; cribbage `pone() -> seat: left(dealer, 1)` uses the contextual `dealer` inside a def body; bridge `match.score[opponents(dt)]` indexes a team-scoped var with `opponents`' result).
- **Decision:**
  1. **Optional polymorphism (§7.4):** `T?` is accepted wherever `T` is expected (call arguments, operands, member bases, indexed bases, returns), and `T` where `T?` is declared; the `null` literal unifies with any type. A dereference of `null` is a runtime `engineFault`, not a compile error — validation deliberately does not reject these.
  2. **Stringy literals:** a string literal has the internal type `literalString`, which unifies with `string`, `suit`, `rank`, `phase`, `seat`, and `team` (the string-domained types). It does not unify with `int`, `bool`, `card`, or lists. A non-literal of an enum type never unifies with `string`.
  3. **Def bodies see ambient scope plus canonical contextual bindings:** options, vars, builtins, `players.*`, `deal.index`, all §7.3 contextual names at their canonical types (`dealer`/`seat`/`s`/`awardee`: `seat`, `c`: `card`, `t`: `team`, `call`: `record{id, level?, strain?, alone?}`, `param`: any, `cards`: `list<card>`, `isCrib`: `bool`, `trick.*`: canonical trick record fields), plus the def's own parameters (which shadow). A def that references a mechanic-only binding is therefore accepted at load but faults if evaluated where the mechanic does not bind it (§7.4 fault semantics).
  4. **Signatures:** `opponents(t: team) -> team` (the opposing team, so it can index team-scoped vars), `dealtHands() -> list<list<card>>`, `contract = record{level: int, strain: suit, doubled: bool}`, `card = record{id: string, suit: suit, rank: rank}`.
  5. **`hostOnly` marking:** `holderOf` is always hostOnly; `zone` is hostOnly when the referenced zone's visibility is not `public`, unless the seat argument is exactly the identifier `seat` (the evaluator's own seat). Zone visibility comes from the zones registry passed in the check context. Defs that use a hostOnly construct are tainted; calling a tainted def in the `ai` or `ui` evaluation context is rejected.
  6. **Dotted names:** `.` is postfix member access in the grammar; namespaced natives (`cribbage.handScore`) are member-calls on an otherwise-unbound identifier resolved against the natives registry, and variable namespaces (`match`, `deal`, `options`, `players`, `trick`, and `deal.index`) are member accesses on unbound reserved roots. Def signature strings (`"penalty(c: card) -> int"`) are parsed by the checker; parameter order comes from the signature string, not JSON key order.
- **Consequences:** The checker accepts all four reference rulesets while still catching arity, unknown-name, enum/`int` mixing, and list-element errors at load time. Where it cannot prove safety (mechanic-bound names in def bodies, own-seat zones) it relies on the well-defined §7.4 fault semantics instead of rejecting; this is revisited when the AI phase (P7) specifies its evaluator context.

## ADR-0025 — Standard native scoring semantics (P2.4)

- **Status:** Accepted (2026-11-19, P2.4)
- **Context:** ARCHITECTURE §5.8 fixes the five Wave 1 native signatures but leaves open several semantics the reference rulesets and the P2 tests depend on: the meaning of `bridge.score`'s `total` field, where the Chicago/duplicate game and part-score bonuses go, how `bridge.honors` resolves its team argument, the `rummy.rules` record's field names (not pinned anywhere in the plan), the deadwood value of unused wild cards, the meaning of `wrap` runs, and the boundary between `cribbage.pegPoints` and the `count-play` mechanic's own 31/go/last-card awards.
- **Decision:**
  1. `bridge.score(contract, tricks, vulnerable, mode)`: `contract` is `record{level: int, strain: suit, doubled: bool, redoubled: bool}`; `total` counts the declarer side only (`below + above`); a set contract reports the penalty through `defenders` alone with `below`/`above` 0 (the Chicago overlay awards both sides from these fields). Chicago and duplicate score the per-deal game (300/500 by vulnerability) and part-score (50) bonus into `above`; rubber leaves accumulated part-game bonuses to the match store. Slam bonuses and the insult (50 doubled / 100 redoubled) score in every mode.
  2. `bridge.honors(hands, trump, team)`: the team argument resolves against the teams list the host installs via `StandardNatives.all(teams:)`; team index `i` owns the alternating seats `j % 2 == i` (§5.4 partnership seating). Awards 100 for four trump honors, 150 for five, 150 for all four aces at notrump; an unknown team name faults.
  3. `rummy.rules` record fields (unpinned by the plan): `record{minSet: int, minRun: int, aceHigh: bool, wrap: bool, wildRanks: list<string>}`; result record `rummy.meldResult` = `record{melds: list<list<card>>, deadwood: int}`.
  4. `rummy.melds` returns an optimal partition: minimal deadwood, ties broken by the first partition the deterministic search reaches. Sets need at least `minSet` cards of one rank with at least one natural; runs need at least `minRun` consecutive distinct ranks in one suit under the declared order (ace low or high; circular windows when `wrap` is true), gaps filled by wilds, at least one natural per meld. Unused wilds contribute 0 deadwood (the plan pins no value). Input must be at most 17 cards with unique ids.
  5. `cribbage.pegPoints(sequence)` scores only what the last played card creates from the count run since the last reset: a fifteen when the running total is exactly 15 (2 points), pairs royal among cards of the last card's rank (2 per pair), and the longest valid suffix run (1 point per rank × the product of per-rank multiplicities). The `count-play` mechanic owns the 31 award, `go`, and last-card points (CRB-4.3) — the native never awards them.
- **Consequences:** The P2.4 test suite pins all of the above. Ruleset authors needing different rummy field names or run semantics address that in a ruleset definition, not a native change; revisit only if a catalogued game requires it.
- **Addendum (2026-11-19, after full-suite debugging):** two input-validation decisions pinned by the fault tests: `cribbage.handScore` faults when the four-card hand repeats a suit+rank or the starter duplicates a hand card (scoring is undefined otherwise; Cribbage deals disjoint cards), and `bridge.honors` faults on a trump string outside C/D/H/S (null stays notrump).

## ADR-0026 — Schema shapes are closed; unknown keys fail decode (P2.5)

- **Status:** Accepted (2026-11-19, P2.5)
- **Context:** During decode a struct must choose between silently carrying unknown keys through decode/encode (an `extras` ride-through, the initial P2.5 design) and rejecting them. ARCHITECTURE's posture is strict — unknown future `schemaVersion`s are refused with a clear message and evolution happens through tested migration functions — and the P2.7 validator exists precisely to catch author mistakes, which a silent ride-through would hide (a typo like `payoffs` for `payoff` would decode, round-trip, validate, and only misbehave at the table). The four reference rulesets and two overlays contain only known keys, so the round-trip acceptance does not need tolerance.
- **Decision:** Every schema struct's decode ends with `reader.rejectLeftovers()`; any unconsumed key throws `SchemaError.wrongType` naming the leftover keys and the document path. The `extras` field and ride-through mechanism are removed. Deliberately open data stays where the schema declares it (house-overlay `options` is a raw keyed object, notes and sources are strings).
- **Consequences:** Adding a field to a ruleset means a `schemaVersion` bump plus a migration function, not silent acceptance; malformed documents fail loudly at load with the offending path; the round-trip tests still pass unchanged for the reference corpus.

## ADR-0027 — JSON Schema export is a structural mirror, generated and freshness-checked (P2.9)

- **Status:** Accepted (2026-11-19, P2.9)
- **Context:** P2.9 requires machine-readable schemas for editor tooling and CI, generated from the Swift types. A schema that hardcodes full value semantics would be a second source of truth that drifts from the Swift decoder; the Swift validator (P2.7) is already the authority.
- **Decision:** `rules-cli schema` emits Draft 2020-12 schemas (`Resources/Schemas/ruleset.schema.json`, `lesson.schema.json`) that mirror structure and fixed vocabularies (enums, required fields, scopes, effect kinds) but keep free-form types for expressions, params, and any `varDecl.type` values — the Swift validator owns those. `--check` regenerates in memory and compares the pretty form byte-for-byte against the committed files, failing on drift. CI runs both `make schema-check` and `scripts/validate-schemas.py` (Python `jsonschema`, 2020-12), which validates the exported schemas themselves and all four reference rulesets against them; Python jsonschema is CI-only and never a build dependency.
- **Consequences:** Adding a schema field in Swift without regenerating the export fails CI (`schema-check`), forcing the mirror to stay current. External tools get honest structure validation; semantic validation still requires the Swift tool. The mirror declares `required`, enums, and scopes but does not set `additionalProperties`, so it is deliberately looser than decode (ADR-0026 closes decode on unknown keys); the Swift validator remains the strict layer.

## ADR-0028 — Score choices pend per seat, in any order (P3.1)

- **Status:** Accepted (2026-11-20, P3.1 mechanic test wave)
- **Context:** `ScoreMechanic` supports several `choices[]` gating one scoring run (hearts' moon shooter is the reference). The first implementation resolved "the" pending choice by scanning `phaseOptions` for any non-empty `pending:<id>` — with two choices active, which seat was asked first depended on Swift's per-process String hashing, so the same seed and action list could be legal in one process and `notYourTurn` in another (§10 replay hazard). The same scan also silently skipped choices whose `when` gate evaluated to a non-bool, inconsistent with every other mechanic faulting loudly on mistyped expressions.
- **Decision:** Choices pend per seat: `pendingSeats` returns every seat that owes a choice, `legalIntents`/`apply` resolve the asking seat's own choice deterministically (iterating `params.choices` in declared order), and the effects run once when no seat owes anything. A non-bool `when` result is an engine fault naming the choice. One-at-a-time sequencing remains available to rulesets by construction (each choice names one seat); parallel answering is now also legal.
- **Consequences:** Replay determinism no longer depends on dictionary iteration order; multi-choice scoring (e.g. a moon shot plus a confession) works with seats answering concurrently in the host UI. Pinned by the `ShowScoreTests` suite (gate/settle/multi-choice/fault cases).

## ADR-0029 — Show `cards` binds the pile's own cards; the `with` zone is revealed, not merged (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset wave)
- **Context:** The `show` mechanic's `points` expression receives contextual bindings. `ShowMechanic` initially merged the `with` zone's cards into the `cards` binding (pile + starter for cribbage), but ARCHITECTURE's normative cribbage example calls `cribbage.handScore(cards, zone('starter')[0], isCrib)` — passing `cards` as the 4-card hand and pulling the starter as a single card. With a merged `cards` (5 entries) that call can never satisfy `handScore`'s 4-card signature, and the starter could not be isolated as one card from a merged list at all. The plan example is authoritative; the engine conforms to it.
- **Decision:** `cards` binds only the entry pile's own cards. `with` names a shared zone that is revealed alongside each pile (its cards become public with the first pile and stay public) and remains reachable from expressions through `zone('<id>')[…]`. This matches `cribbage.handScore(hand:starter:isCrib:)`'s signature and keeps nobs/heels logic expressible in rulesets.
- **Consequences:** Rulesets that need the with-zone cards in scoring reference the zone directly (`zone('starter')[0]`), as the plan example already does. Pinned by the cribbage six-card/five-card ruleset simulations (`show.points` faults if the merge returns).

## ADR-0030 — `trick.number` is 1-based, and the trick record is bound at every trick-context eval (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** ARCHITECTURE §7.4's binding table lists `trick.number` without a base (it marks `deal.index` 0-based explicitly), and hearts' `leadAllowed` (`trick.number == 1 ? c.id == '2C'`, with `firstLeader: holderOf('2C')`) pins the semantics: the first trick's number is 1. Two engine gaps surfaced in the 500-seed battery: the simulator's env trick snapshot bound `number` from the 0-based `trickIndex`, and the trick mechanic bound no `trick` record at all during legality evaluation or at trick end (only `winner`/`index` at end), so `trick.*` in guard expressions silently evaluated against the stale/absent snapshot.
- **Decision:** `trick.number` is 1-based everywhere (`trickIndex + 1`). `TrickPlayMechanic` binds the full contextual record — `number`, `leader`, `cards`, `ledSuit`, `winner` — wherever trick-context expressions evaluate: lead and follow legality (`playAllowed`), `nextLeader`, and trick-end effects (winner filled, cards/ledSuit captured before the trick is archived). The env snapshot remains the phase-level fallback and now agrees with the record.
- **Consequences:** Guard expressions keyed on the first trick (hearts' 2C lead and no-points-first-trick, and any future game using `trick.number`) behave as written; the hearts 500-seed stall (seeds 495–499) is gone. Pinned by the RulesEngine trick tests and the ruleset battery.


## ADR-0031 — Claim legal branches mirror `applyClaim` gates exactly (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** `TrickPlayMechanic` supports pending card-claims (`claimVotes`). Random-legal simulation faulted with `notYourTurn` at the claim step: the `legalIntents` branches offered `acceptClaim` to seats that had already voted, and the proposal branch did not reproduce every gate `applyClaim` checks, so an intent that passed `legalIntents` could still fail in `apply`.
- **Decision:** Every legal branch mirrors the `applyClaim` gates exactly: the proposal branch applies the same gates as `applyClaim`'s proposal path, and both proposal and accept branches exclude seats already present in `claimVotes` (`!claimVotes.contains(seat)`). A seat that has voted is never offered a claim intent again.
- **Consequences:** `legalIntents` is exactly the inverse of `apply`'s fault conditions for claims; bridge (all three variants) no longer faults during claims. Pinned by the ruleset battery (500 seeds × bridge rubber/chicago/duplicate).

## ADR-0032 — `PhaseOutcome.autoStep` lets a mechanic expose internal automatic steps (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** Cribbage's show phase scores multiple entries (hand, crib, starter) as one `show` intent, and per-ARCHITECTURE the entries' results are announced stepwise, with the deal possibly terminating between steps (one player reaching the game hole ends the deal before the remaining entries). Scoring all entries atomically inside `apply` skipped the mid-show termination check, producing ties in 500-seed play.
- **Decision:** `Mechanic.step` + `PhaseOutcome.autoStep` allow a mechanic to return additional automatic steps that the engine runs like user-driven actions: `ScoreMechanic` scores one entry per `step`, and the engine re-enters the same legality/termination checks between steps (each step can end the deal, which stops further steps). No new intent kind is exposed to rulesets or UI.
- **Consequences:** Mid-show termination now behaves per the plan; the cribbage "tied at" faults are gone (both cribbage rulesets pass 500 seeds). Future mechanics with internal sequences (e.g. staged scoring) reuse the same channel.

## ADR-0033 — Engine retains the completed trick record for score-phase expressions (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** `tricksWon(...)` and the §7.3 builtins read the trick substate's cumulative counts, but at score time the phase is no longer `.trick`, so the snapshot was empty and every declarer scored 0 tricks — bridge's rubber never reached two games and a random-legal sim could not finish within the action cap even at 60,000.
- **Decision:** The engine retains the completed trick-play substate in `GameState.lastPlaySubstate: TrickSubstate?`, saved when the play phase hands off to scoring and in `finishDeal`, cleared on per-deal reset, and included in hash/equality. The environment's `trickSnapshot` falls back to `state.lastPlayTrick()` when the live phase is not `.trick`. The field is host-side only: the redactor never copies it into `Observation`.
- **Consequences:** Score-phase expressions see the deal's cumulative trick counts as the play phase left them; bridge rubber completes (`deals=4`, `games@0=2`, `above@0=4200`, `below=0` on the probe seed). Golden-replay fixtures were regenerated because the field participates in the state hash. Hidden-information discipline is unaffected (never leaves the host).

## ADR-0034 — Host-side dealt record backs `dealtHands()`; scalar Int keys (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** ARCHITECTURE L1308 defines `dealtHands()` as host-side full state: the dealt hand = current hand ∪ played cards. Bridge scoring expressions consume it, but nothing retained the dealt cards once a zone shrank, so `dealtHands()` returned empty lists.
- **Decision:** `DealMechanic.enter` records every dealt card in `GameState.dealt: [Int: [CardInstance]]` (keyed by `Seat.raw`, the scalar key type required for canonically sorted JSON encoding — §10.4), cleared on per-deal reset. The `dealtHands` environment closure derives each seat's hand as the recorded dealt cards that are still in the seat's hand zone (hand ∪ played = recorded set; membership filtered by the current zone). It returns a flat `[Value]` array of per-seat card lists — one entry per seat — because bridge scoring indexes hands directly. The field is host-side only and never copied into `Observation`.
- **Consequences:** Bridge scoring sees full hands; an earlier `[Seat: …]` key type broke golden-replay hashing (unordered pair-array encoding) and was rejected in favor of scalar keys. Pinned by the bridge ruleset battery.

## ADR-0035 — `otherwise: "any"` fallback when guards empty the candidate set (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** ARCHITECTURE §6.1 requires a deterministic fallback when an auto-guard (`auto`/`legal` guards on candidates) filters the candidate set to empty and the ruleset declares one. Hearts' 500-seed battery stalled on seeds 495–499: a position existed where every candidate card was filtered out and no fallback was implemented, so the simulator capped out.
- **Decision:** When guard filtering empties the candidate set and the guard declares `otherwise: "any"`, the engine falls back to the whole unfiltered candidate list (deterministic first element under the seeded RNG). Without the declaration the empty set remains a fault.
- **Consequences:** Hearts completes under random play on all seeds; rulesets opt into the fallback explicitly, so silently illegal plays cannot creep in.

## ADR-0036 — Auction param calls bind the value canonically as `param` (P3.3)

- **Status:** Accepted (2026-11-21, P3.3 ruleset battery)
- **Context:** ARCHITECTURE L816's euchre example declares a named param (`"param": "suit"`) but reads the value through the canonical binding `param` (`"allowed": "param != zone('discard')[0].suit"`), and L1310 lists `param` as a canonical contextual binding "bound by the mechanic evaluating the expression". `AuctionRoundsMechanic` bound only the declared name, so euchre's second-round naming faulted with `param not bound` on every seed that reached round 2 (~5% of games).
- **Decision:** For every auction param call, `AuctionRoundsMechanic` binds the candidate/applied value both under the declared param name and canonically as `param`, in the menu evaluation (`legalParams`) and in `apply` (allowed re-check and effects).
- **Consequences:** Expressions may use either the declared name or `param`; euchre standard and canadian-loner pass 500 seeds. Rulesets that declare a param literally named `param` are unaffected (both keys coincide).
