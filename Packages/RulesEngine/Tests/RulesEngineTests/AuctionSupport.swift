import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

// Shared fixtures for the auction mechanic suites (auction.rounds shaped
// like euchre's two-round make, auction.ladder shaped like bridge's
// auction). Kept in an extension so each type body stays under the lint
// limit.
extension AuctionTests {
    // MARK: - auction.rounds fixture

    /// A euchre-shaped rounds auction: round `orderUp` offers pass/orderUp,
    /// round `nameTrump` offers pass/name:<suit>; ordering up sets
    /// `deal.trump` from the upcard, naming sets it from the param; onCall
    /// records `deal.maker` and `deal.alone`.
    static func roundsEngine(
        stickPass: Bool = false, alone: String? = "aloneOn", allPass: String = "redealNext"
    ) -> Engine {
        let trump = EngineEffect.set(name: "deal.trump", index: nil, value: "upcardSuit")
        let nameTrump = EngineEffect.set(name: "deal.trump", index: nil, value: "suit")
        let onMaker = EngineEffect.set(name: "deal.maker", index: nil, value: "seat")
        let onAlone = EngineEffect.set(name: "deal.alone", index: nil, value: "callAlone")
        let turnDown = EngineEffect.move(
            from: "upcard", to: "discard", owner: nil, cards: .all)
        let passAllowed: ExprRef? =
            stickPass
            ? ExprRef(pointer: "/phases/bid/allowed", source: "noPassForDealer") : nil
        let params = AuctionRoundsParams(
            firstBidder: ExprRef(pointer: "/phases/bid/firstBidder", source: "leftOfDealer"),
            rounds: [
                .init(
                    id: "orderUp", ruleId: "EUC-2.1",
                    calls: [
                        .init(id: "pass", ruleId: "EUC-2.1"),
                        .init(id: "orderUp", ruleId: "EUC-2.1", sets: [trump], alone: aloneExpr(alone)),
                    ]),
                .init(
                    id: "nameTrump", ruleId: "EUC-2.3",
                    before: [turnDown],
                    calls: [
                        .init(id: "pass", allowed: passAllowed, ruleId: "EUC-2.4"),
                        .init(
                            id: "name",
                            allowed: ExprRef(
                                pointer: "/phases/bid/allowed", source: "paramNotDiscard"),
                            ruleId: "EUC-2.3",
                            param: "suit",
                            paramValues: ["S", "H", "D", "C"],
                            sets: [nameTrump], alone: aloneExpr(alone)),
                    ]),
            ],
            onCall: [onMaker, onAlone],
            endWhen: ExprRef(pointer: "/phases/bid/endWhen", source: "trumpNamed"),
            allPass: ExprRef(pointer: "/phases/bid/allPass", source: allPassWord(allPass)))
        return auctionEngine(
            bid: AnyMechanic(AuctionRoundsMechanic.self, params: params),
            dealVars: [
                "trump": dealVar("trump", scope: .deal, type: "suit?"),
                "maker": dealVar("maker", scope: .deal, type: "seat?"),
                "alone": dealVar("alone", scope: .deal, type: "bool"),
            ])
    }

    static func aloneExpr(_ source: String?) -> ExprRef? {
        source.map { ExprRef(pointer: "/phases/bid/alone", source: $0) }
    }

    static func allPassWord(_ word: String) -> String {
        switch word {
        case "redealNext": return "redealNextDealer"
        case "redealSame": return "redealSameDealer"
        default: return word
        }
    }

    static func dealVar(_ name: String, scope: EngineVarScope, type: String) -> EngineVarDecl {
        EngineVarDecl(name: name, scope: scope, type: type, isHidden: false, initial: .null)
    }

    // MARK: - auction.ladder fixture

    /// A bridge-shaped ladder: levels 1–7 over the C/D/H/S/NT order, with
    /// pass/double/redouble, three-pass end, and result writes into
    /// `deal.contract` / `deal.declarer`.
    static func ladderEngine(allPass: String = "redealNext", passes: Int? = 3) -> Engine {
        let params = AuctionLadderParams(
            minLevel: 1, maxLevel: 7,
            strainOrder: ["C", "D", "H", "S", "NT"], ladderRuleId: "BRG-2.2",
            extraCalls: ["pass", "double", "redouble"], doubleRuleId: "BRG-2.3",
            consecutivePasses: passes, endRuleId: "BRG-2.4",
            allPass: ExprRef(pointer: "/phases/auction/allPass", source: allPassWord(allPass)),
            allPassRuleId: "BRG-2.6",
            contractPath: "deal.contract", declarerPath: "deal.declarer",
            declarerRuleId: "BRG-2.5")
        return auctionEngine(
            bid: AnyMechanic(AuctionLadderMechanic.self, params: params),
            dealVars: [
                "contract": dealVar("contract", scope: .deal, type: "contract?"),
                "declarer": dealVar("declarer", scope: .deal, type: "seat?"),
            ],
            teamOfSeat: [0, 1, 0, 1])
    }

