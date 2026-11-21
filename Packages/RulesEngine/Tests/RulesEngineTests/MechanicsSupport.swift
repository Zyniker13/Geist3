import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

// Shared fixtures for the non-auction mechanic suites (P3.1): the
// exchange family, reveal.starter, count-play, show and score. One
// canned expression runtime answers every source the fixtures use;
// engine builders assemble a deal-idle phase, the mechanic under test,
// and a trailing idle phase so completions are observable.

enum MechanicsFixtures {
    // MARK: - Engine shell

    static func makeEngine(
        phases: [PhaseConfig], seats: Int = 4, vars: [String: EngineVarDecl] = [:],
        setup: @escaping @Sendable (inout GameState) throws -> Void
    ) -> Engine {
        Engine(
            phases: phases, seatCount: seats, setup: setup,
            expressionRuntime: { (call: EvalCall, state: GameState) throws(EvalFailure) -> EvalValue in
                try mechanicsRuntime(call, state, seats: seats)
            },
            vars: vars, seatNames: (0..<seats).map { "S\($0 + 1)" }, teamOfSeat: [])
    }

    static func dealPhase() -> PhaseConfig {
        PhaseConfig(id: "deal", mechanic: AnyMechanic(IdleMechanic.self, params: IdleParams()))
    }

    static func idlePhase(_ id: String) -> PhaseConfig {
        PhaseConfig(id: id, mechanic: AnyMechanic(IdleMechanic.self, params: IdleParams()))
    }

    // MARK: - Zones and hands

    static func declareSeat(_ state: inout GameState, seat: Int, zone: String) throws {
        state.zones.ensureDeclared(ZoneKey(scope: .seat, owner: seat, id: zone), capacity: 13)
    }

