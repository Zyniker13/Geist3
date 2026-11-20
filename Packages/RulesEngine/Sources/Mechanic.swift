// The Mechanic protocol (ARCHITECTURE §5.6). Mechanics are the only code
// that mutates play state; every mutation flows through `apply`.
// Host-only: mechanics manipulate the full GameState (§9.1), which never
// leaves the host; bots and UI consume Observation only.

import CardModel

/// Parameters are Codable & Sendable data; P1 configures them in Swift
/// (JSON parsing and validation arrive with the ruleset DSL in P2).
@_spi(HostOnly)
public protocol Mechanic: Sendable {
    static var id: String { get }
    associatedtype Params: Codable & Sendable
    static func enter(_ params: Params, state: inout GameState, ctx: EvalContext) throws(RuleViolation) -> [GameEvent]
    static func legalIntents(_ params: Params, state: GameState, seat: Seat, ctx: EvalContext) -> [ActionIntent]
    static func apply(_ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext)
        throws(RuleViolation) -> [GameEvent]
    static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome
    static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet
}

/// Evaluation context handed to mechanics (§7.3–§7.5): the seat count,
/// the dealer, and the host-mediated expression runtime. `eval` is null
/// only when the host installs no runtime (pure mechanics, unit tests);
/// a mechanic that receives null where its parameters are expressions
/// fails with `RuleViolation.engineFault` — never a silent default.
@_spi(HostOnly)
public struct EvalContext: Sendable {
    public let seatCount: Int
    public let dealer: Seat?
    /// Evaluates one expression (§7.5). The engine owns no evaluator;
    /// the host installs this through `Engine`.
    public let eval: (@Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)?

    public init(
        seatCount: Int, dealer: Seat? = nil,
        eval: (@Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)? = nil
    ) {
        self.seatCount = seatCount
        self.dealer = dealer
        self.eval = eval
    }

    /// Evaluates one expression, mapping any failure onto an engine
    /// fault carrying the rule and pointer (§7.4).
    public func evalCall(
        _ call: EvalCall, state: GameState, ruleId: String? = nil
    ) throws(RuleViolation) -> EvalValue {
        guard let eval else {
            throw RuleViolation.engineFault(
                ruleId: ruleId ?? call.ruleId,
                pointer: "\(call.pointer) no expression runtime installed")
        }
        do {
            return try eval(call, state)
        } catch {
            throw RuleViolation.engineFault(
                ruleId: ruleId ?? call.ruleId,
                pointer: "\(call.pointer) \(Self.describe(error))")
        }
    }

    private static func describe(_ failure: EvalFailure) -> String {
        switch failure {
        case .budget: return "expression fuel exhausted"
        case .fault(_, let detail): return detail
        }
    }
}