    /// Shared engine shell: a deal phase (so the auction starts on entered
    /// state) followed by the auction phase; zones and the upcard are laid
    /// by `setup` because the auction fixture needs no real deal.
    static func auctionEngine(
        bid: AnyMechanic, dealVars: [String: EngineVarDecl],
        teamOfSeat: [Int] = []
    ) -> Engine {
        let setup: @Sendable (inout GameState) throws -> Void = { state in
            state.zones.ensureDeclared(ZoneKey(scope: .shared, id: "upcard"), capacity: 1)
            state.zones.ensureDeclared(ZoneKey(scope: .shared, id: "discard"), capacity: 1)
            // The upcard: the queen of clubs, face up to everyone.
            let up = CardInstance(id: CardID(0), face: CardFace(suit: Suit("C"), rank: Rank("Q")))
            try state.zones.place(up, in: ZoneKey(scope: .shared, id: "upcard"))
            state.knowledge.reveal(up.id, to: SeatSet((0..<4).map(Seat.init)))
        }
        return Engine(
            phases: [
                PhaseConfig(id: "deal", mechanic: AnyMechanic(IdleMechanic.self, params: IdleParams())),
                PhaseConfig(id: "bid", mechanic: bid),
            ],
            seatCount: 4, setup: setup,
            expressionRuntime: { (call: EvalCall, state: GameState) throws(EvalFailure) -> EvalValue in
                try auctionRuntime(call, state)
            },
            vars: dealVars, seatNames: ["S1", "S2", "S3", "S4"], teamOfSeat: teamOfSeat)
    }

    /// The canned auction expression runtime: answers exactly the sources
    /// the fixtures use (§7.5 pattern from the trick-play suites).
    static func auctionRuntime(_ call: EvalCall, _ state: GameState) throws(EvalFailure) -> EvalValue {
        // Bindings the mechanic hands to the call site resolve first — the
        // production runtime consults `contextual` the same way, so seat,
        // param and result values never need canned cases here.
        if let bound = call.contextual[call.source] { return bound }
        let dealer = "S\(state.dealer.raw + 1)"
        switch call.source {
        case "leftOfDealer":
            return .string("S\((state.dealer.raw + 1) % 4 + 1)")
        case "noPassForDealer":
            guard case .string(let seat)? = call.contextual["seat"] else {
                throw .fault(pointer: call.pointer, detail: "no seat bound")
            }
            return .bool(seat != dealer)
        case "paramNotDiscard":
            guard case .string(let param)? = call.contextual["suit"] else {
                throw .fault(pointer: call.pointer, detail: "no param bound")
            }
            let key = ZoneKey(scope: .shared, id: "discard")
            let top = state.zones.cards(in: key).first
            return .bool(param != (top?.face.suit?.code ?? ""))
        case "upcardSuit":
            let key = ZoneKey(scope: .shared, id: "upcard")
            guard let top = state.zones.cards(in: key).first else {
                throw .fault(pointer: call.pointer, detail: "upcard is empty")
            }
            return .string(top.face.suit?.code ?? "")
        case "callAlone":
            guard case .record(_, let fields)? = call.contextual["call"],
                case .bool(let alone)? = fields["alone"]
            else {
                throw .fault(pointer: call.pointer, detail: "no call bound")
            }
            return .bool(alone)
        case "trumpNamed":
            return .bool(
                state.dealVars.get(VarPath("trump")) != nil
                    && state.dealVars.get(VarPath("trump")) != .null)
        case "dealer":
            return .string(dealer)
        case "aloneOn":
            guard case .string(let seat)? = call.contextual["seat"] else {
                throw .fault(pointer: call.pointer, detail: "no seat bound")
            }
            // Fixture policy: only the first bidder would go alone.
            return .bool(seat == "S2")
        case "true", "false":
            return .bool(call.source == "true")
        case "redealNextDealer", "redealSameDealer":
            return .string(call.source)
        default:
            throw .fault(
                pointer: call.pointer,
                detail: "test runtime: unsupported expression '\(call.source)'")
        }
    }

    static func dealVarOf(_ state: GameState, _ name: String) -> VarValue? {
        state.dealVars.get(VarPath(name))
    }

    /// The auction sub-state, read through the public phase cursor.
    static func substate(_ state: GameState) -> AuctionSubstate {
        switch state.phase.substate {
        case .auctionRounds(let sub), .auctionLadder(let sub): return sub
        default: return AuctionSubstate()
        }
    }
}

/// A no-op mechanic standing in for the deal phase: the auction fixture
/// needs an entered prior phase, not real dealing.
struct IdleParams: Codable, Hashable, Sendable {}

enum IdleMechanic: Mechanic {
    static let id = "idle"
    typealias Params = IdleParams

    static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] { [] }

    static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] { [] }

    static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState,
        ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] { [] }

    static func isComplete(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> PhaseOutcome { .complete }

    static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet { SeatSet() }
}

extension GameState {
    /// Test-only convenience: the deal vars store read for assertions.
    func dealVar(_ name: String) -> VarValue? {
        dealVars.get(VarPath(name))
    }
}
