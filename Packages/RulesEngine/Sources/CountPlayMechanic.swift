// The count-play mechanic (ARCHITECTURE §5.6): the cribbage pegging wave.
// Seats play cards one at a time into a shared run buffer while a running
// total stays under a limit; scoring expressions run after each play. When
// every active seat is blocked (no card fits) the run closes and the go
// points go to the player of the last card. When hands empty the phase
// completes and, with `returnCards`, all played cards return to hands for
// the show.
//
// Turn tracking lives in phase options: `turn` (raw seat index), `count`
// (running total), `last` (raw index of the last player), `blocked:<i>`
// and `run:<i>` (the card ids a seat played into the open run).

import CardModel

@_spi(HostOnly)
public struct CountPlayParams: Codable, Hashable, Sendable {
    /// Seat-scoped hand zone cards are played from.
    public let from: String
    /// Seat-scoped resting zone played cards return to when the run closes.
    public let to: String
    /// Shared zone holding the live run, in play order (defaults to "count";
    /// the reference rulesets read it back through `zone('count')`).
    public let runZone: String
    /// Run mode; only "count" (running total) is supported in Engine 1.0.
    public let sequence: String
    /// Seat expression naming the first player to act.
    public let firstPlayer: ExprRef
    /// Card-value expression (binding `c`) used for the running total.
    public let valueOf: ExprRef
    /// The run closes when the total reaches this limit.
    public let limit: Int
    /// Points for the last card when a go closes the run.
    public let goLastCardPoints: Int
    /// Points when a play lands the total exactly on the limit.
    public let goExactLimitPoints: Int
    /// Scoring expression evaluated after each play.
    public let pointsOnPlay: ExprRef?
    /// Rule id attached to the play scoring (provenance only).
    public let pointsRule: String?
    /// Award lvalue variable name (e.g. "match.score").
    public let awardName: String?
    /// Award lvalue index expression source (e.g. "seat").
    public let awardIndex: String?
    /// Return resting piles and the run to hands at completion.
    public let returnCards: Bool

    public init(
        from: String, to: String, runZone: String = "count", sequence: String = "count",
        firstPlayer: ExprRef, valueOf: ExprRef, limit: Int, goLastCardPoints: Int = 0,
        goExactLimitPoints: Int = 0, pointsOnPlay: ExprRef? = nil, pointsRule: String? = nil,
        awardName: String? = nil, awardIndex: String? = nil, returnCards: Bool
    ) {
        self.from = from
        self.to = to
        self.runZone = runZone
        self.sequence = sequence
        self.firstPlayer = firstPlayer
        self.valueOf = valueOf
        self.limit = limit
        self.goLastCardPoints = goLastCardPoints
        self.goExactLimitPoints = goExactLimitPoints
        self.pointsOnPlay = pointsOnPlay
        self.pointsRule = pointsRule
        self.awardName = awardName
        self.awardIndex = awardIndex
        self.returnCards = returnCards
    }
}

@_spi(HostOnly)
public struct CountPlayMechanic: Mechanic {
    public typealias Params = CountPlayParams

