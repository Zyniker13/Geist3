// The `reveal.starter` mechanic (ARCHITECTURE §5.6): one seat cuts the
// source packet and the card behind the cut becomes the starter card.
// The phase is automatic — no seat intents — with the cut depth chosen
// by the engine's seeded RNG at or above `minCutDepth`, so replays are
// deterministic. The `after` effects (e.g. hisHeels scoring) run once
// the starter is on the table.

import CardModel

public struct RevealStarterParams: Codable, Hashable, Sendable {
    /// Who cuts (a seat expression such as `pone()`); evaluated at phase
    /// entry with the dealer bound. Nil means no seat is recorded.
    public let cutBy: ExprRef?
    /// Source packet zone (shared, e.g. the stock).
    public let from: String
    /// Zone the starter card lands in (shared, public visibility).
    public let to: String
    /// Floor on the cut depth (cards lifted); nil means no floor.
    public let minCutDepth: Int?
    /// Effects run after the starter is revealed.
    public let afterEffects: [EngineEffect]

    public init(
        cutBy: ExprRef?, from: String, to: String,
        minCutDepth: Int? = nil, afterEffects: [EngineEffect] = []
    ) {
        self.cutBy = cutBy
        self.from = from
        self.to = to
        self.minCutDepth = minCutDepth
        self.afterEffects = afterEffects
    }
}

@_spi(HostOnly)
public enum RevealStarterMechanic: Mechanic {
    public static let id = "reveal.starter"

    public typealias Params = RevealStarterParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        let sourceKey = ZoneKey(scope: .shared, id: params.from)
        guard state.zones.zones[sourceKey] != nil else {
            throw RuleViolation.engineFault(
                ruleId: "reveal.starter.zone",
                pointer: "phases.reveal.starter.from unknown zone '\(params.from)'")
        }
        let cards = state.zones.cards(in: sourceKey)
        let floor = params.minCutDepth ?? 0
        guard cards.count > floor else {
            throw RuleViolation.engineFault(
                ruleId: "reveal.starter.cut",
                pointer: "phases.reveal.starter \(params.from) has \(cards.count) cards, cut floor is \(floor)")
        }

        var cutSeat: Seat?
        if let cutBy = params.cutBy {
            let value = try ctx.evalCall(
                EvalCall(
                    pointer: cutBy.pointer, source: cutBy.source,
                    ruleId: "reveal.starter.cutBy"),
                state: state)
            cutSeat = try seat(from: value, ctx: ctx, pointer: cutBy.pointer)
        }

        // The cut depth is engine-chosen, seeded, and at or above the
        // floor: at least `floor` cards stay on the lifted packet and at
        // least one card remains under the cut.
        let depth = floor + state.rng.below(cards.count - floor)
        let starter = cards[depth]
        do {
            try state.zones.move(
                starter.id, from: sourceKey, to: ZoneKey(scope: .shared, id: params.to))
        } catch {
            throw RuleViolation.engineFault(
                ruleId: "reveal.starter.move", pointer: "starter move failed: \(error)")
        }

        // The starter is public: every seat learns it.
        var everyone = SeatSet()
        for i in 0..<ctx.seatCount { everyone.insert(Seat(i)) }
        state.knowledge.reveal(starter.id, to: everyone)
        state.setPhaseOption("cutBy", value: cutSeat.map { "\($0.raw)" } ?? "-1")
        state.setPhaseOption("cutDepth", value: "\(depth)")

        var events: [GameEvent] = [.revealed(zone: params.to, cards: [starter])]
        if let runner = ctx.effects, !params.afterEffects.isEmpty {
            var bindings: [String: EvalValue] = [:]
            if let cutSeat {
                bindings["cut"] = .string(spelling(cutSeat, ctx))
            }
            try runner.run(
                params.afterEffects, in: &state, bindings: bindings,
                events: &events, pointer: "phases.reveal.starter.after")
        }
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        // The starter reveal is automatic; seats never act.
        return []
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        throw RuleViolation.illegal(
            ruleId: "reveal.starter.automatic",
            detail: .custom("reveal.starter is automatic; seats do not act"))
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        // One automatic step; done as soon as it has run.
        return state.phaseOption("cutDepth") == nil ? .continue : .complete
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        return SeatSet()
    }

    // MARK: - Internals

    /// Resolves a seat spelling onto a seat position (§7.3).
    private static func seat(
        from value: EvalValue, ctx: EvalContext, pointer: String
    ) throws(RuleViolation) -> Seat {
        guard let spelling = value.seatOrTeam else {
            throw RuleViolation.engineFault(
                ruleId: "reveal.starter.cutBy", pointer: "\(pointer) produced \(value), not a seat")
        }
        if let index = ctx.seatNames.firstIndex(of: spelling) {
            return Seat(index)
        }
        if spelling.hasPrefix("S"), let n = Int(spelling.dropFirst()), n >= 1 {
            return Seat(n - 1)
        }
        throw RuleViolation.engineFault(
            ruleId: "reveal.starter.cutBy", pointer: "\(pointer) produced unknown seat '\(spelling)'")
    }

    /// The spelling used for a seat in the host expression runtime (§7.3):
    /// the ruleset's seat names when supplied, else `S1…Sn`.
    private static func spelling(_ seat: Seat, _ ctx: EvalContext) -> String {
        if ctx.seatNames.indices.contains(seat.raw) { return ctx.seatNames[seat.raw] }
        return "S\(seat.raw + 1)"
    }
}
