// The score mechanic (§5.6): pure effects plus optional interactive
// choices. When no choice is pending the effects run once; when a choice
// gates the scoring (e.g. hearts' moon), the selected seats choose first
// and the effects run with `choice(id, seat)` resolving the picks.

import CardModel

#if canImport(Foundation)
    import Foundation
#endif

@_spi(HostOnly)
public struct ScoreChoiceRef: Codable, Hashable, Sendable {
    /// The choice id referenced by `choice(id, seat)` in effects.
    public let id: String
    /// Seat expression naming who chooses.
    public let seat: ExprRef
    /// Gate; the choice is only asked when this evaluates true.
    public let when: ExprRef
    /// Allowed answers.
    public let values: [String]

    public init(id: String, seat: ExprRef, when: ExprRef, values: [String]) {
        self.id = id
        self.seat = seat
        self.when = when
        self.values = values
    }
}

@_spi(HostOnly)
public struct ScoreParams: Codable, Hashable, Sendable {
    /// The scoring effects, run once when choices (if any) are settled.
    public let effects: [EngineEffect]
    /// Optional interactive choices gating the effects.
    public let choices: [ScoreChoiceRef]?

    public init(effects: [EngineEffect], choices: [ScoreChoiceRef]? = nil) {
        self.effects = effects
        self.choices = choices
    }
}

@_spi(HostOnly)
public struct ScoreMechanic: Mechanic {
    public typealias Params = ScoreParams

    public static let id = "score"

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard let choices = params.choices, !choices.isEmpty else {
            return try runEffects(params, state: &state, ctx: ctx, bindings: [:])
        }
        var events: [GameEvent] = []
        for choice in choices {
            let gate = try ctx.evalCall(
                .init(pointer: "score.choices[\(choice.id)].when", source: choice.when.source, ruleId: id),
                state: state)
            guard case .bool(let active) = gate else {
                throw RuleViolation.engineFault(
                    ruleId: id,
                    pointer: "score.choices[\(choice.id)].when not a boolean")
            }
            guard active else { continue }
            let seatValue = try ctx.evalCall(
                .init(pointer: "score.choices[\(choice.id)].seat", source: choice.seat.source, ruleId: id),
                state: state)
            let seat = try seatOf(
                seatValue, pointer: "score.choices[\(choice.id)].seat", ctx: ctx)
            guard !choice.values.isEmpty else {
                throw RuleViolation.engineFault(
                    ruleId: id, pointer: "score.choices[\(choice.id)] has no values")
            }
            state.setPhaseOption("pending:\(choice.id)", value: seat.raw.description)
        }
        if pendingSeats(params, state: state, ctx: ctx).isEmpty {
            return try runEffects(params, state: &state, ctx: ctx, bindings: [:])
        }
        return events
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        guard let choice = pendingChoice(params, state: state, seat: seat) else { return [] }
        return choice.values.map { .choose($0) }
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat,
        state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        guard case .choose(let answer) = intent else {
            throw RuleViolation.engineFault(ruleId: id, pointer: "score expects a choose")
        }
        guard let choice = pendingChoice(params, state: state, seat: seat) else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "score: no pending choice for seat \(seat.raw)")
        }
        guard choice.values.contains(answer) else {
            throw RuleViolation.engineFault(
                ruleId: id, pointer: "score: \(answer) is not a legal \(choice.id) answer")
        }
        state.setPhaseOption("choice:\(choice.id):\(seat.raw)", value: answer)
        state.setPhaseOption("pending:\(choice.id)", value: "")
        var events: [GameEvent] = []
        if pendingSeats(params, state: state, ctx: ctx).isEmpty {
            events += try runEffects(params, state: &state, ctx: ctx, bindings: [:])
        }
        return events
    }

    public static func isComplete(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> PhaseOutcome {
        state.phaseOptions["scored"] == "1" ? .complete : .continue
    }

    public static func pendingSeats(
        _ params: Params, state: GameState, ctx: EvalContext
    ) -> SeatSet {
        var seats = SeatSet()
        for (key, raw) in state.phaseOptions where key.hasPrefix("pending:") && !raw.isEmpty {
            if let index = Int(raw) { seats.insert(Seat(index)) }
        }
        return seats
    }

    // MARK: - Helpers

    /// The choice a seat still owes, if any. Choices pend per seat, so
    /// several seats may answer in any order and legality never depends
    /// on dictionary iteration order (§10 determinism).
    static func pendingChoice(
        _ params: Params, state: GameState, seat: Seat
    ) -> ScoreChoiceRef? {
        guard let choices = params.choices else { return nil }
        for choice in choices
        where state.phaseOptions["pending:\(choice.id)"] == seat.raw.description {
            return choice
        }
        return nil
    }

    static func runEffects(
        _ params: Params, state: inout GameState, ctx: EvalContext,
        bindings: [String: EvalValue]
    ) throws(RuleViolation) -> [GameEvent] {
        state.setPhaseOption("scored", value: "1")
        guard let runner = ctx.effects else { return [] }
        var events = [GameEvent]()
        do {
            try runner.run(
                params.effects, in: &state, bindings: bindings, events: &events,
                pointer: "score/effects")
        } catch {
            throw RuleViolation.engineFault(ruleId: id, pointer: "score effects \(error)")
        }
        return events
    }

    static func seatOf(
        _ value: EvalValue, pointer: String, ctx: EvalContext
    ) throws(RuleViolation) -> Seat {
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
}
