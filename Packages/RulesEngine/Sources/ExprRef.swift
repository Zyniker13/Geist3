// An expression reference carried by engine mechanics (§7.3–§7.5).
//
// Mechanic params must be plain `Codable` data, while rulesets deliver
// expressions as source text. `ExprRef` is the plain-data carrier: the
// host builder copies the schema expression's pointer and source
// verbatim, and the mechanic evaluates it at the moment the rules
// require through `EvalContext.evalCall`. The engine owns no evaluator.

public struct ExprRef: Codable, Hashable, Sendable {
    /// JSON pointer of the expression in the ruleset document, for faults.
    public let pointer: String
    /// Verbatim expression source text.
    public let source: String

    public init(pointer: String, source: String) {
        self.pointer = pointer
        self.source = source
    }
}
