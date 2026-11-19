/// A parse error with the position where it was detected.
public struct ParseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let position: SourcePosition

    public init(message: String, position: SourcePosition) {
        self.message = message
        self.position = position
    }

    public var description: String { "\(position): \(message)" }
}

/// The result of parsing a CardExpr expression.
public struct ParsedExpression: Sendable {
    public let ast: AST
    /// Number of AST nodes (input to the §11.3 size limit).
    public let nodeCount: Int

    public init(ast: AST, nodeCount: Int) {
        self.ast = ast
        self.nodeCount = nodeCount
    }
}

/// The CardExpr Pratt parser.
///
/// A single forward pass over the token stream: no backtracking. Every
/// input either parses or produces a `ParseError` (or `LexerError`); the
/// parser never traps.
public struct Parser: Sendable {
    public init() {}

    /// Parses a single expression. The whole input must be consumed.
    public func parse(_ source: String) throws -> ParsedExpression {
        let tokens = try Lexer(source: source).tokenize()
        var cursor = Cursor(tokens: tokens)
        let ast = try cursor.parseTernary()
        guard cursor.peek().kind == .eof else {
            throw ParseError(message: cursor.peek().unexpected, position: cursor.peek().span.start)
        }
        return ParsedExpression(ast: ast, nodeCount: ast.nodeCount)
    }
}

private struct Cursor {
    let tokens: [Token]
    var index: Int

    init(tokens: [Token]) {
        self.tokens = tokens
        self.index = 0
    }

    func peek() -> Token {
        tokens[index]
    }

    mutating func advance() -> Token {
        let current = tokens[index]
        if index < tokens.count - 1 {
            index += 1
        }
        return current
    }

    mutating func expect(_ kind: Token.Kind, _ what: String) throws -> Token {
        let current = peek()
        guard current.kind == kind else {
            throw ParseError(
                message: "expected \(what) but found \(current.describe)",
                position: current.span.start)
        }
        return advance()
    }

    // MARK: - Expression levels (lowest to highest precedence)

    mutating func parseTernary() throws -> AST {
        let cond = try parseOr()
        if peek().kind == .question {
            _ = advance()
            let then = try parseTernary()
            _ = try expect(.colon, "':'")
            let els = try parseTernary()
            return .ternary(cond, then, els, SourceSpan(start: cond.span.start, end: els.span.end))
        }
        return cond
    }

    mutating func parseOr() throws -> AST {
        var lhs = try parseAnd()
        while peek().kind == .pipePipe {
            _ = advance()
            let rhs = try parseAnd()
            lhs = .binary(.or, lhs, rhs, SourceSpan(start: lhs.span.start, end: rhs.span.end))
        }
        return lhs
    }

    mutating func parseAnd() throws -> AST {
        var lhs = try parseEquality()
        while peek().kind == .ampAmp {
            _ = advance()
            let rhs = try parseEquality()
            lhs = .binary(.and, lhs, rhs, SourceSpan(start: lhs.span.start, end: rhs.span.end))
        }
        return lhs
    }

    mutating func parseEquality() throws -> AST {
        var lhs = try parseRelational()
        while peek().kind == .eqEq || peek().kind == .bangEq {
            let op = advance()
            let rhs = try parseRelational()
            let kind: AST.Operator = op.kind == .eqEq ? .eq : .neq
            lhs = .binary(kind, lhs, rhs, SourceSpan(start: lhs.span.start, end: rhs.span.end))
        }
        return lhs
    }

    mutating func parseRelational() throws -> AST {
        var lhs = try parseAdditive()
        while true {
            guard let op = relationalOp() else { return lhs }
            _ = advance()
            let rhs = try parseAdditive()
            lhs = .binary(op, lhs, rhs, SourceSpan(start: lhs.span.start, end: rhs.span.end))
        }
    }

    private mutating func relationalOp() -> AST.Operator? {
        switch peek().kind {
        case .lt: return .lt
        case .ltEq: return .le
        case .gt: return .gt
        case .gtEq: return .ge
        case .keywordIn: return .inOp
        default: return nil
        }
    }

