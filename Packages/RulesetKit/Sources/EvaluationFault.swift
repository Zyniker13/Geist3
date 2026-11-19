/// A runtime evaluation fault (ARCHITECTURE.md §7.4).
///
/// Fuel exhaustion, integer overflow, division by zero, a `null`
/// dereference, and an out-of-range index all raise this fault. The
/// engine (P3) maps it onto `RuleViolation.engineFault(ruleId:pointer:)`;
/// `EvaluationFault` lives here so the pure DSL package does not depend
/// on the engine.
public struct EvaluationFault: Error, Sendable, Equatable {
    /// What went wrong.
    public enum Kind: String, Sendable {
        case fuelExhausted
        case integerOverflow
        case divisionByZero
        case nullDereference
        case indexOutOfRange
        case unsupportedValue
    }

    /// The kind of fault.
    public let kind: Kind
    /// The rule that was being evaluated, when the caller supplies one.
    public let ruleId: String?
    /// The JSON pointer of the expression in the ruleset document.
    public let pointer: String
    /// Human-readable detail for diagnostics.
    public let message: String

    public init(kind: Kind, ruleId: String? = nil, pointer: String, message: String) {
        self.kind = kind
        self.ruleId = ruleId
        self.pointer = pointer
        self.message = message
    }

    /// The §7.4 fuel budget for one expression evaluation.
    public static let expressionBudget = 10_000
    /// The §7.4 fuel budget for one reducer step (all expressions in it
    /// combined); the engine enforces the step total across calls.
    public static let reducerStepBudget = 250_000
}