    static func dealHand(
        _ state: inout GameState, seat: Int, faces: [(String, String)], base: UInt16
    ) throws {
        try declareSeat(&state, seat: seat, zone: "hand")
        var viewers = SeatSet()
        viewers.insert(Seat(seat))
        for (offset, face) in faces.enumerated() {
            let card = CardInstance(
                id: CardID(base + UInt16(offset)),
                face: CardFace(suit: Suit(face.0), rank: Rank(face.1)))
            try state.zones.place(card, in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
            state.knowledge.reveal(card.id, to: viewers)
        }
    }

    /// A shared zone with fixed contents, optionally public to everyone.
    static func sharedZone(
        _ state: inout GameState, _ id: String, cards: [(String, String)],
        base: UInt16, publicToAll: Bool = false, seats: Int = 4
    ) throws {
        state.zones.ensureDeclared(ZoneKey(scope: .shared, id: id), capacity: max(13, cards.count))
        for (offset, face) in cards.enumerated() {
            let card = CardInstance(
                id: CardID(base + UInt16(offset)),
                face: CardFace(suit: Suit(face.0), rank: Rank(face.1)))
            try state.zones.place(card, in: ZoneKey(scope: .shared, id: id))
            if publicToAll {
                state.knowledge.reveal(
                    card.id, to: SeatSet((0..<seats).map(Seat.init)))
            }
        }
    }

    // MARK: - Variables

    static func scoreVar() -> EngineVarDecl {
        EngineVarDecl(name: "score", scope: .seatMatch, type: "int", isHidden: false, initial: .int(0))
    }

    static func matchStringVar(_ name: String) -> EngineVarDecl {
        EngineVarDecl(name: name, scope: .match, type: "string", isHidden: false, initial: .null)
    }

    static func scoreOf(_ state: GameState, _ seat: Int) -> VarValue? {
        state.matchVars.get(VarPath("score", seat))
    }

    static func matchVar(_ state: GameState, _ name: String) -> VarValue? {
        state.matchVars.get(VarPath(name))
    }

    // MARK: - Expression runtime

    /// The canned runtime: contextual bindings resolve first (matching
    /// the production runtime), then integer literals, then the fixture
    /// sources grouped by shape.
    static func mechanicsRuntime(
        _ call: EvalCall, _ state: GameState, seats: Int
    ) throws(EvalFailure) -> EvalValue {
        if let bound = call.contextual[call.source] { return bound }
        if let literal = Int(call.source) { return .int(Int64(literal)) }
        if let flag = flagSource(call.source) { return flag }
        if let zone = zoneSource(call.source) { return .string(zone) }
        if let word = wordSource(call.source, state: state, seats: seats) { return word }
        return try computedSource(call, state, seats: seats)
    }

    /// Boolean-flag sources the fixtures share.
    static func flagSource(_ source: String) -> EvalValue? {
        switch source {
        case "true", "skipAlways", "neverSkip", "moonPossible": return .bool(true)
        case "false", "neverMoon": return .bool(false)
        default: return nil
        }
    }

    /// Zone-id sources the fixtures share.
    static func zoneSource(_ source: String) -> String? {
        switch source {
        case "takeUpcard": return "upcard"
        case "zoneKitty": return "kitty"
        case "zoneCrib": return "crib"
        case "zoneStarter": return "starter"
        default: return nil
        }
    }

    /// Spelling and phase-option sources.
    static func wordSource(
        _ source: String, state: GameState, seats: Int
    ) -> EvalValue? {
        switch source {
        case "dealer": return .string("S\(state.dealer.raw + 1)")
        case "pone": return .string("S\((state.dealer.raw + 1) % seats + 1)")
        case "alwaysHearts": return .string("H")
        case "chosenMoon": return .string(state.phaseOptions["choice:moon:0"] ?? "")
        case "chosenConfess": return .string(state.phaseOptions["choice:confess:1"] ?? "")
        default: return nil
        }
    }

    /// Sources computed from the game state or contextual bindings.
    static func computedSource(
        _ call: EvalCall, _ state: GameState, seats: Int
    ) throws(EvalFailure) -> EvalValue {
        switch call.source {
        case "leftSeat", "rightSeat":
            return .string(neighbor(call, seats: seats, left: call.source == "leftSeat"))
        case "cardValue":
            guard case .card(_, _, let rank)? = call.contextual["c"] else {
                throw .fault(pointer: call.pointer, detail: "no card bound")
            }
            return .int(Int64(cardPoints(rank)))
        case "pegPairs":
            let run = state.zones.cards(in: ZoneKey(scope: .shared, id: "count"))
            guard let last = run.last else { return .int(0) }
            let pairs = run.dropLast().contains { $0.face.rank.code == last.face.rank.code }
            return .int(pairs ? 2 : 0)
        case "handPoints":
            return try handPointsValue(call)
        case "starterIsJack":
            let starter = state.zones.cards(in: ZoneKey(scope: .shared, id: "starter"))
            return .bool(starter.first?.face.rank.code == "J")
        default:
            throw .fault(
                pointer: call.pointer,
                detail: "test runtime: unsupported expression '\(call.source)'")
        }
    }

    /// Points for a shown pile: pip totals plus the crib bonus.
    static func handPointsValue(_ call: EvalCall) throws(EvalFailure) -> EvalValue {
        guard case .list(let cards)? = call.contextual["cards"] else {
            throw .fault(pointer: call.pointer, detail: "no cards bound")
        }
        var total = 0
        for value in cards {
            if case .card(_, _, let rank) = value { total += cardPoints(rank) }
        }
        if case .bool(true)? = call.contextual["isCrib"] { total += 2 }
        return .int(Int64(total))
    }

    /// The seat left or right of the bound `seat` spelling ("S3").
    static func neighbor(_ call: EvalCall, seats: Int, left: Bool) -> String {
        guard case .string(let seat)? = call.contextual["seat"],
            let raw = Int(seat.dropFirst()), raw >= 1
        else { return "S1" }
        let step = left ? 1 : seats - 1
        return "S\(((raw - 1) + step) % seats + 1)"
    }

    /// A=1, face cards=10, pips at face value.
    static func cardPoints(_ rank: String) -> Int {
        switch rank {
        case "A": return 1
        case "J", "Q", "K": return 10
        default: return Int(rank) ?? 0
        }
    }
}
