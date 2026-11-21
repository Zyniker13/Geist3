// The `auction.ladder` mechanic (§5.6): one ordered ladder of bids —
// contract bridge's auction is the reference shape (BRG-2.1–BRG-2.6). Each
// seat in turn bids a `(level, strain)` pair higher than the last, or makes
// one of the ruleset's extra calls (pass, double, redouble). Three
// consecutive passes after a bid end the auction (BRG-2.4); all seats
// passing with no bid throws the deal in per the `allPass` action (§5.7).
// The contract record and the declarer (the first seat of the winning side
// to name the final strain, BRG-2.5) are written into the ruleset's
// variables at the end.

import CardModel

/// Parameters for `auction.ladder` (§5.6).
public struct AuctionLadderParams: Codable, Hashable, Sendable {
    /// Who calls first; nil means the dealer (BRG-2.1).
    public let firstBidder: ExprRef?
    public let firstBidderRuleId: String?
    /// Inclusive level range (e.g. `[1, 7]` → min 1, max 7).
    public let minLevel: Int
    public let maxLevel: Int
    /// Strain codes in ascending rank order (e.g. `["C", "D", "H", "S", "NT"]`),
    /// resolved from the ruleset order named by `ladder.strains`.
    public let strainOrder: [String]
    public let ladderRuleId: String?
    /// Extra calls the ruleset offers besides bids (e.g. pass/double/redouble).
    public let extraCalls: [String]
    public let doubleRuleId: String?
    /// Consecutive passes after a bid that end the auction; nil means every
    /// other seat passing once.
    public let consecutivePasses: Int?
    public let endRuleId: String?
    /// Action word when every seat passes with no bid (§5.7).
    public let allPass: ExprRef?
    public let allPassRuleId: String?
    /// Destination variable paths for the result (§5.6 `result`), resolved
    /// at build time; nil writes nothing.
    public let contractPath: String?
    public let declarerPath: String?
    public let declarerRuleId: String?

    public init(
        firstBidder: ExprRef? = nil, firstBidderRuleId: String? = nil,
        minLevel: Int, maxLevel: Int, strainOrder: [String], ladderRuleId: String? = nil,
        extraCalls: [String] = [], doubleRuleId: String? = nil,
        consecutivePasses: Int? = nil, endRuleId: String? = nil,
        allPass: ExprRef? = nil, allPassRuleId: String? = nil,
        contractPath: String? = nil, declarerPath: String? = nil,
        declarerRuleId: String? = nil
    ) {
        self.firstBidder = firstBidder
        self.firstBidderRuleId = firstBidderRuleId
        self.minLevel = minLevel
        self.maxLevel = maxLevel
        self.strainOrder = strainOrder
        self.ladderRuleId = ladderRuleId
        self.extraCalls = extraCalls
        self.doubleRuleId = doubleRuleId
        self.consecutivePasses = consecutivePasses
        self.endRuleId = endRuleId
        self.allPass = allPass
        self.allPassRuleId = allPassRuleId
        self.contractPath = contractPath
        self.declarerPath = declarerPath
        self.declarerRuleId = declarerRuleId
    }
}

/// The `auction.ladder` mechanic (§5.6).
@_spi(HostOnly)
public enum AuctionLadderMechanic: Mechanic {
    public static let id = "auction.ladder"
    public typealias Params = AuctionLadderParams

