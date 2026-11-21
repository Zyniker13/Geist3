// P3.4 conformance harness: inject a scripted deal by threading explicit
// faces through the engine's `deckFaces` path with the deal's shuffle
// suppressed (`@_spi(HostDealOverride)` on `EngineBuilder.build`), then
// drive the engine with state-visible script steps and check named
// checkpoints.
//
// Why a stacked deck: every checkpoint must depend on the script, not on a
// seed-dependent shuffle. With `dealOverride` set, the deal phase injects
// the given faces in the exact order listed — the first listed card is
// dealt first. The deal pops from the source zone's end, so the builder
// reverses the list once when stacking the zone.
//
// Deal-order mapping (engine contract, all four shipped rulesets): a
// seat-scoped packet expands to one packet per owner seat in seat order,
// and each packet is drained fully before the next (`dealPackets` +
// DealMechanic's loop). A single `{to: hand, each: N}` packet therefore
// deals seat-major — seat 0's N cards, then seat 1's N, and so on — not
// round-robin. Euchre's three packets (3, 2, kitty 4) expand to nine
// packets in this order: seats 0–3's threes, seats 0–3's twos, then the
// kitty's 4; the deal's `then` moves the kitty top — the LAST listed
// face — to the upcard zone.
//
// For cribbage the deal source is `stock`, so the override stacks the
// stock; the stock's top (its last listed face) is what a top cut takes
// for the starter, and a depth cut picks with the run RNG (fix the seed).
//
// The first-dealer pick draws from the same face list (`drawFace` scans
// the override faces), so a suite must either fix the seed so the pick is
// deterministic or account for the pick's draws. The pick runs in the
// setup closure BEFORE the deal phase injects the stack.
//
// Seat numbering is raw seat N; rotation shape (left/right/alternate) is
// the ruleset's, not the harness's. Deck-size mismatches surface through
// the engine's own fault paths: a short list runs the source dry
// (`deal.empty`), an oversized list leaves cards in the source zone (the
// post-deal card-conservation check faults).
//
// The harness drives `Engine` directly (not `Simulator`): scripted steps
// make action-cap and stall diagnostics unnecessary, and rule coverage is
// computed here against the resolved ruleset's declared rule IDs.
//
// Host-only tooling: none of this crosses the network boundary (§9) — the
// override enters through the host SPI and checkpoints read host-visible
// state only.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) @_spi(HostDealOverride) import RulesetKit

// MARK: - Face builders

/// French-suit face from a rank-suit code pair ("QS", "10H"); the last
/// character is the suit, the rest is the rank.
func face(_ spec: String) -> CardFace {
    let suitCode = String(spec.last!)
    let rankCode = String(spec.dropLast())
    let suit: Suit
    switch suitCode {
    case "S": suit = .spades
    case "H": suit = .hearts
    case "D": suit = .diamonds
    case "C": suit = .clubs
    default: preconditionFailure("unknown suit code \(suitCode) in \(spec)")
    }
    return CardFace(suit: suit, rank: Rank(rankCode))
}

/// Faces from a list of specs.
func faces(_ specs: [String]) -> [CardFace] { specs.map(face(_:)) }

// MARK: - Ruleset loading

enum ConformanceRulesets {
    /// Walks up from this file until it finds `docs/plan/rulesets` (the
    /// plan's ruleset copies; same layout ResolverTests reads).
    static let dir: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("docs/plan/rulesets")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        fatalError("docs/plan/rulesets not found above \(#filePath)")
    }()

    /// Loads a base ruleset (file stem, e.g. "hearts.standard"), optionally
    /// layered with a variant and/or house overlay (full file stem, e.g.
    /// "contract-bridge.chicago"), with optional table options, and resolves
    /// it.
    static func resolved(
        game: String, variant: String? = nil, house: String? = nil,
        tableOptions: [String: JSON] = [:]
    ) throws -> ResolvedRuleset {
        func read(_ name: String) throws -> String {
            try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        let base = try Schema.decodeRuleset(try read("\(game).ruleset.json"))
        let variantDoc = try variant.map { try Schema.decodeOverlay(try read("\($0).variant.json")) }
        let houseDoc = try house.map { try Schema.decodeOverlay(try read("\($0).house.json")) }
        return try Resolver.resolve(base: base, variant: variantDoc, house: houseDoc, tableOptions: tableOptions)
    }

    /// The ruleset's declared rule IDs — the conformance coverage target.
    static func declaredRules(_ resolved: ResolvedRuleset) -> Set<String> {
        Set((resolved.document.rules ?? []).map(\.id))
    }

    /// An engine whose deal phase deals exactly `deal` (face specs in
    /// dealing order); everything else — zones, vars, the first-dealer
    /// pick — is the ruleset's own.
    static func riggedEngine(
        game: String, variant: String? = nil, house: String? = nil,
        tableOptions: [String: JSON] = [:], deal: [String]
    ) throws -> Engine {
        let resolved = try resolved(game: game, variant: variant, house: house, tableOptions: tableOptions)
        return try EngineBuilder.build(from: resolved, dealOverride: faces(deal))
    }
}

