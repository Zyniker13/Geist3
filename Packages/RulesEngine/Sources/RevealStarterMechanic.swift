// The `reveal.starter` mechanic (ARCHITECTURE §5.6): reveal cards from a
// source zone to a target zone (e.g., revealing a starter card in cribbage).

import CardModel

public struct RevealStarterParams: Codable, Hashable, Sendable {
    /// Zone the starter cards come from.
    public let source: String
    /// Zone the revealed cards go to.
    public let target: String
    /// Number of cards to reveal.
    public let count: Int
    /// Seats that can see the revealed cards (default: all seats).
    public let visibleTo: SeatSet

    public init(source: String, target: String, count: Int, visibleTo: SeatSet = SeatSet.allSeats(4)) {
        self.source = source
        self.target = target
        self.count = count
        self.visibleTo = visibleTo
    }
}

@_spi(HostOnly)
public enum RevealStarterMechanic: Mechanic {
    public static let id = "reveal.starter"

    public typealias Params = RevealStarterParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var events: [GameEvent] = []
        let sourceKey = ZoneKey(scope: .shared, id: params.source)
        let targetKey = ZoneKey(scope: .shared, id: params.target)
        state.zones.ensureDeclared(targetKey)

        var revealed: [CardInstance] = []
        for _ in 0..<params.count {
            let popped = try? state.zones.popTop(from: sourceKey)
            guard let card = popped ?? nil else {
                throw RuleViolation.engineFault(
                    ruleId: "reveal.empty",
                    pointer: "source \(params.source) exhausted")
            }
            do {
                try state.zones.place(card, in: targetKey)
            } catch {
                throw RuleViolation.engineFault(
                    ruleId: "reveal.place",
                    pointer: "\(error)")
            }
            state.knowledge.reveal(card.id, to: params.visibleTo)
            revealed.append(card)
        }
        events.append(.revealed(zone: params.target, cards: revealed))
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        []  // revealing is automatic
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        throw RuleViolation.illegal(
            ruleId: "reveal.automatic",
            detail: .custom("reveal.starter is not player-driven"))
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        .complete
    }

    public static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet {
        SeatSet()  // nobody acts during reveal
    }
}
