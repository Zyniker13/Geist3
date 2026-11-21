// The `exchange.pass` mechanic (ARCHITECTURE §5.6): every passer
// stages `count` cards from their `from` zone, then the staged cards
// are delivered to each passer's `target` seat (a seat expression with
// `seat` bound, e.g. `left(seat, passOffset())`).
//
// `via` names a seat-scoped staging zone: pick-up into it per passer,
// then one combined delivery step — the chess-clock so no seat can
// learn anything early. With `simultaneous` the delivery happens only
// after every passer has staged `count` cards. Without `via` (e.g.
// cribbage's one-way lay-away) a pick moves straight to the target.
//
// Knowledge follows `revealTo`: `nobody` keeps the transfer secret,
// `recipient` reveals the incoming cards to their new holder only,
// `all` makes them public.

import CardModel

public struct ExchangePassParams: Codable, Hashable, Sendable {
    /// Zone the cards leave (seat-scoped, e.g. the hand).
    public let from: String
    /// Optional seat-scoped staging zone; nil moves straight to the target.
    public let via: String?
    /// Zone the cards land in (seat-scoped, e.g. the recipient's hand).
    public let to: String
    /// Cards each passer stages (an integer expression, e.g. `options.passCount`).
    public let count: ExprRef
    /// Target seat per passer; a seat expression with `seat` bound.
    public let target: ExprRef
    /// Wait until every passer has staged before delivering.
    public let simultaneous: Bool
    /// Who learns the delivered cards: `nobody`, `recipient`, `all`.
    public let revealTo: String

    public init(
        from: String, via: String?, to: String, count: ExprRef,
        target: ExprRef, simultaneous: Bool, revealTo: String
    ) {
        self.from = from
        self.via = via
        self.to = to
        self.count = count
        self.target = target
        self.simultaneous = simultaneous
        self.revealTo = revealTo
    }
}

@_spi(HostOnly)
public enum ExchangePassMechanic: Mechanic {
    public static let id = "exchange.pass"

