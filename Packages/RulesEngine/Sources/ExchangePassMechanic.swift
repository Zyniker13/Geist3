// The `exchange.pass` mechanic (ARCHITECTURE §5.6): players pass one card
// to the next player in turn order.

import CardModel

public struct ExchangePassParams: Codable, Hashable, Sendable {
    /// Zone the cards come from (each player's hand).
    public let source: String
    /// Zone the cards go to (each player's hand).
    public let target: String
    /// Number of cards each player passes.
    public let count: Int
    /// Direction: "left" (next seat) or "right" (previous seat).
    public let direction: String

    public init(source: String, target: String, count: Int, direction: String = "left") {
        self.source = source
        self.target = target
        self.count = count
        self.direction = direction
    }
}

@_spi(HostOnly)
public enum ExchangePassMechanic: Mechanic {
    public static let id = "exchange.pass"

    public typealias Params = ExchangePassParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        // Pass phase: players act one at a time.
        return [.phaseStarted("exchange.pass")]
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        // Only the current seat acts; they must choose a card to pass.
        guard isPending(params, state: state, seat: seat) else { return [] }
        let handKey = ZoneKey(scope: .seat, owner: seat.raw, id: params.source)
        let cards = state.zones.cards(in: handKey)
        return cards.map { .play($0.id) }
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard case .play(let cardID) = intent else {
            throw RuleViolation.illegal(
                ruleId: "exchange.playOnly",
                detail: .custom("exchange.pass accepts .play intents"))
        }
        guard isPending(params, state: state, seat: seat) else {
            throw RuleViolation.notYourTurn(expected: pendingSeats(params, state: state, ctx: ctx))
        }
        let handKey = ZoneKey(scope: .seat, owner: seat.raw, id: params.source)
        guard state.zones.zoneOf(cardID) == handKey else {
            throw RuleViolation.illegal(ruleId: "exchange.notInHand", detail: .notInHand(cardID))
        }
        guard let card = state.zones.cards(in: handKey).first(where: { $0.id == cardID }) else {
            throw RuleViolation.engineFault(ruleId: "exchange.notInHand", pointer: "card \(cardID.raw) in hand index")
        }

        // Determine the destination seat.
        let destSeat = directionSeat(seat, params.direction, ctx.seatCount)
        let destKey = ZoneKey(scope: .seat, owner: destSeat.raw, id: params.target)

        // Move the card.
        do {
            try state.zones.move(cardID, from: handKey, to: destKey)
        } catch {
            throw RuleViolation.engineFault(ruleId: "exchange.move", pointer: "\(error)")
        }

        // Record the pass.
        state.setPhaseOption("passed_\(seat.raw)", value: "\(destSeat.raw)")
        state.setPhaseOption("lastPass", value: "\(seat.raw)->\(destSeat.raw)")
        return [.cardPlayed(seat: seat, card: card)]
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        // Complete when all seats have passed.
        guard state.phaseOption("lastPass") != nil else { return .continue }
        let passes = state.phaseOptions.count
        return passes >= ctx.seatCount ? .complete : .continue
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        var seats = SeatSet()
        for i in 0..<ctx.seatCount {
            let seat = Seat(i)
            if isPending(params, state: state, seat: seat) {
                seats.insert(seat)
            }
        }
        return seats
    }

    // MARK: - Internals

    private static func isPending(_ params: Params, state: GameState, seat: Seat) -> Bool {
        // A seat has acted if it has already passed a card (tracked by the
        // phase option). Each seat passes exactly once.
        let handKey = ZoneKey(scope: .seat, owner: seat.raw, id: params.source)
        let cards = state.zones.cards(in: handKey)
        let targetKey = ZoneKey(scope: .seat, owner: seat.raw, id: params.target)
        let targetCards = state.zones.cards(in: targetKey)
        // If the seat has fewer cards than it started with (or has received
        // cards), it has passed. We track via phase options.
        let passKey = "passed_\(seat.raw)"
        return state.phaseOption(passKey) == nil
    }

    private static func directionSeat(_ seat: Seat, _ direction: String, _ seatCount: Int) -> Seat {
        switch direction {
        case "left":
            return Seat((seat.raw + 1) % seatCount)
        case "right":
            return Seat((seat.raw - 1 + seatCount) % seatCount)
        default:
            return Seat((seat.raw + 1) % seatCount)
        }
    }
}
