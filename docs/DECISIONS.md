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
