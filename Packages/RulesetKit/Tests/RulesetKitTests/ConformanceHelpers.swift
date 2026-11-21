// P3.4 shared helpers: face-based intent tokens the runner resolves at
// apply time (scripts reference cards by FACE, never by ID — IDs are
// assigned fresh each deal), deal-block builders, and a continuation
// entry point for the conformance runner.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) @_spi(HostDealOverride) import RulesetKit
import Testing

/// Thread-safe sentinel registry (final class + NSLock: `static let`
/// references are concurrency-safe, `static var`s are not).
private final class TokenRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var faces: [UInt16: String] = [:]

    func register(_ faceId: String) -> CardID {
        lock.lock()
        defer { lock.unlock() }
        let raw = FaceRef.base + UInt16(faces.count)
        faces[raw] = faceId
        return CardID(raw)
    }

    func face(of raw: UInt16) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return faces[raw]
    }
}

/// A face token for scripted play intents: the runner resolves the token
/// against the live state at apply time, so a state snapshot taken before
/// the deal still addresses the dealt cards (§9.5 fresh IDs each deal).
/// Tokens occupy raw IDs 0xF000…0xF0FF, far above the engine's 0..<65280
/// per-deal assignment range; the face string is registered at token
/// creation and looked up by raw value at resolve time.
enum FaceRef {
    static let base: UInt16 = 0xF000
    /// A `static let` class instance is the concurrency-safe way to hold
    /// mutable shared state (Swift 6 strict concurrency: no global vars).
    private static let registry = TokenRegistry()

    static func id(_ faceId: String) -> CardID {
        registry.register(faceId)
    }

    /// The registered face for a sentinel raw value.
    static func face(of raw: UInt16) -> String? {
        registry.face(of: raw)
    }

    /// Maps a play/discard/pass intent holding sentinels onto the live
    /// state's CardInstances; any unregistered sentinel stays (and faults
    /// loudly at apply time).
    static func resolve(_ intent: ActionIntent, in state: GameState) -> ActionIntent {
        func lookup(_ id: CardID) -> CardID {
            guard id.raw >= base, let face = face(of: id.raw) else { return id }
            for (_, cards) in state.zones.zones {
                if let found = cards.first(where: { $0.face.id == face }) {
                    return found.id
                }
            }
            return id
        }
        switch intent {
        case .play(let id):
            return .play(lookup(id))
        case .pass(let ids):
            return .pass(ids.map(lookup))
        case .discard(let ids):
            return .discard(ids.map(lookup))
        case .meld(let ids):
            return .meld(ids.map(lookup))
        default:
            return intent
        }
    }
}

enum ConformanceHelpers {
    // MARK: Face blocks (A..2 within one suit)

    static let heartsAto2 = ["AH", "KH", "QH", "JH", "10H", "9H", "8H", "7H", "6H", "5H", "4H", "3H", "2H"]
    static let spadesAto2 = ["AS", "KS", "QS", "JS", "10S", "9S", "8S", "7S", "6S", "5S", "4S", "3S", "2S"]
    static let clubsAto2 = ["AC", "KC", "QC", "JC", "10C", "9C", "8C", "7C", "6C", "5C", "4C", "3C", "2C"]
    static let diamondsAto2 = ["AD", "KD", "QD", "JD", "10D", "9D", "8D", "7D", "6D", "5D", "4D", "3D", "2D"]

    /// The violation layout from DealOverrideSmokeTests: seat 0 holds
    /// AD+AH+spades 3..K, seat 1 holds 2C+hearts K..2, seat 2 holds AC +
    /// diamonds K..2, seat 3 holds clubs K..3 + AS + 2S.
    static var violation52: [String] {
        seatMajor([
            ["AD", "AH", "KS", "QS", "JS", "10S", "9S", "8S", "7S", "6S", "5S", "4S", "3S"],
            ["2C", "KH", "QH", "JH", "10H", "9H", "8H", "7H", "6H", "5H", "4H", "3H", "2H"],
            ["AC", "KD", "QD", "JD", "10D", "9D", "8D", "7D", "6D", "5D", "4D", "3D", "2D"],
            ["KC", "QC", "JC", "10C", "9C", "8C", "7C", "6C", "5C", "4C", "3C", "AS", "2S"],
        ])
    }

    /// Seat-major deal order: the first listed seat's block in full, then
    /// the next, and so on (hearts/bridge's single `each: 13` packet).
    static func seatMajor(_ blocks: [[String]]) -> [String] {
        blocks.flatMap { $0 }
    }

    /// A card's ID in a seat's hand (host state, tests only).
    static func card(_ faceId: String, in state: GameState) -> CardID {
        for seat in 0..<8 {
            let hand = state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
            if let found = hand.first(where: { $0.face.id == faceId }) {
                return found.id
            }
        }
        // Shared zones (kitty, upcard, starter…) too: scripts sometimes
        // reference a face that has moved off a hand.
        for (_, cards) in state.zones.zones {
            if let found = cards.first(where: { $0.face.id == faceId }) {
                return found.id
            }
        }
        preconditionFailure("\(faceId) not found in any zone")
    }

    /// SeatSet is a Sequence, not a Collection: the lowest pending seat.
    static func firstPending(_ engine: Engine, _ state: GameState) -> Seat {
        engine.pendingSeats(in: state).min()!
    }