// MARK: - Script steps

/// One scripted step: optionally act, then check the (post-action) state.
struct ConformanceStep {
    var act: (seat: Seat, intent: ActionIntent)? = nil
    /// When set, the step's action must be rejected with exactly this rule
    /// id; the rejection also counts the rule as exercised.
    var expectViolation: String? = nil
    var checkpoints: [Checkpoint] = []

    /// Act, then check.
    init(action seat: Seat, _ intent: ActionIntent, _ checks: Checkpoint...) {
        act = (seat, intent)
        checkpoints = checks
    }

    /// Act, expect a specific rule-id rejection, then check.
    init(
        action seat: Seat, _ intent: ActionIntent, expectViolation ruleId: String,
        _ checks: Checkpoint...
    ) {
        act = (seat, intent)
        expectViolation = ruleId
        checkpoints = checks
    }

    /// Check only (an automatic phase advanced between steps).
    init(_ checks: Checkpoint...) {
        checkpoints = checks
    }
}

/// State assertions a step can make (evaluated after the step's action).
enum Checkpoint {
    /// A rule id fired during this step (score event or caught violation).
    /// The window is "since the previous step boundary": the events the
    /// engine produced while starting the session count toward step 0.
    case scored(String)
    /// The phase the state sits in after the step.
    case phase(String)
    /// The seats with a pending action (raw numbers).
    case turn([Int])
    /// The dealer (raw seat).
    case dealer(Int)
    /// The deal counter.
    case dealIndex(Int)
    /// The match's winners in end.rank order (raw seats); empty while play
    /// continues.
    case winners([Int])
    /// A zone's faces in zone order (bottom → top), as face ids ("QS").
    /// Owner nil is a shared zone; otherwise the raw seat owner.
    case zone(Int?, String, [String])
    /// A zone's card count.
    case zoneCount(Int?, String, Int)
    /// A var (name with optional seat/team index) against an expected value.
    /// Names prefixed "match." read the match store, others the deal store.
    case varInt(String, Int?, Int)
    case varBool(String, Int?, Bool)
    case varString(String, Int?, String)
}

// MARK: - Session

/// The result of one scripted session: every failed checkpoint (not
/// first-failure-only), every rule id the run exercised, and the final
/// host state for extra assertions.
struct SessionOutcome {
    var failures: [String] = []
    var fired: Set<String> = []
    var finalState: GameState? = nil
}

/// Drives one scripted game: start once, apply steps in order, collect
/// rule-id firings from score events and caught violations. Multi-deal
/// matches need no special handling — the engine rotates and re-deals
/// inside its automatic advance, and checkpoints key off `dealIndex`.
enum ConformanceRunner {
    static func play(
        _ steps: [ConformanceStep], engine: Engine, seed: UInt64
    ) throws -> SessionOutcome {
        var outcome = SessionOutcome()
        let start = try engine.start(seed: seed)
        var state = start.state
        var window: Set<String> = []
        absorb(start.events, into: &outcome.fired, and: &window)

        for (index, step) in steps.enumerated() {
            window = []
            if let act = step.act {
                let action = Action(
                    seat: act.seat, intent: act.intent, expectedVersion: state.version)
                do {
                    let transition = try engine.apply(action, to: state)
                    state = transition.state
                    absorb(transition.events, into: &outcome.fired, and: &window)
                    if let expect = step.expectViolation {
                        outcome.failures.append(
                            "step \(index): expected violation \(expect) but the action was accepted")
                    }
                } catch {
                    // Downcast in the body instead of `catch let v as RuleViolation`:
                    // Swift 6.3.3 (Xcode 26.6, the CI runner default) crashes in
                    // SILGenCleanup on the typed-catch binding (ownership verifier
                    // fatal error), so keep the catch untyped and bind here.
                    if let violation = error as? RuleViolation {
                        let ruleId = Self.ruleId(of: violation)
                        if let expect = step.expectViolation {
                            if ruleId == expect {
                                outcome.fired.insert(expect)
                                window.insert(expect)
                            } else {
                                outcome.failures.append(
                                    "step \(index): expected violation \(expect), got "
                                        + (ruleId ?? String(describing: violation)))
                            }
                        } else {
                            outcome.failures.append(
                                "step \(index): unexpected violation: "
                                    + (ruleId ?? String(describing: violation)))
                        }
                    } else {
                        outcome.failures.append("step \(index): unexpected error: \(error)")
                    }
                }
            } else if step.expectViolation != nil {
                outcome.failures.append("step \(index): expectViolation without an action")
            }

            for checkpoint in step.checkpoints {
                Self.check(
                    checkpoint, state: state, engine: engine, step: index,
                    window: window, into: &outcome.failures)
            }
        }
        outcome.finalState = state
        return outcome
    }