    static let auctionDefaultRuleId = "auction.ladder"
    static let seatStep = 1
    static let contractRecordName = "contract"

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let turn = try firstBidder(params, state: state, ctx: ctx)
        let sub = AuctionSubstate(turn: turn)
        state.setAuctionSubstate(sub, ladder: true)
        return []
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        let sub = state.auctionSubstate()
        guard sub.turn == seat else { return [] }
        var intents = legalBids(params, sub: sub)
        for call in params.extraCalls where isExtraCallLegal(params, call: call, sub: sub, seat: seat, ctx: ctx) {
            intents.append(.call(call))
        }
        return intents
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState,
        ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var sub = state.auctionSubstate()
        guard let turn = sub.turn, turn == seat, case .call(let tag) = intent else {
            throw RuleViolation.illegal(
                ruleId: auctionDefaultRuleId, detail: .custom("expected a call on turn"))
        }
        var events: [GameEvent] = []
        if let bid = parseBid(tag, params: params, sub: sub) {
            acceptBid(bid, seat: seat, seats: ctx.seatCount, sub: &sub)
        } else if params.extraCalls.contains(tag) {
            try acceptExtraCall(params, tag, seat: seat, sub: &sub, state: &state, ctx: ctx)
        } else {
            throw RuleViolation.illegal(
                ruleId: params.ladderRuleId ?? auctionDefaultRuleId,
                detail: .custom("illegal call \(tag)"))
        }
        events.append(.called(seat: seat, call: tag))
        if sub.ended {
            try writeResult(params, sub: sub, state: &state, ctx: ctx, events: &events)
        }
        state.setAuctionSubstate(sub, ladder: true)
        return events
    }

    public static func isComplete(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> PhaseOutcome {
        let sub = state.auctionSubstate()
        if sub.passedOut { return .redeal }
        if sub.ended { return .complete }
        return .continue
    }

    public static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet {
        let sub = state.auctionSubstate()
        // Once the auction has ended (or passed out) nobody is pending: a
        // non-empty set would stop the engine's automatic phase advance and
        // the .complete / .redeal outcome would never run.
        guard let turn = sub.turn, !sub.ended, !sub.passedOut else { return SeatSet() }
        return SeatSet([turn])
    }

    // MARK: - Legality

    /// Every `(level, strain)` pair ranking above the current winning bid,
    /// offered in ladder order.
    static func legalBids(_ params: Params, sub: AuctionSubstate) -> [ActionIntent] {
        guard params.minLevel <= params.maxLevel else { return [] }
        var intents: [ActionIntent] = []
        let winningRank = sub.winning.map { bidRank($0, params: params) }
        for level in params.minLevel...params.maxLevel {
            for (index, strain) in params.strainOrder.enumerated() {
                let rank = (level, index)
                if let winningRank, rank <= winningRank { continue }
                intents.append(.call("\(level)\(strain)"))
            }
        }
        return intents
    }

    /// Lexicographic bid rank: level first, then the strain's ladder index.
    static func bidRank(_ tag: String, params: Params) -> (Int, Int) {
        guard let bid = parseBidLoose(tag) else { return (0, -1) }
        return (bid.level, params.strainOrder.firstIndex(of: bid.strain) ?? -1)
    }

    /// Extra-call legality: pass is always legal; double only the opponents'
    /// undoubled winning bid; redouble only the owning side's doubled bid
    /// (BRG-2.3). Unknown extra calls are never offered.
    static func isExtraCallLegal(
        _ params: Params, call: String, sub: AuctionSubstate, seat: Seat, ctx: EvalContext
    ) -> Bool {
        switch call {
        case "pass":
            return true
        case "double":
            guard sub.winning != nil, !sub.doubled, let winningSeat = sub.winningSeat else {
                return false
            }
            return teamOf(seat, ctx) != teamOf(winningSeat, ctx)
        case "redouble":
            guard sub.doubled, !sub.redoubled, let winningSeat = sub.winningSeat else {
                return false
            }
            return teamOf(seat, ctx) == teamOf(winningSeat, ctx)
        default:
            return false
        }
    }

    // MARK: - Application

    /// A bid: nil means not a bid tag or illegal (level out of range, strain
    /// off the ladder, or not ranking above the winning bid, BRG-2.2).
    static func parseBid(
        _ tag: String, params: Params, sub: AuctionSubstate
    ) -> (level: Int, strain: String)? {
        guard let bid = parseBidLoose(tag) else { return nil }
        guard (params.minLevel...params.maxLevel).contains(bid.level),
            let strainIndex = params.strainOrder.firstIndex(of: bid.strain)
        else { return nil }
        if let winning = sub.winning {
            guard (bid.level, strainIndex) > bidRank(winning, params: params) else { return nil }
        }
        return bid
    }

    static func parseBidLoose(_ tag: String) -> (level: Int, strain: String)? {
        let digits = tag.prefix { $0.isNumber }
        guard !digits.isEmpty, let level = Int(digits) else { return nil }
        let strain = String(tag.dropFirst(digits.count))
        guard !strain.isEmpty else { return nil }
        return (level, strain)
    }

    /// A new bid wins the auction, clears the doubling state, and resets the
    /// pass count (BRG-2.2, BRG-2.3).
    static func acceptBid(
        _ bid: (level: Int, strain: String), seat: Seat, seats: Int, sub: inout AuctionSubstate
    ) {
        sub.winning = "\(bid.level)\(bid.strain)"
        sub.winningSeat = seat
        sub.doubled = false
        sub.redoubled = false
        sub.passes = 0
        sub.bids.append(AuctionBid(seat: seat, level: bid.level, strain: bid.strain))
        advanceTurn(&sub, seats: seats)
    }

    static func acceptExtraCall(
        _ params: Params, _ tag: String, seat: Seat, sub: inout AuctionSubstate,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) {
        switch tag {
        case "pass":
            sub.passes += 1
        case "double":
            guard sub.winning != nil, !sub.doubled, let winningSeat = sub.winningSeat,
                teamOf(seat, ctx) != teamOf(winningSeat, ctx)
            else {
                throw RuleViolation.illegal(
                    ruleId: params.doubleRuleId ?? auctionDefaultRuleId,
                    detail: .custom("double not allowed"))
            }
            sub.doubled = true
            sub.passes = 0
        case "redouble":
            guard sub.doubled, !sub.redoubled, let winningSeat = sub.winningSeat,
                teamOf(seat, ctx) == teamOf(winningSeat, ctx)
            else {
                throw RuleViolation.illegal(
                    ruleId: params.doubleRuleId ?? auctionDefaultRuleId,
                    detail: .custom("redouble not allowed"))
            }
            sub.redoubled = true
            sub.passes = 0
        default:
            throw RuleViolation.illegal(
                ruleId: params.ladderRuleId ?? auctionDefaultRuleId,
                detail: .custom("unknown call \(tag)"))
        }
        advanceTurn(&sub, seats: ctx.seatCount)
        let needed = params.consecutivePasses ?? max(ctx.seatCount - 1, 1)
        if sub.winning == nil, sub.passes >= ctx.seatCount {
            // All seats passed with no bid: throw the deal in (§5.7).
            sub.passedOut = true
            sub.turn = nil
            try rotateForAllPass(params, state: &state, ctx: ctx)
        } else if sub.winning != nil, sub.passes >= needed {
            sub.ended = true
            sub.turn = nil
        }
    }

    static func advanceTurn(_ sub: inout AuctionSubstate, seats: Int) {
        guard let current = sub.turn, seats > 0 else { return }
        sub.turn = Seat((current.raw + seatStep) % seats)
    }

    /// The `allPass` action word rotates the dealer for redeal words (§5.7).
    static func rotateForAllPass(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) {
        guard let allPass = params.allPass else {
            throw RuleViolation.engineFault(
                ruleId: params.allPassRuleId, pointer: "\(id).allPass missing")
        }
        let value = try ctx.evalCall(
            .init(pointer: "\(id).allPass", source: allPass.source, ruleId: params.allPassRuleId),
            state: state)
        guard case .string(let action) = value else {
            throw RuleViolation.engineFault(
                ruleId: params.allPassRuleId, pointer: "\(id).allPass not an action word")
        }
        switch action {
        case "redeal", "redealNextDealer":
            state.dealer = Seat((state.dealer.raw + seatStep) % ctx.seatCount)
        case "redealSameDealer":
            break
        default:
            throw RuleViolation.engineFault(
                ruleId: params.allPassRuleId, pointer: "\(id).allPass unknown action \(action)")
        }
    }

    /// Writes the contract record and the declarer into the ruleset's
    /// variables through synthesized `set` effects; each reads its own
    /// value binding so the two writes stay independent.
    static func writeResult(
        _ params: Params, sub: AuctionSubstate, state: inout GameState,
        ctx: EvalContext, events: inout [GameEvent]
    ) throws(RuleViolation) {
        guard let winning = sub.winning, let bid = parseBidLoose(winning) else { return }
        var effects: [EngineEffect] = []
        var bindings: [String: EvalValue] = [:]
        if let contractPath = params.contractPath {
            let record = EvalValue.record(
                name: contractRecordName,
                fields: [
                    "level": .int(Int64(bid.level)),
                    "strain": .string(bid.strain),
                    "doubled": .bool(sub.doubled),
                    "redoubled": .bool(sub.redoubled),
                ])
            effects.append(.set(name: contractPath, index: nil, value: contractBinding))
            bindings[contractBinding] = record
        }
        if let declarerPath = params.declarerPath {
            let declarer = declarerFor(params, sub: sub, strain: bid.strain, ctx: ctx)
            effects.append(.set(name: declarerPath, index: nil, value: declarerBinding))
            bindings[declarerBinding] = .string(spelling(declarer, ctx))
        }
        guard let runner = ctx.effects, !effects.isEmpty else { return }
        try runner.run(effects, in: &state, bindings: bindings, events: &events, pointer: "\(id).result")
        if params.contractPath != nil { events.append(.contractSet(winning)) }
    }

    static let contractBinding = "contractValue"
    static let declarerBinding = "declarerValue"

    /// BRG-2.5: the first seat of the winning side who named the final
    /// strain; the winning bidder when nobody else on the side named it.
    static func declarerFor(
        _ params: Params, sub: AuctionSubstate, strain: String, ctx: EvalContext
    ) -> Seat {
        guard let winningSeat = sub.winningSeat else { return Seat(0) }
        let winnerTeam = teamOf(winningSeat, ctx)
        for bid in sub.bids where bid.strain == strain && teamOf(bid.seat, ctx) == winnerTeam {
            return bid.seat
        }
        return winningSeat
    }

    static func teamOf(_ seat: Seat, _ ctx: EvalContext) -> Int {
        ctx.teamOfSeat.indices.contains(seat.raw) ? ctx.teamOfSeat[seat.raw] : seat.raw
    }

    static func spelling(_ seat: Seat, _ ctx: EvalContext) -> String {
        ctx.seatNames.indices.contains(seat.raw) ? ctx.seatNames[seat.raw] : "S\(seat.raw + 1)"
    }

    static func firstBidder(
        _ params: Params, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        guard let spec = params.firstBidder else { return state.dealer }
        let value = try ctx.evalCall(
            .init(
                pointer: "\(id).firstBidder", source: spec.source,
                ruleId: params.firstBidderRuleId),
            state: state)
        guard case .string(let name) = value,
            let index = ctx.seatNames.firstIndex(of: name)
        else {
            throw RuleViolation.engineFault(
                ruleId: params.firstBidderRuleId, pointer: "\(id).firstBidder not a seat")
        }
        return Seat(index)
    }
}