    public static let id = "count-play"

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard params.limit > 0 else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "count-play.limit must be positive")
        }
        guard params.sequence == "count" else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "count-play sequence \(params.sequence) unsupported")
        }
        let first = try ctx.evalCall(
            .init(pointer: "count-play.firstPlayer", source: params.firstPlayer.source, ruleId: id),
            state: state)
        guard let seat = seatValue(of: first, ctx: ctx) else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "count-play.firstPlayer not a seat")
        }
        state.setPhaseOption("turn", value: String(seat.raw))
        state.setPhaseOption("count", value: "0")
        state.setPhaseOption("last", value: "")
        clearBlocked(&state, ctx: ctx)
        var events: [GameEvent] = []
        try settleTurn(&state, params: params, ctx: ctx)
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        guard state.phaseOptions["turn"] == String(seat.raw) else { return [] }
        let hand = state.zones.cards(in: zoneKey(params.from, seat: seat))
        var intents: [ActionIntent] = []
        for card in hand
        where valueOf(params, card: card, state: state, ctx: ctx)
            <= limitRemaining(state, params)
        {
            intents.append(.play(card.id))
        }
        if intents.isEmpty, !hand.isEmpty {
            intents.append(.choose("go"))
        }
        return intents
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard state.phaseOptions["turn"] == String(seat.raw) else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        var events: [GameEvent] = []
        switch intent {
        case .play(let raw):
            try applyPlay(params, cardID: raw, by: seat, state: &state, ctx: ctx, events: &events)
        case .choose(let choice):
            guard choice == "go" else {
                throw RuleViolation.illegal(ruleId: id, detail: .custom("unknown choice \(choice)"))
            }
            try applyGo(params, by: seat, state: &state, ctx: ctx, events: &events)
        default:
            throw RuleViolation.illegal(ruleId: id, detail: .custom("count-play expects play or go"))
        }
        finalizeIfHandsEmpty(&state, params: params, ctx: ctx, events: &events)
        try settleTurn(&state, params: params, ctx: ctx)
        return events
    }

    public static func isComplete(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> PhaseOutcome {
        if state.phaseOptions["done"] == "1" { return .complete }
        for index in 0..<ctx.seatCount {
            if !state.zones.cards(in: zoneKey(params.from, seat: Seat(index))).isEmpty {
                return .continue
            }
        }
        return .complete
    }

    public static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet {
        if state.phaseOptions["done"] == "1" { return SeatSet() }
        let turnRaw = state.phaseOptions["turn"] ?? "0"
        guard let index = Int(turnRaw), index < ctx.seatCount else { return SeatSet() }
        return SeatSet(Seat(index))
    }

    // MARK: - Play

    static func applyPlay(
        _ params: Params, cardID raw: CardID, by seat: Seat,
        state: inout GameState, ctx: EvalContext, events: inout [GameEvent]
    ) throws(RuleViolation) {
        let fromKey = zoneKey(params.from, seat: seat)
        guard let card = state.zones.cards(in: fromKey).first(where: { $0.id == raw }) else {
            throw RuleViolation.illegal(ruleId: id, detail: .notInHand(raw))
        }
        let value = valueOf(params, card: card, state: state, ctx: ctx)
        guard value <= limitRemaining(state, params) else {
            throw RuleViolation.illegal(ruleId: id, detail: .exceedsLimit(params.limit))
        }
        let runKey = ZoneKey(scope: .shared, owner: 0, id: params.runZone)
        do {
            try state.zones.move(raw, from: fromKey, to: runKey)
        } catch {
            throw RuleViolation.engineFault(ruleId: id, pointer: "count-play move \(error)")
        }
        appendRun(&state, seat: seat, card: raw)
        events.append(.cardPlayed(seat: seat, card: card))
        events.append(.cardsMoved(from: params.from, to: params.runZone, count: 1))
        let total = runTotal(state) + value
        state.setPhaseOption("count", value: String(total))
        state.setPhaseOption("last", value: String(seat.raw))
        let playPoints = pointsOnPlay(params, seat: seat, state: state, ctx: ctx)
        if playPoints > 0 {
            try award(
                params, seat: seat, points: playPoints, state: &state, ctx: ctx,
                events: &events, reason: "pegging")
        }
        // The next seat in order acts next; settleTurn skips seats that
        // are empty or blocked, and a closed run re-leads after the closer.
        state.setPhaseOption("turn", value: String(nextSeat(seat, ctx: ctx).raw))
        if total >= params.limit {
            let bonus = params.goExactLimitPoints
            events += try closeRun(params, state: &state, ctx: ctx, scorer: seat, points: bonus)
        }
    }

    // MARK: - Go

    static func applyGo(
        _ params: Params, by seat: Seat,
        state: inout GameState, ctx: EvalContext, events: inout [GameEvent]
    ) throws(RuleViolation) {
        guard !state.zones.cards(in: zoneKey(params.from, seat: seat)).isEmpty else {
            throw RuleViolation.illegal(
                ruleId: id, detail: .custom("go requires cards in hand"))
        }
        guard hasPlayable(params, seat: seat, state: state, ctx: ctx) else {
            throw RuleViolation.illegal(
                ruleId: id, detail: .custom("go only when no card fits the run"))
        }
        state.setPhaseOption("blocked:\(seat.raw)", value: "1")
        if allActiveBlocked(params, state: state, ctx: ctx) {
            let lastRaw = Int(state.phaseOptions["last"] ?? "-1") ?? -1
            let scorer = (0..<ctx.seatCount).contains(lastRaw) ? Seat(lastRaw) : seat
            events += try closeRun(
                params, state: &state, ctx: ctx,
                scorer: scorer, points: params.goLastCardPoints)
            state.setPhaseOption("turn", value: String(nextSeat(scorer, ctx: ctx).raw))
        }
    }

    // MARK: - Run lifecycle

    /// Closes the open run: awards `points`, empties the run buffer into
    /// the resting piles, and unblocks every seat. The caller sets the
    /// turn to the next leader (the seat after the closer).
    static func closeRun(
        _ params: Params, state: inout GameState, ctx: EvalContext,
        scorer: Seat, points: Int
    ) throws(RuleViolation) -> [GameEvent] {
        var events: [GameEvent] = []
        returnRunCards(params, state: &state, ctx: ctx, events: &events)
        state.setPhaseOption("count", value: "0")
        clearBlocked(&state, ctx: ctx)
        if points > 0 {
            try award(
                params, seat: scorer, points: points, state: &state, ctx: ctx,
                events: &events, reason: "go")
        }
        return events
    }

    /// Plays still open in the run buffer go back to their players' resting
    /// piles, in play order (`run:<i>` tracks who played each card).
    static func returnRunCards(
        _ params: Params, state: inout GameState, ctx: EvalContext,
        events: inout [GameEvent]
    ) {
        let runKey = ZoneKey(scope: .shared, owner: 0, id: params.runZone)
        var moved = 0
        for index in 0..<ctx.seatCount {
            let seat = Seat(index)
            let raws = runCardIds(state, seat: seat)
            guard !raws.isEmpty else { continue }
            for raw in raws where state.zones.cards(in: runKey).contains(where: { $0.id == raw }) {
                do {
                    try state.zones.move(raw, from: runKey, to: zoneKey(params.to, seat: seat))
                    moved += 1
                } catch {
                    continue
                }
            }
            state.setPhaseOption("run:\(index)", value: "")
        }
        if moved > 0 {
            events.append(.cardsMoved(from: params.runZone, to: params.to, count: moved))
        }
    }

    /// At completion every played card returns to hands (for the show):
    /// the run buffer first, then each resting pile.
    static func finalizeIfHandsEmpty(
        _ state: inout GameState, params: Params, ctx: EvalContext,
        events: inout [GameEvent]
    ) {
        for index in 0..<ctx.seatCount {
            if !state.zones.cards(in: zoneKey(params.from, seat: Seat(index))).isEmpty {
                return
            }
        }
        // Mark completion BEFORE returning any cards: with `returnCards`
        // the hands refill for the show, and an empty-hand completion
        // check would otherwise never fire again.
        state.setPhaseOption("done", value: "1")
        returnRunCards(params, state: &state, ctx: ctx, events: &events)
        guard params.returnCards else { return }
        for index in 0..<ctx.seatCount {
            let seat = Seat(index)
            let restKey = zoneKey(params.to, seat: seat)
            let handKey = zoneKey(params.from, seat: seat)
            let count = state.zones.cards(in: restKey).count
            guard count > 0 else { continue }
            for card in state.zones.cards(in: restKey) {
                do {
                    try state.zones.move(card.id, from: restKey, to: handKey)
                } catch {
                    continue
                }
            }
            events.append(.cardsMoved(from: params.to, to: params.from, count: count))
        }
    }

    /// Advances the turn to the next seat that can act: holds cards and is
    /// not blocked. Starting from the current turn keeps a legal leader in
    /// place; a blocked or empty seat is passed over.
    static func settleTurn(
        _ state: inout GameState, params: Params, ctx: EvalContext
    ) throws(RuleViolation) {
        let turnRaw = Int(state.phaseOptions["turn"] ?? "0") ?? 0
        for offset in 0..<ctx.seatCount {
            let seat = Seat((turnRaw + offset) % ctx.seatCount)
            guard !state.zones.cards(in: zoneKey(params.from, seat: seat)).isEmpty else { continue }
            guard state.phaseOptions["blocked:\(seat.raw)"] != "1" else { continue }
            state.setPhaseOption("turn", value: String(seat.raw))
            return
        }
    }

    // MARK: - Helpers

    static func zoneKey(_ id: String, seat: Seat) -> ZoneKey {
        ZoneKey(scope: .seat, owner: seat.raw, id: id)
    }

    static func nextSeat(_ seat: Seat, ctx: EvalContext) -> Seat {
        Seat((seat.raw + 1) % ctx.seatCount)
    }

    static func runTotal(_ state: GameState) -> Int {
        Int(state.phaseOptions["count"] ?? "0") ?? 0
    }

    static func limitRemaining(_ state: GameState, _ params: Params) -> Int {
        params.limit - runTotal(state)
    }

    static func runCardIds(_ state: GameState, seat: Seat) -> [CardID] {
        (state.phaseOptions["run:\(seat.raw)"] ?? "")
            .split(separator: ",").compactMap { raw in
                guard let value = UInt16(raw) else { return nil }
                return CardID(value)
            }
    }

    static func appendRun(_ state: inout GameState, seat: Seat, card: CardID) {
        var ids = runCardIds(state, seat: seat).map { String($0.raw) }
        ids.append(String(card.raw))
        state.setPhaseOption("run:\(seat.raw)", value: ids.joined(separator: ","))
    }

    static func clearBlocked(_ state: inout GameState, ctx: EvalContext) {
        for index in 0..<ctx.seatCount {
            state.setPhaseOption("blocked:\(index)", value: "0")
        }
    }

    static func hasPlayable(
        _ params: Params, seat: Seat, state: GameState, ctx: EvalContext
    ) -> Bool {
        !state.zones
            .cards(in: zoneKey(params.from, seat: seat))
            .contains {
                valueOf(params, card: $0, state: state, ctx: ctx) <= limitRemaining(state, params)
            }
    }

    static func allActiveBlocked(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> Bool {
        for index in 0..<ctx.seatCount {
            let seat = Seat(index)
            guard !state.zones.cards(in: zoneKey(params.from, seat: seat)).isEmpty else { continue }
            guard state.phaseOptions["blocked:\(seat.raw)"] == "1" else { return false }
        }
        return true
    }

    /// The card's value under `valueOf` (binding `c`). A failed evaluation
    /// reads as zero — never counts, never faults the phase; the fault
    /// surfaces through `evalCall`'s own diagnostics in the host runtime.
    static func valueOf(
        _ params: Params, card: CardInstance, state: GameState, ctx: EvalContext
    ) -> Int {
        guard
            case .int(let raw) =
                (try? ctx.evalCall(
                    .init(
                        pointer: "count-play.valueOf", source: params.valueOf.source, ruleId: id,
                        contextual: ["c": cardValue(card)]),
                    state: state))
        else { return 0 }
        return Int(exactly: raw) ?? 0
    }

    /// The points a play earns under `pointsOnPlay` (binding `seat`).
    static func pointsOnPlay(
        _ params: Params, seat: Seat, state: GameState, ctx: EvalContext
    ) -> Int {
        guard let expr = params.pointsOnPlay else { return 0 }
        guard
            case .int(let raw) =
                (try? ctx.evalCall(
                    .init(
                        pointer: "count-play.pointsOnPlay", source: expr.source, ruleId: id,
                        contextual: ["seat": .string(spelling(seat, ctx))]),
                    state: state))
        else { return 0 }
        return Int(exactly: raw) ?? 0
    }

    /// Awards points through the ruleset's effects runner, exactly as an
    /// `add` effect would (same variable, same index expression).
    static func award(
        _ params: Params, seat: Seat, points: Int, state: inout GameState,
        ctx: EvalContext, events: inout [GameEvent], reason: String
    ) throws(RuleViolation) {
        guard let name = params.awardName, let indexSource = params.awardIndex,
            let runner = ctx.effects
        else { return }
        var awarded = [GameEvent]()
        do {
            try runner.run(
                [.add(name: name, index: indexSource, value: "awarded", event: nil)],
                in: &state,
                bindings: [
                    "awarded": .int(Int64(points)),
                    "seat": .string(spelling(seat, ctx)),
                ],
                events: &awarded,
                pointer: "count-play/award")
        } catch {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "count-play award \(error)")
        }
        events += awarded
        events.append(.scored(seat: seat, points: points, reason: reason, ruleId: id))
    }

    static func cardValue(_ instance: CardInstance) -> EvalValue {
        .card(
            id: instance.face.id,
            suit: instance.face.suit?.code ?? "",
            rank: instance.face.rank.code)
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
