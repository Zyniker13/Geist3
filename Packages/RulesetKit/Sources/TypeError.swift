import CardExpr

/// A type error found while checking a ruleset expression.
///
/// The span points into the expression text the rule came from; def-level
/// problems (signature parsing, recursion) are reported by the loader with
/// the JSON pointer of the offending field, so here they carry the span of
/// the def body or call site they were found at.
public struct TypeError: Error, CustomStringConvertible, Sendable {
    public let span: SourceSpan
    public let message: String

    public init(span: SourceSpan, message: String) {
        self.span = span
        self.message = message
    }

    public var description: String { "\(span.start): type error: \(message)" }
}