    mutating func parseAdditive() throws -> AST {
        var lhs = try parseMultiplicative()
        while peek().kind == .plus || peek().kind == .minus {
            let op = advance()
            let rhs = try parseMultiplicative()
            let kind: AST.Operator = op.kind == .plus ? .add : .sub
            lhs = .binary(kind, lhs, rhs, SourceSpan(start: lhs.span.start, end: rhs.span.end))
        }
        return lhs
    }

    mutating func parseMultiplicative() throws -> AST {
        var lhs = try parseUnary()
        while peek().kind == .star || peek().kind == .slash || peek().kind == .percent {
            let op = advance()
            let rhs = try parseUnary()
            let kind: AST.Operator
            switch op.kind {
            case .star: kind = .mul
            case .slash: kind = .div
            default: kind = .mod
            }
            lhs = .binary(kind, lhs, rhs, SourceSpan(start: lhs.span.start, end: rhs.span.end))
        }
        return lhs
    }

    mutating func parseUnary() throws -> AST {
        let token = peek()
        if token.kind == .bang {
            advance()
            let operand = try parseUnary()
            return .unary(.not, operand, SourceSpan(start: token.span.start, end: operand.span.end))
        }
        if token.kind == .minus {
            advance()
            let operand = try parseUnary()
            return .unary(.negate, operand, SourceSpan(start: token.span.start, end: operand.span.end))
        }
        return try parsePostfix()
    }

    mutating func parsePostfix() throws -> AST {
        var base = try parsePrimary()
        while true {
            switch peek().kind {
            case .dot:
                _ = advance()
                let nameTok = try expect(.ident, "an identifier after '.'")
                var node = AST.member(base, nameTok.text, SourceSpan(start: base.span.start, end: nameTok.span.end))
                if peek().kind == .lParen {
                    node = try makeCall(node)
                }
                base = node
            case .lBracket:
                _ = advance()
                let idx = try parseTernary()
                let close = try expect(.rBracket, "']'")
                base = .index(base, idx, SourceSpan(start: base.span.start, end: close.span.end))
            case .lParen:
                base = try makeCall(base)
            default:
                return base
            }
        }
    }

    mutating func makeCall(_ callee: AST) throws -> AST {
        _ = advance()  // lParen
        var args: [AST] = []
        if peek().kind != .rParen {
            args.append(try parseTernary())
            while peek().kind == .comma {
                _ = advance()
                args.append(try parseTernary())
            }
        }
        let close = try expect(.rParen, "')'")
        return .call(callee, args, SourceSpan(start: callee.span.start, end: close.span.end))
    }

    mutating func parsePrimary() throws -> AST {
        let token = peek()
        return try parsePrimary(for: token)
    }

    private mutating func parsePrimary(for token: Token) throws -> AST {
        switch token.kind {
        case .int:
            advance()
            return .int(token.intValue!, token.span)
        case .string:
            advance()
            return .string(token.stringValue!, token.span)
        case .keywordTrue:
            advance()
            return .bool(true, token.span)
        case .keywordFalse:
            advance()
            return .bool(false, token.span)
        case .keywordNull:
            advance()
            return .null(token.span)
        case .ident:
            advance()
            return .ident(token.text, token.span)
        default:
            break
        }
        switch token.kind {
        case .lBracket:
            return try parseList()
        case .lParen:
            advance()
            let inner = try parseTernary()
            _ = try expect(.rParen, "')'")
            return inner
        default:
            throw ParseError(message: token.unexpected, position: token.span.start)
        }
    }

    private mutating func parseList() throws -> AST {
        let open = advance()
        var items: [AST] = []
        if peek().kind != .rBracket {
            items.append(try parseTernary())
            while peek().kind == .comma {
                _ = advance()
                items.append(try parseTernary())
            }
        }
        let close = try expect(.rBracket, "']'")
        return .list(items, SourceSpan(start: open.span.start, end: close.span.end))
    }
}