    /// Optional form for scripts that tolerate an empty pending set.
    static func firstPendingOpt(_ engine: Engine, _ state: GameState) -> Seat? {
        engine.pendingSeats(in: state).min()
    }

    /// The seat holding a face in a hand zone (nil when nowhere).
    static func holder(_ faceId: String, in state: GameState) -> Int? {
        for seat in 0..<8 {
            let hand = state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
            if hand.contains(where: { $0.face.id == faceId }) {
                return seat
            }
        }
        return nil
    }
}

extension ConformanceRunner {
    /// Continuation entry: drive steps from an existing state.
    static func play(
        _ steps: [ConformanceStep], engine: Engine, from state: GameState
    ) throws -> SessionOutcome {
        var outcome = SessionOutcome()
        var window: Set<String> = []
        return try Self.play(steps, engine: engine, from: state, window: &window, into: &outcome)
    }

    /// Shared step loop: `window` may carry the start events (steps can
    /// then checkpoint them), `outcome` accumulates across calls.
    private static func play(
        _ steps: [ConformanceStep], engine: Engine, from state0: GameState,
        window: inout Set<String>, into outcome: inout SessionOutcome
    ) throws -> SessionOutcome {
        var current = state0
        for (index, step) in steps.enumerated() {
            window = []
            if let act = step.act {
                let action = Action(
                    seat: act.seat, intent: FaceRef.resolve(act.intent, in: current),
                    expectedVersion: current.version)
                do {
                    let transition = try engine.apply(action, to: current)
                    current = transition.state
                    Self.absorb(transition.events, into: &outcome.fired, and: &window)
                    if step.expectViolation != nil {
                        outcome.failures.append(
                            "step \(index): expected violation \(step.expectViolation!) but the action was accepted")
                    }
                } catch {
                    // Engine.apply throws typed RuleViolation errors; the
                    // untyped catch mirrors the main runner's 6.3.3-safe shape.
                    // Engine.apply throws typed RuleViolation errors; the
                    // untyped catch mirrors the main runner's 6.3.3-safe
                    // shape (no typed-catch binding).
                    let violation = error as RuleViolation
                    let ruleId: String?
                    switch violation {
                    case .illegal(let id, _):
                        ruleId = id
                    case .engineFault(let id, _):
                        ruleId = id
                    case .notYourTurn, .staleVersion:
                        ruleId = nil
                    }
                    if let expect = step.expectViolation, ruleId == expect {
                        outcome.fired.insert(expect)
                        window.insert(expect)
                    } else {
                        outcome.failures.append(
                            "step \(index): " + (ruleId.map { "violation \($0)" } ?? String(describing: violation)))
                    }
                }
            }
            for checkpoint in step.checkpoints {
                Self.checkContinuation(
                    checkpoint, state: current, engine: engine, step: index, window: window, into: &outcome.failures)
            }
        }
        outcome.finalState = current
        return outcome
    }

    /// Checkpoint evaluation for continuations (shares the main checker's
    /// zone/var logic through the same enum cases).
    static func checkContinuation(
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
        case .zone(let owner, let id, let expected):
            let key = owner.map { ZoneKey(scope: .seat, owner: $0, id: id) } ?? ZoneKey(scope: .shared, id: id)
            let actual = state.zones.cards(in: key).map { $0.face.id }
            if actual != expected {
                fail("zone \(id) is \(actual.joined(separator: ",")), expected \(expected.joined(separator: ","))")
            }
        case .zoneCount(let owner, let id, let count):
            let key = owner.map { ZoneKey(scope: .seat, owner: $0, id: id) } ?? ZoneKey(scope: .shared, id: id)
            let actual = state.zones.cards(in: key).count
            if actual != count { fail("zone \(id) has \(actual) cards, expected \(count)") }
        case .varInt(let name, let index, let value):
            Self.checkVar(name, index, .int(value), state: state, fail: fail)
        case .varBool(let name, let index, let value):
            Self.checkVar(name, index, .bool(value), state: state, fail: fail)
        case .varString(let name, let index, let value):
            Self.checkVar(name, index, .string(value), state: state, fail: fail)
        }
    }

    /// Shared var-check body: fetches from the match or deal store and
    /// compares against the expected value of the same kind.
    private static func checkVar(
        _ name: String, _ index: Int?, _ expected: VarValue,
        state: GameState, fail: (String) -> Void
    ) {
        let store = name.hasPrefix("match.") ? state.matchVars : state.dealVars
        guard let actual = store.get(VarPath(name, index)) else {
            fail("var \(name) is unset (expected \(expected))")
            return
        }
        if actual != expected { fail("var \(name) is \(actual), expected \(expected)") }
    }
}

/// The state accessor used by continuation scripts: a helper so suites can
/// read hand contents between steps without reaching into private APIs.
extension GameState {
    /// Card IDs in a seat-scoped hand, in zone order.
    func handOf(_ seat: Int) -> [CardInstance] {
        zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
    }

    /// The face ids of a shared zone.
    func shared(_ id: String) -> [String] {
        zones.cards(in: ZoneKey(scope: .shared, id: id)).map { $0.face.id }
    }
}
