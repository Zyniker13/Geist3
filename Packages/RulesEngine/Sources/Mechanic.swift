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
    static func apply(_ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext) throws(RuleViolation) -> [GameEvent]
    static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome
    static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet
}

/// Evaluation context handed to mechanics. P1: seat count and dealer; the
/// ruleset reference (CardExpr evaluation) arrives in P2.
@_spi(HostOnly)
public struct EvalContext: Sendable {
    public let seatCount: Int

    public init(seatCount: Int) {
        self.seatCount = seatCount
    }
}
