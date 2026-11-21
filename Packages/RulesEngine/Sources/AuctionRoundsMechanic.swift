// The `auction.rounds` mechanic (§5.6): fixed rounds of offers, each round
// offering every seat in turn a fixed menu of calls. Euchre's two-round
// make-the-trump auction is the reference shape (EUC-2.1–EUC-2.4). The
// auction ends when `endWhen` holds after a call; when every round is
// exhausted the ruleset's `allPass` action decides what happens to the
// deal (redeal words throw the deal in, §5.7).

import CardModel

/// Mechanic-local state for the auction phases (`auction.rounds` and
/// `auction.ladder` share the record shape; each owns its substate case).
public struct AuctionSubstate: Codable, Hashable, Sendable {
    /// The seat whose call is awaited; nil while the auction is over.
    public var turn: Seat?
    /// The active round index (`auction.rounds`); 0 for `auction.ladder`.
    public var round: Int
    /// Calls already made in the active round (`auction.rounds`).
    public var callsInRound: Int
    /// Consecutive passes (`auction.ladder`).
    public var passes: Int
    /// Set when the phase's end condition held after a call.
    public var ended: Bool
    /// Set when the auction passed out with no call made (§5.7 redeal).
    public var passedOut: Bool
    /// Ladder bookkeeping: the winning bid and the doubling state.
    public var winning: String?
    public var winningSeat: Seat?
    public var doubled: Bool
    public var redoubled: Bool
    /// Ladder bids in call order, for declarer determination (BRG-2.5).
    public var bids: [AuctionBid]

    public init(
        turn: Seat? = nil, round: Int = 0, callsInRound: Int = 0, passes: Int = 0,
        ended: Bool = false, passedOut: Bool = false, winning: String? = nil,
        winningSeat: Seat? = nil, doubled: Bool = false, redoubled: Bool = false,
        bids: [AuctionBid] = []
    ) {
        self.turn = turn
        self.round = round
        self.callsInRound = callsInRound
        self.passes = passes
        self.ended = ended
        self.passedOut = passedOut
        self.winning = winning
        self.winningSeat = winningSeat
        self.doubled = doubled
        self.redoubled = redoubled
        self.bids = bids
    }
}

/// One bid on the ladder, recorded for declarer determination.
public struct AuctionBid: Codable, Hashable, Sendable {
    public let seat: Seat
    public let level: Int
    public let strain: String

    public init(seat: Seat, level: Int, strain: String) {
        self.seat = seat
        self.level = level
        self.strain = strain
    }
}

/// Parameters for `auction.rounds` (§5.6).
public struct AuctionRoundsParams: Codable, Hashable, Sendable {
    public struct Call: Codable, Hashable, Sendable {
        public let id: String
        /// Legality predicate; `seat` and `param` are bound when evaluated.
        public let allowed: ExprRef?
        public let ruleId: String?
        /// Name of the parameter the call carries (e.g. `"suit"`); the tag
        /// spells it after a colon (`name:H`, §9.2 opaque tags).
        public let param: String?
        /// Candidate values for the parameter (§5.6: the deck's suit codes,
        /// first-seen order), compiled from the ruleset's deck.
        public let paramValues: [String]
        /// Assignments run when the call is accepted, with `seat` and
        /// `param` bound (e.g. `deal.trump` ← `param`).
        public let sets: [EngineEffect]
        /// Go-alone predicate for the caller, bound as `call.alone` in
        /// `onCall` effects.
        public let alone: ExprRef?

        public init(
            id: String, allowed: ExprRef? = nil, ruleId: String? = nil,
            param: String? = nil, paramValues: [String] = [],
            sets: [EngineEffect] = [], alone: ExprRef? = nil
        ) {
            self.id = id
            self.allowed = allowed
            self.ruleId = ruleId
            self.param = param
            self.paramValues = paramValues
            self.sets = sets
            self.alone = alone
        }
    }

    public struct Round: Codable, Hashable, Sendable {
        public let id: String
        public let ruleId: String?
        /// Effects run when the round begins (e.g. turn the upcard down).
        public let before: [EngineEffect]
        public let calls: [Call]

        public init(id: String, ruleId: String? = nil, before: [EngineEffect] = [], calls: [Call]) {
            self.id = id
            self.ruleId = ruleId
            self.before = before
            self.calls = calls
        }
    }

    /// Who calls first in every round; nil means left of the dealer.
    public let firstBidder: ExprRef?
    public let rounds: [Round]
    /// Effects run after every accepted call, with `seat` and `call`
    /// (`call.id`, `call.alone`) bound.
    public let onCall: [EngineEffect]
    /// End predicate, evaluated after each call's effects (e.g. trump named).
    public let endWhen: ExprRef?
    public let endWhenRuleId: String?
    /// Action word when every round passes out: `redeal` /
    /// `redealNextDealer` / `redealSameDealer` (§5.7).
    public let allPass: ExprRef?
    public let allPassRuleId: String?

