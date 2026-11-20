//! exchange.kitty (§5.6): the acting seat takes cards from a shared
//! stock/kitty zone into their hand and, when configured, lays away
//! (discards) the same number of cards into a shared discard zone.
//
// Euchre's pick-up is the reference case: the dealer takes the face-up
// card into their hand, then discards one card face-down into the
// kitty. Cribbage-style lay-away uses `discard` with no `take`.
//
// `take` resolves at phase entry: a string result names the shared
// zone to empty into the actor's hand; an integer result is the number
// of cards taken from the shared zone `kitty`. `discard` and
// `discardTo` likewise resolve once at entry, so the acting seat's
// later intents never re-evaluate rules text.

import CardModel

public struct ExchangeKittyParams: Codable, Hashable, Sendable {
    /// The acting seat (euchre: `dealer`).
    public let seat: ExprRef?
    /// Take: zone id (string) or count from the shared zone `kitty` (int).
    public let take: ExprRef?
    /// How many cards the seat lays away (nil → no discard step).
    public let discard: ExprRef?
    /// The shared zone receiving the laid-away cards.
    public let discardTo: ExprRef?
    /// Skip predicate evaluated at phase entry.
    public let skipIf: ExprRef?

    public init(
        seat: ExprRef? = nil,
        take: ExprRef? = nil,
        discard: ExprRef? = nil,
        discardTo: ExprRef? = nil,
        skipIf: ExprRef? = nil
    ) {
        self.seat = seat
        self.take = take
        self.discard = discard
        self.discardTo = discardTo
        self.skipIf = skipIf
    }
}

@_spi(HostOnly)
public enum ExchangeKittyMechanic: Mechanic {
    public static let id = "exchange.kitty"

    public typealias Params = ExchangeKittyParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let actor = try actingSeat(params, state: state, ctx: ctx)
        let pointer = "phases.exchange.kitty"
        // Resolve every parametrized value once, at entry (§7.4): later
        // intent handling reads plain numbers from phase options.
        let takeCount: Int
        let takeZone: String
        if let take = params.take {
            let value = try eval(take, ruleId: "exchange.kitty.take", state: state, ctx: ctx)
            switch value {
            case .string(let zone):
                takeZone = zone
                let key = ZoneKey(scope: .shared, id: zone)
                takeCount = state.zones.cards(in: key).count
            case .int(let n):
                guard let count = Int(exactly: n), count >= 0 else {
                    throw RuleViolation.engineFault(
                        ruleId: "exchange.kitty.take",
                        pointer: "\(take.pointer) produced \(value), not a valid count")
                }
                takeZone = "kitty"
                takeCount = count
            default:
                throw RuleViolation.engineFault(
                    ruleId: "exchange.kitty.take",
                    pointer: "\(take.pointer) produced \(value), not a zone or count")
            }
        } else {
            takeZone = "kitty"
            takeCount = 0
        }
        let discardCount: Int
        if let discard = params.discard {
            discardCount = try evalInt(
                discard, ruleId: "exchange.kitty.discard", pointer: discard.pointer,
                state: state, ctx: ctx)
        } else {
            discardCount = 0
        }
        let discardTo: String
        if let to = params.discardTo {
            let value = try eval(to, ruleId: "exchange.kitty.discardTo", state: state, ctx: ctx)
            guard case .string(let zone) = value else {
                throw RuleViolation.engineFault(
                    ruleId: "exchange.kitty.discardTo",
                    pointer: "\(to.pointer) produced \(value), not a zone id")
            }
            discardTo = zone
        } else {
            discardTo = "discard"
        }

        state.setPhaseOption("actor", value: "\(actor.raw)")
        state.setPhaseOption("to", value: discardTo)
        state.setPhaseOption("target", value: "\(discardCount)")
        state.setPhaseOption(takenKey(actor), value: "0")
        state.setPhaseOption(discardedKey(actor), value: "0")

        // Skip predicate: if true the exchange does not happen and the
        // phase completes immediately.
        if let skip = params.skipIf {
            let verdict = try eval(skip, ruleId: "exchange.kitty.skipIf", state: state, ctx: ctx)
            guard case .bool(let skipIt) = verdict else {
                throw RuleViolation.engineFault(
                    ruleId: "exchange.kitty.skipIf",
                    pointer: "\(skip.pointer) produced \(verdict), not a boolean")
            }
            if skipIt {
                state.setPhaseOption("done", value: "1")
                return []
            }
        }