    private static func absorb(
        _ events: [GameEvent], into fired: inout Set<String>, and window: inout Set<String>
    ) {
        for event in events {
            if case .scored(_, _, _, let ruleId?) = event {
                fired.insert(ruleId)
                window.insert(ruleId)
            }
        }
    }

    private static func ruleId(of violation: RuleViolation) -> String? {
        switch violation {
        case .illegal(let ruleId, _): return ruleId
        case .engineFault(let ruleId, _): return ruleId
        case .notYourTurn, .staleVersion: return nil
        }
    }

    private static func check(
        _ checkpoint: Checkpoint, state: GameState, engine: Engine, step: Int,
        window: Set<String>, into failures: inout [String]
    ) {
        func fail(_ detail: String) { failures.append("step \(step): \(detail)") }
        switch checkpoint {
        case .scored(let ruleId):
            if !window.contains(ruleId) { fail("expected \(ruleId) to fire this step") }
        case .phase(let id):
            if state.phase.phaseID != id { fail("phase is \(state.phase.phaseID), expected \(id)") }
        case .turn(let seats):
            let actual = engine.pendingSeats(in: state).map(\.raw).sorted()
            if actual != seats.sorted() { fail("pending seats \(actual), expected \(seats.sorted())") }
        case .dealer(let raw):
            if state.dealer.raw != raw { fail("dealer is \(state.dealer.raw), expected \(raw)") }
        case .dealIndex(let index):
            if state.dealIndex != index { fail("dealIndex is \(state.dealIndex), expected \(index)") }
        case .winners(let seats):
            let actual = state.winners.map(\.raw)
            if actual != seats { fail("winners \(actual), expected \(seats)") }
        case .zone, .zoneCount:
            checkZone(checkpoint, state: state, step: step, into: &failures)
        case .varInt, .varBool, .varString:
            checkVar(checkpoint, state: state, step: step, into: &failures)
        }
    }

    private static func checkZone(
        _ checkpoint: Checkpoint, state: GameState, step: Int, into failures: inout [String]
    ) {
        func fail(_ detail: String) { failures.append("step \(step): \(detail)") }
        switch checkpoint {
        case .zone(let owner, let id, let expected):
            let actual = state.zones.cards(in: zoneKey(owner, id)).map { $0.face.id }
            let label = owner.map(String.init) ?? "shared"
            if actual != expected {
                fail(
                    "zone \(id)@\(label) is \(actual.joined(separator: ",")), "
                        + "expected \(expected.joined(separator: ","))")
            }
        case .zoneCount(let owner, let id, let count):
            let actual = state.zones.cards(in: zoneKey(owner, id)).count
            let label = owner.map(String.init) ?? "shared"
            if actual != count { fail("zone \(id)@\(label) has \(actual) cards, expected \(count)") }
        default:
            break
        }
    }

    private static func checkVar(
        _ checkpoint: Checkpoint, state: GameState, step: Int, into failures: inout [String]
    ) {
        func fail(_ detail: String) { failures.append("step \(step): \(detail)") }
        switch checkpoint {
        case .varInt(let name, let index, let value):
            guard case .int(let actual)? = varValue(state, name, index) else {
                fail("var \(name)@\(describe(index)) is not an int (expected \(value))")
                return
            }
            if actual != value { fail("var \(name)@\(describe(index)) is \(actual), expected \(value)") }
        case .varBool(let name, let index, let value):
            guard case .bool(let actual)? = varValue(state, name, index) else {
                fail("var \(name)@\(describe(index)) is not a bool (expected \(value))")
                return
            }
            if actual != value { fail("var \(name)@\(describe(index)) is \(actual), expected \(value)") }
        case .varString(let name, let index, let value):
            guard case .string(let actual)? = varValue(state, name, index) else {
                fail("var \(name)@\(describe(index)) is not a string (expected \(value))")
                return
            }
            if actual != value { fail("var \(name)@\(describe(index)) is \(actual), expected \(value)") }
        default:
            break
        }
    }

    private static func zoneKey(_ owner: Int?, _ id: String) -> ZoneKey {
        if let owner { return ZoneKey(scope: .seat, owner: owner, id: id) }
        return ZoneKey(scope: .shared, id: id)
    }

    private static func varValue(_ state: GameState, _ name: String, _ index: Int?) -> VarValue? {
        let store = name.hasPrefix("match.") ? state.matchVars : state.dealVars
        return store.get(VarPath(name, index))
    }

    private static func describe(_ index: Int?) -> String {
        index.map(String.init) ?? "·"
    }
}