    public init(
        firstBidder: ExprRef? = nil, rounds: [Round], onCall: [EngineEffect] = [],
        endWhen: ExprRef? = nil, endWhenRuleId: String? = nil,
        allPass: ExprRef? = nil, allPassRuleId: String? = nil
    ) {
        self.firstBidder = firstBidder
        self.rounds = rounds
        self.onCall = onCall
        self.endWhen = endWhen
        self.endWhenRuleId = endWhenRuleId
        self.allPass = allPass
        self.allPassRuleId = allPassRuleId
    }
}

/// The `auction.rounds` mechanic (§5.6).
@_spi(HostOnly)
public enum AuctionRoundsMechanic: Mechanic {
    public static let id = "auction.rounds"
    public typealias Params = AuctionRoundsParams

    static let auctionDefaultRuleId = "auction.rounds"
    static let seatStep = 1

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var sub = AuctionSubstate(turn: try firstBidder(params, state: state, ctx: ctx))
        try beginRound(params, round: 0, sub: &sub, state: &state, ctx: ctx)
        state.setAuctionSubstate(sub, ladder: false)
        return []
    }

    /// Whether a non-param call may be offered at all. A faulting predicate
    /// keeps the menu open so the real error surfaces at apply time — the
    /// same tolerance `legalParams` uses.
    static func callAllowed(
        _ call: AuctionRoundsParams.Call, seat: Seat, pointer: String, state: GameState,
        ctx: EvalContext
    ) -> Bool {
        guard let allowed = call.allowed else { return true }
        let bindings = ["seat": EvalValue.string(spelling(seat, ctx))]
        let value = try? ctx.evalCall(
            .init(
                pointer: pointer, source: allowed.source,
                ruleId: call.ruleId, contextual: bindings),
            state: state)
        guard case .bool(let ok)? = value else { return true }
        return ok
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        let sub = state.auctionSubstate()
        guard sub.turn == seat, let round = params.rounds[safe: sub.round] else { return [] }
        var intents: [ActionIntent] = []
        for call in round.calls {
            if let param = call.param {
                for candidate in legalParams(call, seat: seat, state: state, ctx: ctx) {
                    intents.append(.call("\(call.id):\(candidate)"))
                }
            } else if callAllowed(
                call, seat: seat,
                pointer: "\(id).\(round.id).\(call.id).allowed", state: state, ctx: ctx)
            {
                intents.append(.call(call.id))
            }
        }
        return intents
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState,
        ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var sub = state.auctionSubstate()
        guard let turn = sub.turn, turn == seat else {
            throw RuleViolation.illegal(
                ruleId: auctionDefaultRuleId, detail: .custom("not the auction turn"))
        }
        guard case .call(let tag) = intent, let round = params.rounds[safe: sub.round] else {
            throw RuleViolation.illegal(
                ruleId: auctionDefaultRuleId, detail: .custom("expected a call"))
        }
        let (callID, param) = splitTag(tag)
        guard let call = round.calls.first(where: { $0.id == callID }) else {
            throw RuleViolation.illegal(
                ruleId: round.ruleId ?? auctionDefaultRuleId,
                detail: .custom("unknown call \(callID)"))
        }
        let ruleId = call.ruleId ?? round.ruleId ?? auctionDefaultRuleId
        if call.param != nil, param == nil {
            throw RuleViolation.illegal(
                ruleId: ruleId, detail: .custom("call \(callID) needs a param"))
        }
        var bindings: [String: EvalValue] = ["seat": .string(spelling(seat, ctx))]
        if let paramName = call.param, let param {
            bindings[paramName] = .string(param)
        }
        if let allowed = call.allowed {
            let value = try ctx.evalCall(
                .init(
                    pointer: "\(id).\(round.id).\(call.id).allowed", source: allowed.source,
                    ruleId: ruleId, contextual: bindings),
                state: state)
            guard case .bool(let ok) = value, ok else {
                throw RuleViolation.illegal(ruleId: ruleId, detail: .custom("call not allowed"))
            }
        }
        let alone = try goAlone(call, seat: seat, state: state, ctx: ctx)
        bindings["call"] = .record(
            name: "call", fields: ["id": .string(call.id), "alone": .bool(alone)])
        var events: [GameEvent] = []
        if let runner = ctx.effects, !call.sets.isEmpty {
            try runner.run(
                call.sets, in: &state, bindings: bindings, events: &events,
                pointer: "\(id).\(round.id).\(call.id).sets")
        }
        if let runner = ctx.effects, !params.onCall.isEmpty {
            try runner.run(
                params.onCall, in: &state, bindings: bindings, events: &events,
                pointer: "\(id).onCall")
        }
        events.append(.called(seat: seat, call: tag))
        try advance(params, round: round, sub: &sub, state: &state, ctx: ctx)
        state.setAuctionSubstate(sub, ladder: false)
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

    // MARK: - Internals

    /// Round-start bookkeeping: `before` effects run when a round begins
    /// (round 0's run at phase entry), and the turn resets to the first
    /// bidder for every round.
    static func beginRound(
        _ params: Params, round: Int, sub: inout AuctionSubstate, state: inout GameState,
        ctx: EvalContext
    ) throws(RuleViolation) {
        sub.round = round
        sub.callsInRound = 0
        sub.passedOut = false
        if let before = params.rounds[safe: round]?.before, let runner = ctx.effects, !before.isEmpty {
            var events: [GameEvent] = []
            try runner.run(
                before, in: &state, events: &events, pointer: "\(id).round\(round).before")
        }
    }

    /// After a call: end when `endWhen` holds, else move to the next seat,
    /// and when the round is exhausted move to the next round or pass out.
    static func advance(
        _ params: Params, round: AuctionRoundsParams.Round, sub: inout AuctionSubstate,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) {
        if let endWhen = params.endWhen {
            let value = try ctx.evalCall(
                .init(
                    pointer: "\(id).endWhen", source: endWhen.source,
                    ruleId: params.endWhenRuleId),
                state: state)
            if case .bool(true) = value {
                sub.ended = true
                return
            }
        }
        sub.callsInRound += 1
        if sub.callsInRound < ctx.seatCount {
            let current = sub.turn?.raw ?? 0
            sub.turn = Seat((current + seatStep) % ctx.seatCount)
            return
        }
        let next = sub.round + 1
        if params.rounds.indices.contains(next) {
            try beginRound(params, round: next, sub: &sub, state: &state, ctx: ctx)
            sub.turn = try firstBidder(params, state: state, ctx: ctx)
        } else {
            sub.passedOut = true
            try rotateForAllPass(params, state: &state, ctx: ctx)
            sub.turn = nil
        }
    }

    /// The `allPass` action word: redeal words throw the deal in, with the
    /// dealer rotated for `redeal`/`redealNextDealer` (§5.7).
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

    static func firstBidder(
        _ params: Params, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        guard let spec = params.firstBidder else {
            return Seat((state.dealer.raw + seatStep) % ctx.seatCount)
        }
        let value = try ctx.evalCall(
            .init(pointer: "\(id).firstBidder", source: spec.source), state: state)
        guard let seat = seatValue(of: value, ctx: ctx) else {
            throw RuleViolation.engineFault(ruleId: nil, pointer: "\(id).firstBidder not a seat")
        }
        return seat
    }

    static func goAlone(
        _ call: AuctionRoundsParams.Call, seat: Seat, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Bool {
        guard let alone = call.alone else { return false }
        let value = try ctx.evalCall(
            .init(
                pointer: "\(id).alone", source: alone.source, ruleId: call.ruleId,
                contextual: ["seat": .string(spelling(seat, ctx))]),
            state: state)
        guard case .bool(let flag) = value else {
            throw RuleViolation.engineFault(ruleId: call.ruleId, pointer: "\(id).alone not a bool")
        }
        return flag
    }

    /// Parameter values whose `allowed` predicate accepts the call. A
    /// predicate that fails to evaluate counts as accepting: the menu stays
    /// open and `apply` faults with the real error instead of deadlocking.
    static func legalParams(
        _ call: AuctionRoundsParams.Call, seat: Seat, state: GameState, ctx: EvalContext
    ) -> [String] {
        guard let param = call.param, let allowed = call.allowed else {
            return call.paramValues
        }
        var accepted: [String] = []
        for candidate in call.paramValues {
            let bindings = [
                "seat": .string(spelling(seat, ctx)),
                param: EvalValue.string(candidate),
            ]
            let value = try? ctx.evalCall(
                .init(
                    pointer: "\(id).allowed", source: allowed.source,
                    ruleId: call.ruleId, contextual: bindings),
                state: state)
            guard case .bool(let ok)? = value else {
                accepted.append(candidate)
                continue
            }
            if ok { accepted.append(candidate) }
        }
        return accepted
    }

    /// Splits a call tag into its id and optional parameter (`name:H`).
    static func splitTag(_ tag: String) -> (String, String?) {
        guard let colon = tag.firstIndex(of: ":") else { return (tag, nil) }
        let id = String(tag[tag.startIndex..<colon])
        let param = String(tag[tag.index(after: colon)...])
        return (id, param.isEmpty ? nil : param)
    }

    static func spelling(_ seat: Seat, _ ctx: EvalContext) -> String {
        ctx.seatNames.indices.contains(seat.raw) ? ctx.seatNames[seat.raw] : "S\(seat.raw + 1)"
    }

    /// Parses a seat value back: a setup seat spelling, or the `S<n>`
    /// fallback spelling.
    static func seatValue(of value: EvalValue, ctx: EvalContext) -> Seat? {
        guard case .string(let name) = value else { return nil }
        if let index = ctx.seatNames.firstIndex(of: name) { return Seat(index) }
        guard name.hasPrefix("S"), let raw = Int(name.dropFirst()), raw >= 1,
            raw <= ctx.seatCount
        else { return nil }
        return Seat(raw - 1)
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