        // Perform the take now: shared zone → actor's hand.
        var events: [GameEvent] = []
        if takeCount > 0 {
            let source = ZoneKey(scope: .shared, id: takeZone)
            let hand = ZoneKey(scope: .seat, owner: actor.raw, id: "hand")
            for _ in 0..<takeCount {
                guard let card = state.zones.cards(in: source).last else {
                    throw RuleViolation.engineFault(
                        ruleId: "exchange.kitty.take",
                        pointer: "zone '\(takeZone)' has no card to take")
                }
                do {
                    try state.zones.move(card.id, from: source, to: hand)
                } catch {
                    throw RuleViolation.engineFault(
                        ruleId: "exchange.kitty.take",
                        pointer: "take move failed: \(error)")
                }
                // The acting seat learns exactly what they took.
                var viewers = SeatSet()
                viewers.insert(actor)
                state.knowledge.reveal(card.id, to: viewers)
                events.append(.cardPlayed(seat: actor, card: card))
            }
            events.append(.cardsMoved(from: takeZone, to: "hand", count: takeCount))
            events.append(.received(seat: actor, count: takeCount))
        }
        state.setPhaseOption(takenKey(actor), value: "\(takeCount)")
        if discardCount == 0 {
            state.setPhaseOption("done", value: "1")
        }
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        guard Int(state.phaseOption("actor") ?? "-1") == seat.raw else { return [] }
        guard discarded(state, seat) < target(state) else { return [] }
        let hand = ZoneKey(scope: .seat, owner: seat.raw, id: "hand")
        return state.zones.cards(in: hand).map { .discard([$0.id]) }
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard Int(state.phaseOption("actor") ?? "-1") == seat.raw else {
            throw RuleViolation.illegal(
                ruleId: "exchange.kitty.actor",
                detail: .custom("\(spelling(seat, ctx)) is not the exchange actor"))
        }
        guard case .discard(let ids) = intent, ids.count == 1, let cardID = ids.first else {
            throw RuleViolation.illegal(
                ruleId: "exchange.kitty.kind",
                detail: .custom("exchange.kitty takes one .discard card"))
        }
        guard discarded(state, seat) < target(state) else {
            throw RuleViolation.illegal(
                ruleId: "exchange.kitty.target",
                detail: .custom("exchange.kitty discards are already complete"))
        }
        let hand = ZoneKey(scope: .seat, owner: seat.raw, id: "hand")
        guard state.zones.zoneOf(cardID) == hand else {
            throw RuleViolation.illegal(
                ruleId: "exchange.kitty.zone",
                detail: .custom("card '\(cardID)' is not in \(spelling(seat, ctx))'s hand"))
        }
        guard let card = state.zones.cards(in: hand).first(where: { $0.id == cardID }) else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.kitty.zone",
                pointer: "card \(cardID.raw) missing from the hand")
        }
        let toKey = state.phaseOption("to") ?? "discard"
        let targetZone = ZoneKey(scope: .shared, id: toKey)
        do {
            try state.zones.move(cardID, from: hand, to: targetZone)
        } catch {
            throw RuleViolation.engineFault(
                ruleId: "exchange.kitty.discard", pointer: "discard move failed: \(error)")
        }
        // A laid-away card stays known to its discarder only; nobody else
        // learns what went down.
        state.setPhaseOption(
            discardedKey(seat), value: "\(discarded(state, seat) + 1)")
        if discarded(state, seat) >= target(state) {
            state.setPhaseOption("done", value: "1")
        }
        return [.cardPlayed(seat: seat, card: card)]
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        return state.phaseOption("done") == "1" ? .complete : .continue
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        guard (Int(state.phaseOption("actor") ?? "-1") ?? -1) >= 0,
            state.phaseOption("done") != "1"
        else { return SeatSet() }
        let actor = Seat(Int(state.phaseOption("actor") ?? "0") ?? 0)
        guard discarded(state, actor) < target(state) else { return SeatSet() }
        var pending = SeatSet()
        pending.insert(actor)
        return pending
    }

    // MARK: - Internals

    static func eval(
        _ ref: ExprRef, ruleId: String, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> EvalValue {
        return try ctx.evalCall(
            EvalCall(pointer: ref.pointer, source: ref.source, ruleId: ruleId),
            state: state)
    }

    static func evalInt(
        _ ref: ExprRef, ruleId: String, pointer: String, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Int {
        let value = try eval(ref, ruleId: ruleId, state: state, ctx: ctx)
        guard case .int(let n) = value else {
            throw RuleViolation.engineFault(
                ruleId: ruleId,
                pointer: "\(pointer) produced \(value), not an integer")
        }
        guard let count = Int(exactly: n) else {
            throw RuleViolation.engineFault(
                ruleId: ruleId,
                pointer: "\(pointer) produced \(n), out of Int range")
        }
        return count
    }

    /// The acting seat, resolved from the seat expression (§7.4).
    static func actingSeat(
        _ params: Params, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
        guard let seat = params.seat else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.kitty.seat",
                pointer: "params.seat is required")
        }
        let value = try eval(seat, ruleId: "exchange.kitty.seat", state: state, ctx: ctx)
        guard let name = value.seatOrTeam else {
            throw RuleViolation.engineFault(
                ruleId: "exchange.kitty.seat",
                pointer: "\(seat.pointer) produced \(value), not a seat")
        }
        if let index = ctx.seatNames.firstIndex(of: name) {
            return Seat(index)
        }
        if name.hasPrefix("S"), let n = Int(name.dropFirst()), n >= 1 {
            return Seat(n - 1)
        }
        throw RuleViolation.engineFault(
            ruleId: "exchange.kitty.seat",
            pointer: "\(seat.pointer) produced unknown seat '\(name)'")
    }

    static func target(_ state: GameState) -> Int {
        Int(state.phaseOption("target") ?? "0") ?? 0
    }

    static func discarded(_ state: GameState, _ seat: Seat) -> Int {
        Int(state.phaseOption(discardedKey(seat)) ?? "0") ?? 0
    }

    static func takenKey(_ seat: Seat) -> String { "taken:\(seat.raw)" }

    static func discardedKey(_ seat: Seat) -> String { "discarded:\(seat.raw)" }

    static func spelling(_ seat: Seat, _ ctx: EvalContext) -> String {
        if ctx.seatNames.indices.contains(seat.raw) { return ctx.seatNames[seat.raw] }
        return "S\(seat.raw + 1)"
    }
}
