// The exchange.discardTo mechanic (ARCHITECTURE §5.6). Every seat that
// holds cards in a seat-scoped zone discards a fixed count (or its whole
// holding, whichever is smaller) into a target zone, all independently.
// Cribbage's pre-show discard is the reference use: each player lays two
// cards into the shared crib while the crib stays hidden.
//
// Discards are private by default: knowledge follows `revealTo`, and the
// target zone's own visibility is unchanged. Eligibility is "holds at
// least one card in `from`"; a seat discards `min(count, held)`.

import CardModel

@_spi(HostOnly)
public struct ExchangeDiscardToParams: Codable, Hashable, Sendable {
    /// Seat-scoped source zone each discarding seat draws from.
    public let from: String
    /// Target zone id.
    public let to: String
    /// Target zone scope: "shared" (one pile) or "seat" (each discarder's own).
    public let toScope: String
    /// Cards each seat discards (expression, evaluated at phase entry).
    public let count: ExprRef
    /// Who learns of each discarded card: "nobody" or "all".
    public let revealTo: String
    /// True when seats discard without seeing others' discards first.
    public let simultaneous: Bool

    public init(
        from: String, to: String, toScope: String, count: ExprRef,
        revealTo: String, simultaneous: Bool
    ) {
        self.from = from
        self.to = to
        self.toScope = toScope
        self.count = count
        self.revealTo = revealTo
        self.simultaneous = simultaneous
    }
}

@_spi(HostOnly)
public struct ExchangeDiscardToMechanic: Mechanic {
    public static let id = "exchange.discardTo"
    public typealias Params = ExchangeDiscardToParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let count = try ctx.evalCall(
            .init(pointer: "exchange.discardTo.count", source: params.count.source, ruleId: id),
            state: state)
        guard case .int(let raw) = count, let target = Int(exactly: raw), target > 0 else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "exchange.discardTo.count not a positive int")
        }
        guard params.toScope == "shared" || params.toScope == "seat" else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "exchange.discardTo.toScope must be shared or seat")
        }
        guard params.revealTo == "nobody" || params.revealTo == "all" else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "exchange.discardTo.revealTo must be nobody or all")
        }
        state.setPhaseOption("target", value: String(target))
        state.setPhaseOption("toScope", value: params.toScope)
        state.setPhaseOption("revealTo", value: params.revealTo)
        for index in 0..<ctx.seatCount {
            let seat = Seat(index)
            let held = state.zones.cards(in: zoneKey(params.from, seat: seat)).count
            state.setPhaseOption("eligible:\(index)", value: held > 0 ? "1" : "0")
            state.setPhaseOption("discarded:\(index)", value: "0")
        }
        return []
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        guard eligible(params, state: state, seat: seat) else { return [] }
        let hand = state.zones.cards(in: zoneKey(params.from, seat: seat))
        return hand.map { ActionIntent.discard([$0.id]) }
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard case .discard(let ids) = intent else {
            throw RuleViolation.illegal(
                ruleId: id, detail: .custom("discardTo expects discard intents"))
        }
        guard !ids.isEmpty else {
            throw RuleViolation.illegal(ruleId: id, detail: .custom("empty discard"))
        }
        let target = Int(state.phaseOptions["target"] ?? "0") ?? 0
        let fromKey = zoneKey(params.from, seat: seat)
        let hand = state.zones.cards(in: fromKey)
        let discarded = discardedCount(state, seat: seat)
        guard discarded + ids.count <= target else {
            throw RuleViolation.illegal(
                ruleId: id, detail: .custom("discards only \(max(target - discarded, 0)) more"))
        }
        var events: [GameEvent] = []
        for raw in ids {
            guard let card = hand.first(where: { $0.id == raw }) else {
                throw RuleViolation.illegal(ruleId: id, detail: .notInHand(raw))
            }
            do {
                try state.zones.move(raw, from: fromKey, to: targetZone(params, seat: seat))
            } catch {
                throw RuleViolation.engineFault(
                    ruleId: id, pointer: "exchange.discardTo move \(error)")
            }
            if state.phaseOptions["revealTo"] == "all" {
                state.knowledge.makePublic(raw)
            }
            events.append(.cardPlayed(seat: seat, card: card))
        }
        let finished = discarded + ids.count
        state.setPhaseOption("discarded:\(seat.raw)", value: String(finished))
        // A seat is done at the target, or early when its holding ran out
        // (`min(count, held)`). Without this mark a seat that still held
        // cards after reaching the count stayed pending forever and the
        // phase could never complete.
        if finished >= target || state.zones.cards(in: fromKey).isEmpty {
            state.setPhaseOption("done:\(seat.raw)", value: "1")
        }
        events.append(.cardsMoved(from: params.from, to: params.to, count: ids.count))
        return events
    }

    public static func isComplete(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> PhaseOutcome {
        for index in 0..<ctx.seatCount {
            if state.phaseOptions["eligible:\(index)"] == "1",
                state.phaseOptions["done:\(index)"] != "1"
            {
                let held = state.zones
                    .cards(in: zoneKey(params.from, seat: Seat(index))).count
                if held > 0 { return .continue }
            }
        }
        return .complete
    }

    public static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet {
        var seats = SeatSet()
        for index in 0..<ctx.seatCount {
            if state.phaseOptions["eligible:\(index)"] == "1",
                state.phaseOptions["done:\(index)"] != "1"
            {
                seats.insert(Seat(index))
            }
        }
        return seats
    }

    /// A seat that emptied its source zone is done even below the target:
    /// `min(count, held)` bound. Pending seats and completion agree.
    static func eligible(_ params: Params, state: GameState, seat: Seat) -> Bool {
        state.phaseOptions["eligible:\(seat.raw)"] == "1"
            && state.phaseOptions["done:\(seat.raw)"] != "1"
            && !state.zones.cards(in: zoneKey(params.from, seat: seat)).isEmpty
    }

    static func discardedCount(_ state: GameState, seat: Seat) -> Int {
        Int(state.phaseOptions["discarded:\(seat.raw)"] ?? "0") ?? 0
    }

    static func zoneKey(_ id: String, seat: Seat) -> ZoneKey {
        ZoneKey(scope: .seat, owner: seat.raw, id: id)
    }

    static func targetZone(_ params: Params, seat: Seat) -> ZoneKey {
        switch params.toScope {
        case "shared": return ZoneKey(scope: .shared, owner: 0, id: params.to)
        default: return ZoneKey(scope: .seat, owner: seat.raw, id: params.to)
        }
    }
}
