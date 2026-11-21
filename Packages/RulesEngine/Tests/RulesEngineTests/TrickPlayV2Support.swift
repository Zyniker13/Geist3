import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

// Shared fixtures and helpers for the trick-play v2 suites, kept in an
// extension so each type body stays under the lint limit.
extension TrickPlayV2Tests {
    // MARK: - Fixture

    static func euchreDeck() -> [CardFace] {
        // Pop order per seat; the dealer pops the stock tail, so the deck
        // is stored reversed.
        let pops: [(String, String)] = [
            ("c", "9"), ("c", "10"), ("c", "J"), ("h", "J"), ("h", "10"), ("h", "9"),
            ("d", "A"), ("d", "K"), ("d", "Q"), ("d", "J"), ("d", "10"), ("s", "9"),
            ("c", "A"), ("c", "K"), ("c", "Q"), ("h", "A"), ("h", "K"), ("h", "Q"),
            ("s", "A"), ("s", "K"), ("s", "Q"), ("s", "J"), ("s", "10"), ("d", "9"),
        ]
        return pops.reversed().map { CardFace(suit: Suit($0.0), rank: Rank($0.1)) }
    }

    static func hand(_ state: GameState, _ seat: Seat) -> [CardInstance] {
        state.zones.cards(in: ZoneKey(scope: .seat, owner: seat.raw, id: "hand"))
    }

    static func card(_ state: GameState, _ seat: Seat, suit: String, rank: String) -> CardID {
        let hit = hand(state, seat).first { $0.face.suit?.code == suit && $0.face.rank.code == rank }
        return hit?.id ?? CardID(UInt16.max)
    }

    static func euchreEngine(
        claims: TrickPlayParams.ClaimsSpec? = nil,
        dummy: TrickPlayParams.DummySpec? = nil,
        trickCount: Int? = nil,
        follow: TrickPlayParams.Follow? = nil,
        activeSeats: SeatListOrExpr? = nil,
        firstLeader: SeatOrExpr? = nil,
        nextLeader: ExprRef? = nil,
        trump: SuitOrExpr? = nil,
        winner: TrickPlayParams.WinnerSpec? = nil,
        suitOf: ExprRef? = nil,
        strength: ExprRef? = nil,
        leadAllowed: TrickPlayParams.PlayGuard? = nil,
        playAllowed: TrickPlayParams.PlayGuard? = nil,
        onCardPlayed: [EngineEffect] = [],
        onTrickEnd: [EngineEffect] = []
    )
        -> Engine
    {
        let deal = AnyMechanic(
            DealMechanic.self,
            params: DealParams(
                source: "stock",
                packets: [
                    DealPacket(to: Seat(0), each: 6), DealPacket(to: Seat(1), each: 6),
                    DealPacket(to: Seat(2), each: 6), DealPacket(to: Seat(3), each: 6),
                ],
                shuffleFirst: false,
                deckFaces: euchreDeck()))
        let trickMechanic = AnyMechanic(
            TrickPlayMechanic.self,
            params: TrickPlayParams(
                seatCount: 4,
                tricks: .count(trickCount ?? 6),
                orderRanks: ["9", "10", "J", "Q", "K", "A"],
                follow: follow ?? TrickPlayParams.Follow(mustFollow: true, ruleId: "euch.follow"),
                leadAllowed: leadAllowed,
                playAllowed: playAllowed,
                suitOf: suitOf,
                strength: strength,
                trump: trump ?? .suit("d"),
                activeSeats: activeSeats,
                firstLeader: firstLeader,
                nextLeader: nextLeader,
                winner: winner ?? .highestTrumpElseLed,
                dummy: dummy,
                claims: claims,
                onCardPlayed: onCardPlayed,
                onTrickEnd: onTrickEnd))
        return Engine(
            phases: [
                PhaseConfig(id: "deal", mechanic: deal),
                PhaseConfig(id: "tricks", mechanic: trickMechanic),
            ],
            seatCount: 4,
            // Host expression runtime (§7.5): a minimal evaluator that
            // answers exactly the expressions this fixture uses. The
            // runtime itself is a host component, tested elsewhere; here
            // it only unblocks the claims/guard expressions.
            expressionRuntime: { (call: EvalCall, _: GameState) throws(EvalFailure) -> EvalValue in
                try testRuntime(call)
            })
    }

