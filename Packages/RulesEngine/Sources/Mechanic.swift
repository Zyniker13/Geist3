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
    /// One internal automatic step (ADR-0032). Only invoked by the engine
    /// while `isComplete` returns `.autoStep`; the engine runs the
    /// continuous end check between steps. Default: no steps.
    static func step(_ params: Params, state: inout GameState, ctx: EvalContext) throws(RuleViolation) -> [GameEvent]
}

extension Mechanic {
    public static func step(_ params: Params, state: inout GameState, ctx: EvalContext) throws(RuleViolation)
        -> [GameEvent]
    {
        []
    }
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
    /// Seat spellings in seat order (§7.3); empty means `S1…Sn`.
    public let seatNames: [String]
    /// Team spellings in team order; empty means no teams.
    public let teamNames: [String]
    /// Maps a seat position to its team position.
    public let teamOfSeat: [Int]
    /// Table options (§5.9), keyed by name.
    public let options: [String: String]
    /// Runs ruleset effects (§5.6). Nil means the ruleset has no effects.
    public let effects: EffectsRunner?

    public init(
        seatCount: Int, dealer: Seat? = nil,
        eval: (@Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)? = nil,
        seatNames: [String] = [],
        teamNames: [String] = [],
        teamOfSeat: [Int] = [],
        options: [String: String] = [:],
        effects: EffectsRunner? = nil
    ) {
        self.seatCount = seatCount
        self.dealer = dealer
        self.eval = eval
        self.seatNames = seatNames
        self.teamNames = teamNames
        self.teamOfSeat = teamOfSeat
        self.options = options
        self.effects = effects
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
