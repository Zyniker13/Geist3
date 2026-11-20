// The show mechanic (§5.6): the counted reveal at the end of a deal.
// Piles are scored in `order`; each pile is revealed (its cards become
// public knowledge), its points are evaluated from the `points` expression
// with the pile's cards (plus the `with` zone's cards) and the entry's
// `isCrib` flag, and the points are added to the `award` lvalue with the
// entry's awardee bound. Manual counting and muggins are declared by the
// schema but not supported in Engine 1.0; a ruleset that enables them
// faults with a clear pointer rather than scoring silently.

import CardModel

@_spi(HostOnly)
public struct ShowEntryParams: Codable, Hashable, Sendable {
    /// Zone the pile comes from (seat-scoped when `seat` is set, shared
    /// otherwise).
    public let zone: String
    /// Seat expression selecting whose pile this is.
    public let seat: ExprRef?
    /// Seat expression naming who scores the pile; falls back to `seat`.
    public let award: ExprRef?
    /// Passed to the points expression as the `isCrib` binding.
    public let isCrib: Bool?

    public init(zone: String, seat: ExprRef? = nil, award: ExprRef? = nil, isCrib: Bool? = nil) {
        self.zone = zone
        self.seat = seat
        self.award = award
        self.isCrib = isCrib
    }
}

@_spi(HostOnly)
public struct ShowParams: Codable, Hashable, Sendable {
    /// Piles to show, in counting order.
    public let order: [ShowEntryParams]
    /// Expression yielding the name of a zone counted with every pile.
    public let with: ExprRef?
    /// Points expression (bindings `cards`, `isCrib`).
    public let points: ExprRef?
    /// Rule id attached to the points expression (provenance only).
    public let pointsRule: String?
    /// Manual-counting gate; enabling it faults in Engine 1.0.
    public let manual: ExprRef?
    /// Muggins gate; enabling it faults in Engine 1.0.
    public let muggins: ExprRef?
    /// Award lvalue variable name (e.g. "match.score").
    public let awardName: String
    /// Award lvalue index expression source (e.g. "awardee").
    public let awardIndex: String

    public init(
        order: [ShowEntryParams], with: ExprRef? = nil, points: ExprRef? = nil,
        pointsRule: String? = nil, manual: ExprRef? = nil, muggins: ExprRef? = nil,
        awardName: String = "match.score", awardIndex: String = "awardee"
    ) {
        self.order = order
        self.with = with
        self.points = points
        self.pointsRule = pointsRule
        self.manual = manual
        self.muggins = muggins
        self.awardName = awardName
        self.awardIndex = awardIndex
    }
}

@_spi(HostOnly)
public struct ShowMechanic: Mechanic {
    public typealias Params = ShowParams