    /// Shared canned expression runtime for the v2 fixtures.
    static func testRuntime(_ call: EvalCall) throws(EvalFailure) -> EvalValue {
        switch call.source {
        case "true":
            return .bool(true)
        case "['S2', 'S3', 'S4']":
            return .list([.string("S2"), .string("S3"), .string("S4")])
        case "['S2']":
            return .list([.string("S2")])
        case "dealTrump":
            return .string("s")
        case "fixedS4":
            return .string("S4")
        case "leftBower":
            // The euchre left bower: the jack of the same colour as trump.
            // This fixture's trump is diamonds, so the jack of hearts and
            // any real trump-card binding count as diamonds.
            guard case .card(let id, let suit, let rank)? = call.contextual["c"] else {
                throw .fault(pointer: call.pointer, detail: "test runtime: no card bound")
            }
            if rank == "J" && suit.uppercased() == "H" { return .string("d") }
            let lower = suit.lowercased()
            return .string(lower == "t" ? "d" : lower)
        case "spadeAceBeatsAll":
            // A "pet card" strength: the ace of spades outranks everything,
            // everything else keeps the default rank order.
            guard case .card(_, let suit, let rank)? = call.contextual["c"] else {
                throw .fault(pointer: call.pointer, detail: "test runtime: no card bound")
            }
            if suit.uppercased() == "S" && rank == "A" { return .int(100) }
            let order = ["9": 0, "10": 1, "J": 2, "Q": 3, "K": 4, "A": 5]
            return .int(Int64(order[rank] ?? -1))
        case "noTrumpLead", "noTrumpFollow":
            // A guard over the candidate card: forbid diamonds/trumps.
            guard case .card(_, let suit, _)? = call.contextual["c"] else {
                throw .fault(pointer: call.pointer, detail: "test runtime: no card bound")
            }
            let upper = suit.uppercased()
            return .bool(!(upper == "D" || upper == "T"))
        case "secondPlayer":
            // A custom winner: the second player always wins.
            guard case .list(let plays)? = call.contextual["plays"], plays.count >= 2 else {
                throw .fault(pointer: call.pointer, detail: "test runtime: no plays bound")
            }
            guard case .record(_, let fields) = plays[1],
                case .string(let seat)? = fields["seat"]
            else {
                throw .fault(pointer: call.pointer, detail: "test runtime: bad play record")
            }
            return .string(seat)
        default:
            throw .fault(
                pointer: call.pointer,
                detail: "test runtime: unsupported expression '\(call.source)'")
        }
    }

    /// A trick-play engine over a fixed deal: each entry in `pops` is one
    /// seat's pop order as (suit, rank) pairs (the dealer pops the stock
    /// tail, so the deck is stored reversed). The trick phase runs `params`
    /// verbatim, so every test controls the exact configuration.
    static func miniEngine(
        pops: [[(String, String)]],
        params: TrickPlayParams
    ) -> Engine {
        let deckFaces = (pops.flatMap { $0 }).reversed().map { CardFace(suit: Suit($0.0), rank: Rank($0.1)) }
        let deal = AnyMechanic(
            DealMechanic.self,
            params: DealParams(
                source: "stock",
                packets: pops.enumerated().map { seat, cards in
                    DealPacket(to: Seat(seat), each: cards.count)
                },
                shuffleFirst: false,
                deckFaces: deckFaces))
        let trickMechanic = AnyMechanic(TrickPlayMechanic.self, params: params)
        return Engine(
            phases: [
                PhaseConfig(id: "deal", mechanic: deal),
                PhaseConfig(id: "tricks", mechanic: trickMechanic),
            ],
            seatCount: pops.count,
            expressionRuntime: { (call: EvalCall, _: GameState) throws(EvalFailure) -> EvalValue in
                try testRuntime(call)
            })
    }

    static func play(_ engine: Engine, _ state: inout GameState, _ seat: Seat, _ cardID: CardID) throws {
        state = try engine.apply(
            Action(seat: seat, intent: .play(cardID), expectedVersion: state.version), to: state
        ).state
    }

    static func trickSub(_ state: GameState) -> TrickSubstate? {
        if case .trick(let sub)? = state.phase.substate { return sub }
        return nil
    }

    // MARK: - S6: remaining trick-play parameters

    /// Applies a play action and returns the transition's events.
    @discardableResult
    static func playEvents(
        _ engine: Engine, _ state: inout GameState, _ seat: Seat, _ cardID: CardID
    ) throws -> [GameEvent] {
        let transition = try engine.apply(
            Action(seat: seat, intent: .play(cardID), expectedVersion: state.version), to: state)
        state = transition.state
        return transition.events
    }

    /// Runs `body`, expecting a `RuleViolation`. Returns nil when nothing was
    /// thrown; otherwise a short description for the caller's assertion.
    static func violation(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            // Untyped catch + body downcast: Swift 6.3.3 crashes in SILGenCleanup
            // on `catch let e as RuleViolation` (see ConformanceHarness.swift).
            guard let violation = error as? RuleViolation else {
                return "unexpected error type: \(error)"
            }
            return describe(violation)
        }
    }

    static func describe(_ violation: RuleViolation) -> String {
        switch violation {
        case .engineFault(_, let pointer):
            return "engineFault: \(pointer)"
        case .illegal(let ruleId, let detail):
            return "illegal: \(ruleId) \(detail)"
        case .notYourTurn(let expected):
            return "notYourTurn: \(expected)"
        case .staleVersion(let current):
            return "staleVersion: \(current)"
        }
    }
}
