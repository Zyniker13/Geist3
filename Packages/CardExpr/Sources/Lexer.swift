/// A lexical error with the position where it was detected.
public struct LexerError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let position: SourcePosition

    public init(message: String, position: SourcePosition) {
        self.message = message
        self.position = position
    }

    public var description: String { "\(position): \(message)" }
}

/// The CardExpr lexer.
///
/// A single forward pass over the source: no backtracking, at most two
/// characters of lookahead (for two-character operators). It never traps
/// on any input; malformed input produces a `LexerError`.
public struct Lexer: Sendable {
    private let scalars: [Unicode.Scalar]

    public init(source: String) {
        self.scalars = Array(source.unicodeScalars)
    }

    /// Tokenizes the source, appending a trailing `eof` token.
    public func tokenize() throws -> [Token] {
        var tokens: [Token] = []
        var ctx = LexContext(count: scalars.count)

        while ctx.i < ctx.count {
            let current = scalars[ctx.i]
            if skipWhitespace(&ctx, current) { continue }
            let startLine = ctx.line
            let startCol = ctx.column

            if try intToken(&ctx, &tokens) { continue }
            if try stringToken(&ctx, &tokens) { continue }
            if try identToken(&ctx, &tokens) { continue }
            if try twoCharToken(&ctx, &tokens) { continue }
            if try oneCharToken(&ctx, &tokens) { continue }

            throw LexerError(
                message: "unexpected character '\(current)'",
                position: ctx.makePos(startLine, startCol))
        }

        let end = ctx.makePos(ctx.line, ctx.column)
        tokens.append(Token(kind: .eof, text: "", span: SourceSpan(start: end, end: end)))
        return tokens
    }

    // MARK: - Context

    private struct LexContext {
        var i: Int
        var line: Int
        var column: Int
        let count: Int

        init(count: Int) {
            self.i = 0
            self.line = 1
            self.column = 1
            self.count = count
        }

        func makePos(_ line: Int, _ column: Int) -> SourcePosition {
            SourcePosition(line: line, column: column)
        }
    }

    // MARK: - Tokenization helpers

    private func skipWhitespace(_ ctx: inout LexContext, _ char: Unicode.Scalar) -> Bool {
        if char == " " || char == "\t" || char == "\r" {
            ctx.i += 1
            ctx.column += 1
            return true
        }
        if char == "\n" {
            ctx.i += 1
            ctx.line += 1
            ctx.column = 1
            return true
        }
        return false
    }

    private func intToken(_ ctx: inout LexContext, _ tokens: inout [Token]) throws -> Bool {
        guard scalars[ctx.i] >= "0" && scalars[ctx.i] <= "9" else { return false }
        var value: Int64 = 0
        var end = ctx.i
        while end < ctx.count, scalars[end] >= "0" && scalars[end] <= "9" {
            let digit = Int64(scalars[end].value - 48)
            if value > (Int64.max - digit) / 10 {
                throw LexerError(
                    message: "integer literal out of range",
                    position: ctx.makePos(ctx.line, ctx.column))
            }
            value = value * 10 + digit
            end += 1
        }
        let text = String(scalars[ctx.i..<end].map { Character($0) })
        tokens.append(
            Token(
                kind: .int, text: text,
                span: SourceSpan(
                    start: ctx.makePos(ctx.line, ctx.column),
                    end: ctx.makePos(ctx.line, ctx.column + text.count - 1))))
        ctx.i = end
        ctx.column += text.count
        return true
    }

    private func stringToken(_ ctx: inout LexContext, _ tokens: inout [Token]) throws -> Bool {
        guard scalars[ctx.i] == "'" else { return false }
        var end = ctx.i + 1
        while end < ctx.count, scalars[end] != "'", scalars[end] != "\n" { end += 1 }
        guard end < ctx.count, scalars[end] == "'" else {
            throw LexerError(
                message: "unterminated string literal",
                position: ctx.makePos(ctx.line, ctx.column))
        }
        let text = String(scalars[ctx.i...end].map { Character($0) })
        tokens.append(
            Token(
                kind: .string, text: text,
                span: SourceSpan(
                    start: ctx.makePos(ctx.line, ctx.column),
                    end: ctx.makePos(ctx.line, ctx.column + text.count - 1))))
        ctx.i = end + 1
        ctx.column += text.count
        return true
    }

    private func identToken(_ ctx: inout LexContext, _ tokens: inout [Token]) throws -> Bool {
        guard isLetter(scalars[ctx.i]) else { return false }
        var end = ctx.i + 1
        while end < ctx.count, isIdentChar(scalars[end]) { end += 1 }
        let text = String(scalars[ctx.i..<end].map { Character($0) })
        let kind: Token.Kind
        switch text {
        case "true": kind = .keywordTrue
        case "false": kind = .keywordFalse
        case "null": kind = .keywordNull
        case "in": kind = .keywordIn
        default: kind = .ident
        }
        tokens.append(
            Token(
                kind: kind, text: text,
                span: SourceSpan(
                    start: ctx.makePos(ctx.line, ctx.column),
                    end: ctx.makePos(ctx.line, ctx.column + text.count - 1))))
        ctx.i = end
        ctx.column += text.count
        return true
    }

    private func twoCharToken(_ ctx: inout LexContext, _ tokens: inout [Token]) throws -> Bool {
        guard ctx.i + 1 < ctx.count else { return false }
        let two = String([Character(scalars[ctx.i]), Character(scalars[ctx.i + 1])])
        guard let kind: Token.Kind = Self.twoChar[two] else { return false }
        tokens.append(
            Token(
                kind: kind, text: two,
                span: SourceSpan(
                    start: ctx.makePos(ctx.line, ctx.column),
                    end: ctx.makePos(ctx.line, ctx.column + 1))))
        ctx.i += 2
        ctx.column += 2
        return true
    }

    private func oneCharToken(_ ctx: inout LexContext, _ tokens: inout [Token]) throws -> Bool {
        guard let kind: Token.Kind = Self.oneChar[scalars[ctx.i]] else { return false }
        tokens.append(
            Token(
                kind: kind, text: String(scalars[ctx.i]),
                span: SourceSpan(
                    start: ctx.makePos(ctx.line, ctx.column),
                    end: ctx.makePos(ctx.line, ctx.column))))
        ctx.i += 1
        ctx.column += 1
        return true
    }

    // MARK: - Predicates

    private func isLetter(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
    }

    private func isIdentChar(_ s: Unicode.Scalar) -> Bool {
        isLetter(s) || isDigit(s) || s == "_"
    }

    private func isDigit(_ s: Unicode.Scalar) -> Bool { s >= "0" && s <= "9" }

    // MARK: - Token maps

    private static let twoChar: [String: Token.Kind] = [
        "||": .pipePipe, "&&": .ampAmp, "==": .eqEq,
        "!=": .bangEq, "<=": .ltEq, ">=": .gtEq,
    ]

    private static let oneChar: [Unicode.Scalar: Token.Kind] = [
        "+": .plus, "-": .minus, "*": .star, "/": .slash, "%": .percent,
        "!": .bang, "<": .lt, ">": .gt, ".": .dot,
        "(": .lParen, ")": .rParen, "[": .lBracket, "]": .rBracket,
        ",": .comma, "?": .question, ":": .colon,
    ]
}
