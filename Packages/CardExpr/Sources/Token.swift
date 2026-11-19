/// A single lexical token with its source position.
public struct Token: Sendable, Hashable {
    /// Token categories.
    public enum Kind: Sendable, Hashable {
        case int
        case string
        case ident
        case keywordTrue
        case keywordFalse
        case keywordNull
        case keywordIn
        case plus
        case minus
        case star
        case slash
        case percent
        case bang
        case ampAmp
        case pipePipe
        case eqEq
        case bangEq
        case lt
        case ltEq
        case gt
        case gtEq
        case dot
        case lParen
        case rParen
        case lBracket
        case rBracket
        case comma
        case question
        case colon
        case eof
    }

    public let kind: Kind
    /// Raw source text of the token (empty for `eof`).
    public let text: String
    public let span: SourceSpan

    public init(kind: Kind, text: String, span: SourceSpan) {
        self.kind = kind
        self.text = text
        self.span = span
    }

    /// Integer value of an `int` token, or `nil` for other kinds.
    public var intValue: Int64? {
        kind == .int ? Int64(text) : nil
    }

    /// String content of a `string` token (without the quotes), or `nil`.
    public var stringValue: String? {
        guard kind == .string else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// Compact description used by tests and diagnostics.
    public var describe: String {
        switch kind {
        case .int: "int(\(text))"
        case .string: "str('\(text.dropFirst().dropLast())')"
        case .ident: "id(\(text))"
        case .keywordTrue: "kw(true)"
        case .keywordFalse: "kw(false)"
        case .keywordNull: "kw(null)"
        case .keywordIn: "kw(in)"
        case .eof: "eof"
        default: "op(\(text))"
        }
    }

    /// Message fragment for "unexpected token" diagnostics.
    public var unexpected: String {
        kind == .eof ? "unexpected end of input" : "unexpected token '\(text)'"
    }
}