    public typealias Params = ExchangePassParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let count = try resolveCount(params, state: state, ctx: ctx)
        guard count >= 0 else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.pass.count",
                pointer: "\(params.count.pointer) produced \(count), negative")
        }
        let reveal = try revealTarget(params.revealTo, pointer: "phases.exchange.pass.revealTo")
        state.setPhaseOption("count", value: "\(count)")
        state.setPhaseOption("reveal", value: reveal == .recipient ? "1" : "0")
        if reveal == .all {
            state.setPhaseOption("revealAll", value: "1")
        }
        // Count 0 needs no picks; nothing else completes the phase before
        // the cards move (delivery or direct picks).
        state.setPhaseOption("delivered", value: count == 0 ? "1" : "0")
        return []
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        let count = stagedTarget(state)
        guard picked(state, seat) < count else { return [] }
        return intents(state.zones.cards(in: zone(seat, params.from)))
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let count = stagedTarget(state)
        let staged = self.staged(state, seat)
        guard staged.count < count else {
            throw RuleViolation.illegal(
                ruleId: "exchange.pass.already-staged",
                detail: .custom("\(spelling(seat, ctx)) has staged \(staged.count) of \(count) cards"))
        }
        guard case .play(let cardID) = intent else {
            throw RuleViolation.illegal(
                ruleId: "exchange.pass.kind",
                detail: .custom("exchange.pass takes .play intents"))
        }
        let fromKey = zone(seat, params.from)
        guard state.zones.zoneOf(cardID) == fromKey else {
            throw RuleViolation.illegal(
                ruleId: "exchange.pass.zone",
                detail: .custom("card '\(cardID)' is not in \(spelling(seat, ctx))'s \(params.from)"))
        }
        guard let card = state.zones.cards(in: fromKey).first(where: { $0.id == cardID }) else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.pass.zone",
                pointer: "card \(cardID.raw) missing from \(params.from)")
        }

        var events: [GameEvent] = [.cardPlayed(seat: seat, card: card)]
        if let via = params.via {
            do {
                try state.zones.move(cardID, from: fromKey, to: zone(seat, via))
            } catch {
                throw RuleViolation.engineFault(
                    ruleId: "exchange.pass.stage", pointer: "staging move failed: \(error)")
            }
            var ids = staged
            ids.append(cardID)
            state.setPhaseOption(
                stagingKey(seat), value: ids.map { String($0.raw) }.joined(separator: ","))
            state.setPhaseOption(pickedKey(seat), value: "\(picked(state, seat) + 1)")
            if ids.count == count {
                if params.simultaneous {
                    // Combined delivery: no passer's cards land until
                    // everyone has staged (§5.6).
                    if allPicked(state, count, ctx.seatCount) {
                        try deliver(params, state: &state, ctx: ctx, events: &events)
                    }
                } else {
                    try deliverOne(
                        params, passer: seat, ids: ids, state: &state, ctx: ctx,
                        events: &events)
                    // Sequential delivery finishes passer by passer; the
                    // phase ends once the last passer has delivered.
                    if allPicked(state, count, ctx.seatCount) {
                        state.setPhaseOption("delivered", value: "1")
                    }
                }
            }
        } else {
            // No staging zone: a one-way pick lands with its target now.
            let target = try targetSeat(params, seat, state: state, ctx: ctx)
            do {
                try state.zones.move(cardID, from: fromKey, to: zone(target, params.to))
            } catch {
                throw RuleViolation.engineFault(
                    ruleId: "exchange.pass.deliver", pointer: "delivery move failed: \(error)")
            }
            try reveal(params, ids: [cardID], to: target, seatCount: ctx.seatCount, state: &state)
            events.append(.passed(from: seat, to: target, cards: [card]))
            events.append(.received(seat: target, count: 1))
            state.setPhaseOption(pickedKey(seat), value: "\(picked(state, seat) + 1)")
            if allPicked(state, count, ctx.seatCount) {
                state.setPhaseOption("delivered", value: "1")
            }
        }
        return events
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        return state.phaseOption("delivered") == "1" ? .complete : .continue
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        let count = stagedTarget(state)
        var pending = SeatSet()
        for i in 0..<ctx.seatCount where picked(state, Seat(i)) < count {
            pending.insert(Seat(i))
        }
        return pending
    }

    // MARK: - Internals

    /// Combined delivery: every passer's staged cards land with their
    /// targets, in seat order (§5.6). Runs once, when the last of the
    /// passers has finished staging.
    private static func deliver(
        _ params: Params, state: inout GameState, ctx: EvalContext, events: inout [GameEvent]
    ) throws(RuleViolation) {
        for i in 0..<ctx.seatCount {
            let passer = Seat(i)
            let ids = staged(state, passer)
            guard !ids.isEmpty else { continue }
            try deliverOne(
                params, passer: passer, ids: ids, state: &state, ctx: ctx, events: &events)
        }
        state.setPhaseOption("delivered", value: "1")
    }

    /// One passer's staged cards land with their target.
    private static func deliverOne(
        _ params: Params, passer: Seat, ids: [CardID], state: inout GameState,
        ctx: EvalContext, events: inout [GameEvent]
    ) throws(RuleViolation) {
        let target = try targetSeat(params, passer, state: state, ctx: ctx)
        let viaKey = zone(passer, params.via ?? "")
        let toKey = zone(target, params.to)
        for id in ids {
            do {
                try state.zones.move(id, from: viaKey, to: toKey)
            } catch {
                throw RuleViolation.engineFault(
                    ruleId: "exchange.pass.deliver", pointer: "delivery move failed: \(error)")
            }
        }
        try reveal(params, ids: ids, to: target, seatCount: ctx.seatCount, state: &state)
        var cards: [CardInstance] = []
        for id in ids {
            if let card = state.zones.cards(in: toKey).first(where: { $0.id == id }) {
                cards.append(card)
            }
        }
        events.append(.passed(from: passer, to: target, cards: cards))
        events.append(.received(seat: target, count: ids.count))
        state.setPhaseOption(stagingKey(passer), value: "")
    }

    /// The card knowledge each delivery grants.
    private static func reveal(
        _ params: Params, ids: [CardID], to target: Seat, seatCount: Int, state: inout GameState
    ) throws(RuleViolation) {
        let targetKey = try revealTarget(params.revealTo, pointer: "phases.exchange.pass.revealTo")
        switch targetKey {
        case .nobody:
            break
        case .recipient:
            var viewers = SeatSet()
            viewers.insert(target)
            for id in ids { state.knowledge.reveal(id, to: viewers) }
        case .all:
            var viewers = SeatSet()
            for i in 0..<seatCount { viewers.insert(Seat(i)) }
            for id in ids { state.knowledge.reveal(id, to: viewers) }
        }
    }

    /// Evaluates the passer's target seat with `seat` bound to them (§7.4).
    private static func targetSeat(
        _ params: Params, _ passer: Seat, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        let value = try ctx.evalCall(
            EvalCall(
                pointer: params.target.pointer, source: params.target.source,
                ruleId: "exchange.pass.target",
                contextual: ["seat": .string(spelling(passer, ctx))]),
            state: state)
        guard let spelling = value.seatOrTeam else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.pass.target",
                pointer: "\(params.target.pointer) produced \(value), not a seat")
        }
        if let index = ctx.seatNames.firstIndex(of: spelling) {
            return Seat(index)
        }
        if spelling.hasPrefix("S"), let n = Int(spelling.dropFirst()), n >= 1 {
            return Seat(n - 1)
        }
        throw RuleViolation.engineFault(
            ruleId: "exchange.pass.target",
            pointer: "\(params.target.pointer) produced unknown seat '\(spelling)'")
    }

    private static func resolveCount(
        _ params: Params, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Int {
        let value = try ctx.evalCall(
            EvalCall(
                pointer: params.count.pointer, source: params.count.source,
                ruleId: "exchange.pass.count"),
            state: state)
        guard case .int(let count) = value else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.pass.count",
                pointer: "\(params.count.pointer) produced \(value), not an integer")
        }
        guard let n = Int(exactly: count) else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.pass.count",
                pointer: "\(params.count.pointer) produced \(count), out of Int range")
        }
        return n
    }

    private static func revealTarget(
        _ name: String, pointer: String
    ) throws(RuleViolation) -> RevealChoice {
        switch name {
        case "nobody": return .nobody
        case "recipient": return .recipient
        case "all": return .all
        default:
            throw RuleViolation.engineFault(
                ruleId: "exchange.pass.revealTo",
                pointer: "\(pointer) '\(name)' is not nobody, recipient or all")
        }
    }

    private enum RevealChoice { case nobody, recipient, all }

    private static func zone(_ seat: Seat, _ id: String) -> ZoneKey {
        ZoneKey(scope: .seat, owner: seat.raw, id: id)
    }

    private static func staged(_ state: GameState, _ seat: Seat) -> [CardID] {
        guard let raw = state.phaseOption(stagingKey(seat)), !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { UInt16($0) }.map(CardID.init)
    }

    private static func stagingKey(_ seat: Seat) -> String { "staged:\(seat.raw)" }

    private static func pickedKey(_ seat: Seat) -> String { "picked:\(seat.raw)" }

    private static func picked(_ state: GameState, _ seat: Seat) -> Int {
        Int(state.phaseOption(pickedKey(seat)) ?? "0") ?? 0
    }

    private static func allPicked(_ state: GameState, _ count: Int, _ seats: Int) -> Bool {
        for i in 0..<seats where picked(state, Seat(i)) < count { return false }
        return true
    }

    private static func stagedTarget(_ state: GameState) -> Int {
        Int(state.phaseOption("count") ?? "0") ?? 0
    }

    private static func spelling(_ seat: Seat, _ ctx: EvalContext) -> String {
        if ctx.seatNames.indices.contains(seat.raw) { return ctx.seatNames[seat.raw] }
        return "S\(seat.raw + 1)"
    }

    /// One `.play` intent per card the seat still holds in `from`.
    private static func intents(_ cards: [CardInstance]) -> [ActionIntent] {
        cards.map { .play($0.id) }
    }
}