    public static let id = "show"

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        if let manual = params.manual, try boolOf(manual, state: state, ctx: ctx) {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "show.manual is not supported in Engine 1.0")
        }
        if let muggins = params.muggins, try boolOf(muggins, state: state, ctx: ctx) {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "show.muggins is not supported in Engine 1.0")
        }
        let withZone = try withZoneName(params, state: state, ctx: ctx)
        var events: [GameEvent] = []
        for (position, entry) in params.order.enumerated() {
            let pileKey = try pileKey(entry, state: state, ctx: ctx)
            let pile = state.zones.cards(in: pileKey)
            for card in pile {
                state.knowledge.makePublic(card.id)
            }
            events.append(.revealed(zone: entry.zone, cards: pile))
            guard let points = params.points else { continue }
            let cards = pile + (withZone.map { state.zones.cards(in: $0) } ?? [])
            let value = try ctx.evalCall(
                .init(
                    pointer: "show.points[\(position)]", source: points.source, ruleId: id,
                    contextual: [
                        "cards": .list(cards.map { Self.cardValue($0) }),
                        "isCrib": .bool(entry.isCrib ?? false),
                    ]),
                state: state)
            guard case .int(let raw) = value, let points = Int(exactly: raw) else {
                throw RuleViolation.engineFault(
                    ruleId: id, pointer: "show.points[\(position)] not an int")
            }
            guard points > 0 else { continue }
            let awardee = try awardeeSeat(entry, position: position, state: state, ctx: ctx)
            try award(
                params, awardee: awardee, points: points, state: &state, ctx: ctx,
                events: &events, position: position)
            events.append(
                .scored(seat: awardee, points: points, reason: "show", ruleId: params.pointsRule))
        }
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        []
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        throw RuleViolation.engineFault(ruleId: id, pointer: "show takes no intents")
    }

    public static func isComplete(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> PhaseOutcome {
        .complete
    }

    public static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet {
        SeatSet()
    }

    // MARK: - Helpers

    /// The zone key for a pile: seat-scoped when the entry names a seat,
    /// shared otherwise.
    static func pileKey(
        _ entry: ShowEntryParams, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> ZoneKey {
        guard let seatExpr = entry.seat else {
            return ZoneKey(scope: .shared, owner: 0, id: entry.zone)
        }
        let seat = try seatOf(seatExpr, pointer: "show.order.seat", state: state, ctx: ctx)
        return ZoneKey(scope: .seat, owner: seat.raw, id: entry.zone)
    }

    /// Who scores the pile: the entry's `award` expression, else its `seat`.
    static func awardeeSeat(
        _ entry: ShowEntryParams, position: Int, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        if let award = entry.award {
            return try seatOf(award, pointer: "show.order[\(position)].award", state: state, ctx: ctx)
        }
        if let seat = entry.seat {
            return try seatOf(seat, pointer: "show.order[\(position)].seat", state: state, ctx: ctx)
        }
        throw RuleViolation.engineFault(
            ruleId: id, pointer: "show.order[\(position)] has no awardee")
    }

    static func seatOf(
        _ expr: ExprRef, pointer: String, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        let value = try ctx.evalCall(
            .init(pointer: pointer, source: expr.source, ruleId: id), state: state)
        guard case .string(let name) = value else {
            throw RuleViolation.engineFault(ruleId: id, pointer: "\(pointer) not a seat")
        }
        if let index = ctx.seatNames.firstIndex(of: name) { return Seat(index) }
        guard name.hasPrefix("S"), let raw = Int(name.dropFirst()), raw >= 1,
            raw <= ctx.seatCount
        else {
            throw RuleViolation.engineFault(ruleId: id, pointer: "\(pointer) unknown seat \(name)")
        }
        return Seat(raw - 1)
    }

    /// The extra zone counted with every pile, from the `with` expression.
    static func withZoneName(
        _ params: Params, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> ZoneKey? {
        guard let with = params.with else { return nil }
        let value = try ctx.evalCall(
            .init(pointer: "show.with", source: with.source, ruleId: id), state: state)
        guard case .string(let name) = value, !name.isEmpty else {
            throw RuleViolation.engineFault(ruleId: id, pointer: "show.with not a zone name")
        }
        return ZoneKey(scope: .shared, owner: 0, id: name)
    }

    static func boolOf(
        _ expr: ExprRef, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Bool {
        let value = try ctx.evalCall(
            .init(pointer: "show.gate", source: expr.source, ruleId: id), state: state)
        guard case .bool(let flag) = value else {
            throw RuleViolation.engineFault(ruleId: id, pointer: "show gate not a bool")
        }
        return flag
    }

    static func award(
        _ params: Params, awardee: Seat, points: Int, state: inout GameState,
        ctx: EvalContext, events: inout [GameEvent], position: Int
    ) throws(RuleViolation) {
        guard let runner = ctx.effects else { return }
        var awarded = [GameEvent]()
        do {
            try runner.run(
                [
                    .add(
                        name: params.awardName, index: params.awardIndex, value: "awarded",
                        event: nil)
                ],
                in: &state,
                bindings: [
                    "awarded": .int(Int64(points)),
                    "awardee": .string(seatName(awardee, ctx)),
                ],
                events: &awarded,
                pointer: "show/award")
        } catch {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "show award \(error)")
        }
        events += awarded
    }

    static func seatName(_ seat: Seat, _ ctx: EvalContext) -> String {
        ctx.seatNames.indices.contains(seat.raw) ? ctx.seatNames[seat.raw] : "S\(seat.raw + 1)"
    }

    static func cardValue(_ instance: CardInstance) -> EvalValue {
        .card(
            id: instance.face.id,
            suit: instance.face.suit?.code ?? "",
            rank: instance.face.rank.code)
    }
}
