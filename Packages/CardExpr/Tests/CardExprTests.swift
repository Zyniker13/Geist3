import CardExpr
import Foundation
import Testing

// MARK: - Helpers

private func tokens(_ source: String) throws -> [String] {
    try Lexer(source: source).tokenize().map(\.describe)
}

private func canonical(_ source: String) throws -> String {
    try Parser().parse(source).ast.canonical
}

private func expectParseError(_ source: String, containing message: String) {
    do {
        _ = try Parser().parse(source)
        Issue.record("expected parse error for '\(source)' but it parsed")
    } catch {
        #expect("\(error)".contains(message), "for '\(source)': got '\(error)'")
    }
}

private func expectLexerError(_ source: String, containing message: String) {
    do {
        _ = try Lexer(source: source).tokenize()
        Issue.record("expected lexer error for '\(source)' but it lexed")
    } catch {
        #expect("\(error)".contains(message), "for '\(source)': got '\(error)'")
    }
}

// MARK: - Token streams

private let tokenCases: [(String, [String])] = [
    ("123", ["int(123)", "eof"]),
    ("a", ["id(a)", "eof"]),
    ("a.b", ["id(a)", "op(.)", "id(b)", "eof"]),
    ("true", ["kw(true)", "eof"]),
    ("false", ["kw(false)", "eof"]),
    ("null", ["kw(null)", "eof"]),
    ("in", ["kw(in)", "eof"]),
    ("a_b1", ["id(a_b1)", "eof"]),
    ("1+2", ["int(1)", "op(+)", "int(2)", "eof"]),
    ("1-2", ["int(1)", "op(-)", "int(2)", "eof"]),
    ("1*2", ["int(1)", "op(*)", "int(2)", "eof"]),
    ("1/2", ["int(1)", "op(/)", "int(2)", "eof"]),
    ("1%2", ["int(1)", "op(%)", "int(2)", "eof"]),
    ("!a", ["op(!)", "id(a)", "eof"]),
    ("a&&b", ["id(a)", "op(&&)", "id(b)", "eof"]),
    ("a||b", ["id(a)", "op(||)", "id(b)", "eof"]),
    ("a==b", ["id(a)", "op(==)", "id(b)", "eof"]),
    ("a!=b", ["id(a)", "op(!=)", "id(b)", "eof"]),
    ("a<b", ["id(a)", "op(<)", "id(b)", "eof"]),
    ("a<=b", ["id(a)", "op(<=)", "id(b)", "eof"]),
    ("a>b", ["id(a)", "op(>)", "id(b)", "eof"]),
    ("a>=b", ["id(a)", "op(>=)", "id(b)", "eof"]),
    ("a in b", ["id(a)", "kw(in)", "id(b)", "eof"]),
    ("(a)", ["op(()", "id(a)", "op())", "eof"]),
    ("[a]", ["op([)", "id(a)", "op(])", "eof"]),
    ("a,b", ["id(a)", "op(,)", "id(b)", "eof"]),
    ("a?b:c", ["id(a)", "op(?)", "id(b)", "op(:)", "id(c)", "eof"]),
    ("a.b(c)", ["id(a)", "op(.)", "id(b)", "op(()", "id(c)", "op())", "eof"]),
    ("a[1]", ["id(a)", "op([)", "int(1)", "op(])", "eof"]),
    ("'hi'", ["str('hi')", "eof"]),
    ("''", ["str('')", "eof"]),
    ("a.b(c,d)", ["id(a)", "op(.)", "id(b)", "op(()", "id(c)", "op(,)", "id(d)", "op())", "eof"]),
    ("a(1,2)", ["id(a)", "op(()", "int(1)", "op(,)", "int(2)", "op())", "eof"]),
    ("a()", ["id(a)", "op(()", "op())", "eof"]),
]

// MARK: - Parse shapes (source → canonical form)

private let shapeCases: [(String, String)] = [
    // Literals and identifiers.
    ("1", "1"), ("42", "42"), ("'hi'", "'hi'"), ("''", "''"),
    ("true", "true"), ("false", "false"), ("null", "null"),
    ("a", "a"), ("a_b", "a_b"), ("a1", "a1"), ("z9_", "z9_"),
    // Arithmetic.
    ("1*2+3", "1 * 2 + 3"), ("1-2*3", "1 - 2 * 3"),
    ("1+2-3", "1 + 2 - 3"), ("1-(2-3)", "1 - (2 - 3)"),
    ("1*2/3", "1 * 2 / 3"), ("1/2*3", "1 / 2 * 3"),
    ("1/2/3", "1 / 2 / 3"), ("1/(2/3)", "1 / (2 / 3)"),
    ("1+2*3-4/5", "1 + 2 * 3 - 4 / 5"),
    ("(1+2)*3", "(1 + 2) * 3"), ("1+(2*3)", "1 + 2 * 3"),
    ("((1))", "1"),
    // Comparisons.
    ("1<2", "1 < 2"), ("1<=2", "1 <= 2"), ("1>2", "1 > 2"),
    ("1>=2", "1 >= 2"), ("1<2+3", "1 < 2 + 3"), ("1+2<3", "1 + 2 < 3"),
    ("1<2<3", "1 < 2 < 3"), ("1<2<=3", "1 < 2 <= 3"),
    ("1==2", "1 == 2"), ("1!=2", "1 != 2"),
    ("1==2+3", "1 == 2 + 3"), ("1+2==3", "1 + 2 == 3"),
    ("1==2==3", "1 == 2 == 3"), ("1==2!=3", "1 == 2 != 3"),
    ("1<2==3", "1 < 2 == 3"), ("1==2<3", "1 == 2 < 3"),
    // Boolean.
    ("a&&b", "a && b"), ("a&&b||c", "a && b || c"),
    ("a||b&&c", "a || b && c"), ("a&&b&&c", "a && b && c"),
    ("a||b||c", "a || b || c"), ("a&&b||c&&d", "a && b || c && d"),
    ("!a", "!a"), ("!a&&b", "!a && b"), ("!a||b", "!a || b"),
    ("!!a", "!!a"), ("!-a", "!-a"), ("-!a", "-!a"),
    ("!a.b", "!a.b"), ("!a[0]", "!a[0]"), ("!a(1)", "!a(1)"),
    ("!(a+b)", "!(a + b)"), ("-(a+b)", "-(a + b)"),
    ("-a", "-a"), ("-a+b", "-a + b"), ("a+-b", "a + -b"),
    ("a--b", "a - -b"), ("a*-b", "a * -b"), ("a/-b", "a / -b"),
    ("a%-b", "a % -b"), ("-a*b", "-a * b"),
    // `in`.
    ("x in xs", "x in xs"), ("x in xs in ys", "x in xs in ys"),
    ("x in a+b", "x in a + b"), ("a+b in x", "a + b in x"),
    // Ternary.
    ("a?b:c", "a ? b : c"), ("a?b:c?d:e", "a ? b : c ? d : e"),
    ("a?b?c:d:e", "a ? b ? c : d : e"),
    ("(a?b:c)?d:e", "(a ? b : c) ? d : e"),
    ("a?b:c?d:e?f:g", "a ? b : c ? d : e ? f : g"),
    ("a&&b?c:d", "a && b ? c : d"), ("a?b&&c:d", "a ? b && c : d"),
    ("a?b:c&&d", "a ? b : c && d"),
    ("a?b?c&&d:e:f", "a ? b ? c && d : e : f"),
    // Lists.
    ("[]", "[]"), ("[1]", "[1]"), ("[1,2]", "[1, 2]"),
    ("[1,2,3]", "[1, 2, 3]"), ("[[1],[2,3]]", "[[1], [2, 3]]"),
    ("[a,b,c]", "[a, b, c]"), ("['x',1,true]", "['x', 1, true]"),
    ("[a?b:c]", "[a ? b : c]"),
    // Member / index / call.
    ("a.b", "a.b"), ("a[0]", "a[0]"), ("a[0][1]", "a[0][1]"),
    ("a[0].b", "a[0].b"), ("a.b[0]", "a.b[0]"),
    ("a(1)", "a(1)"), ("a()", "a()"), ("a(1,2)", "a(1, 2)"),
    ("a.b(1)", "a.b(1)"), ("a.b(1).c", "a.b(1).c"),
    ("a.b(1).c(2)", "a.b(1).c(2)"), ("a.b(1)[2]", "a.b(1)[2]"),
    ("a[1](2)", "a[1](2)"), ("a[1](2).b", "a[1](2).b"),
]

// MARK: - Parse errors (source → expected message fragment)

private let parseErrorCases: [(String, String)] = [
    ("", "unexpected end of input"),
    ("   ", "unexpected end of input"),
    ("\n", "unexpected end of input"),
    ("in", "unexpected token 'in'"),
    ("true false", "unexpected token 'false'"),
    ("1 2", "unexpected token '2'"),
    ("a b", "unexpected token 'b'"),
    ("1 +", "unexpected end of input"),
    ("(1", "expected ')' but found eof"),
    ("[1", "expected ']' but found eof"),
    ("a.", "expected an identifier after '.' but found eof"),
    ("[1,]", "unexpected token ']'"),
    ("a ? b", "expected ':' but found eof"),
    ("a ? b :", "unexpected end of input"),
    ("a in", "unexpected end of input"),
    ("a in b c", "unexpected token 'c'"),
    ("a..b", "expected an identifier after '.' but found op(.)"),
    ("a(1,)", "unexpected token ')'"),
    ("a[1", "expected ']' but found eof"),
    ("a.b(c", "expected ')' but found eof"),
    ("a?b:c?", "unexpected end of input"),
    ("a||", "unexpected end of input"),
    ("a&&", "unexpected end of input"),
    ("a==", "unexpected end of input"),
    ("a!=", "unexpected end of input"),
    ("a<", "unexpected end of input"),
    ("a*", "unexpected end of input"),
    ("a/", "unexpected end of input"),
    ("a%", "unexpected end of input"),
    ("a-", "unexpected end of input"),
    ("a+", "unexpected end of input"),
    ("!", "unexpected end of input"),
    ("-", "unexpected end of input"),
    ("a.b.", "expected an identifier after '.' but found eof"),
    ("a in b in", "unexpected end of input"),
    ("a ? b : c ?", "unexpected end of input"),
]

// MARK: - Lexer errors (source → expected message fragment)

private let lexerErrorCases: [(String, String)] = [
    ("$", "unexpected character '$'"),
    ("a$", "unexpected character '$'"),
    ("a\n$", "unexpected character '$'"),
    ("'ab", "unterminated string literal"),
    ("'ab\ncd'", "unterminated string literal"),
    ("99999999999999999999", "integer literal out of range"),
    ("a|b", "unexpected character '|'"),
    ("a&b", "unexpected character '&'"),
    ("a=b", "unexpected character '='"),
    ("a#b", "unexpected character '#'"),
    ("a@b", "unexpected character '@'"),
    ("a;b", "unexpected character ';'"),
    ("a\"b", "unexpected character '\"'"),
    ("a~b", "unexpected character '~'"),
    ("a^b", "unexpected character '^'"),
    ("a{b}", "unexpected character '{'"),
    ("a}b", "unexpected character '}'"),
    ("a\\b", "unexpected character '\\'"),
    ("a`b", "unexpected character '`'"),
]

// MARK: - Spans

private struct SpanCase: Sendable {
    let source: String
    let startLine: Int, startCol: Int
    let endLine: Int, endCol: Int

    init(_ source: String, _ startLine: Int, _ startCol: Int,
         _ endLine: Int, _ endCol: Int) {
        self.source = source; self.startLine = startLine
        self.startCol = startCol; self.endLine = endLine; self.endCol = endCol
    }
}

private let spanCases: [SpanCase] = [
    // (source, startLine, startCol, endLine, endCol) of the top-level AST.
    SpanCase("1 + 2", 1, 1, 1, 5),
    SpanCase("a\n+ b", 1, 1, 2, 3),
    SpanCase("a\n\n\n+ b", 1, 1, 4, 3),
    SpanCase("  1", 1, 3, 1, 3),
    SpanCase("'ab'", 1, 1, 1, 4),
    SpanCase("a.b", 1, 1, 1, 3),
    SpanCase("a[1]", 1, 1, 1, 4),
    SpanCase("a(1)", 1, 1, 1, 4),
    SpanCase("a?b:c", 1, 1, 1, 5),
    SpanCase("!a", 1, 1, 1, 2),
    SpanCase("-(a+b)", 1, 1, 1, 5),
    SpanCase("[1, 2]", 1, 1, 1, 6),
]

private let parseErrorPositions: [(String, Int, Int)] = [
    // (source, line, column) of the reported error position.
    ("1 +", 1, 4), ("(1", 1, 3), ("a.", 1, 3), ("[1,]", 1, 4),
    ("a\nb", 2, 1), ("a in\n", 2, 1),
]

private let lexerErrorPositions: [(String, Int, Int)] = [
    ("a$", 1, 2), ("a\n$", 2, 1), ("'ab", 1, 1),
    ("99999999999999999999", 1, 1), ("  $", 1, 3),
]

// MARK: - Node counts

private let nodeCountCases: [(String, Int)] = [
    ("1", 1), ("'x'", 1), ("true", 1), ("null", 1), ("a", 1),
    ("1+2", 3), ("1+2*3", 5), ("a.b", 2), ("a.b.c", 3),
    ("a(1,2)", 4), ("a()", 2), ("[1,2,3]", 4), ("[]", 1),
    ("a?b:c", 4), ("!a", 2), ("((1))", 1), ("a[1]", 3),
    ("a.b(c.d(e.f))", 8),
]

// MARK: - Suites

@Suite("CardExpr")
struct CardExprTests {
    @Test(arguments: tokenCases)
    func tokenStream(src: String, expected: [String]) throws {
        let actual = try tokens(src)
        if actual != expected {
            Issue.record("for '\(src)': got \(actual), expected \(expected)")
        }
        #expect(actual == expected, "for '\(src)'")
    }

    @Test(arguments: shapeCases)
    func parseShape(src: String, expected: String) throws {
        #expect(try canonical(src) == expected, "for '\(src)'")
    }

    @Test(arguments: parseErrorCases)
    func parseError(src: String, message: String) {
        expectParseError(src, containing: message)
    }

    @Test(arguments: lexerErrorCases)
    func lexerError(src: String, message: String) {
        expectLexerError(src, containing: message)
    }

    @Test(arguments: spanCases)
    fileprivate func topLevelSpan(_ c: SpanCase) throws {
        let ast = try Parser().parse(c.source).ast
        #expect(ast.span.start == SourcePosition(line: c.startLine, column: c.startCol), "for '\(c.source)'")
        #expect(ast.span.end == SourcePosition(line: c.endLine, column: c.endCol), "for '\(c.source)'")
    }

    @Test(arguments: parseErrorPositions)
    func parseErrorPosition(src: String, line: Int, col: Int) {
        do {
            _ = try Parser().parse(src)
            Issue.record("expected parse error for '\(src)'")
        } catch {
            #expect("\(error)".contains("\(line):\(col)"), "for '\(src)': got '\(error)'")
        }
    }

    @Test(arguments: lexerErrorPositions)
    func lexerErrorPosition(src: String, line: Int, col: Int) {
        do {
            _ = try Lexer(source: src).tokenize()
            Issue.record("expected lexer error for '\(src)'")
        } catch {
            #expect("\(error)".contains("\(line):\(col)"), "for '\(src)': got '\(error)'")
        }
    }

    @Test(arguments: nodeCountCases)
    func nodeCount(src: String, expected: Int) throws {
        let parsed = try Parser().parse(src)
        #expect(parsed.nodeCount == expected, "for '\(src)'")
        #expect(parsed.ast.nodeCount == expected, "for '\(src)'")
    }

    @Test func tokenSpans() throws {
        let toks = try Lexer(source: "a\n  b").tokenize()
        #expect(toks[0].span == SourceSpan(start: .init(line: 1, column: 1), end: .init(line: 1, column: 1)))
        #expect(toks[1].span == SourceSpan(start: .init(line: 2, column: 3), end: .init(line: 2, column: 3)))
        #expect(toks[2].span.start == SourcePosition(line: 2, column: 4))
        let single = try Lexer(source: "a").tokenize()
        #expect(single[1].span == SourceSpan(start: .init(line: 1, column: 2), end: .init(line: 1, column: 2)))
        let twoChar = try Lexer(source: "a&&b").tokenize()
        #expect(twoChar[1].span == SourceSpan(start: .init(line: 1, column: 2), end: .init(line: 1, column: 3)))
    }

    @Test func tokenAccessors() throws {
        let toks = try Lexer(source: "42 'x' a").tokenize()
        #expect(toks[0].intValue == 42)
        #expect(toks[1].intValue == nil)
        #expect(toks[1].stringValue == "x")
        #expect(toks[0].stringValue == nil)
        #expect(toks[2].intValue == nil)
        #expect(toks[2].stringValue == nil)
    }

    @Test func roundTrip() throws {
        for (src, _) in shapeCases {
            let once = try canonical(src)
            let twice = try canonical(once)
            #expect(once == twice, "round-trip failed for '\(src)': '\(once)' -> '\(twice)'")
        }
    }

    /// 10,000 random strings from the CardExpr alphabet: parsing must
    /// either succeed or throw — never trap (ROADMAP P2.1).
    @Test func fuzzNeverTraps() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        let alphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz_.+-*/%!=<>|&()[]?,:' intruefalsenull")
        for _ in 0..<10_000 {
            let len = Int(next() % 24)
            var s = ""
            for _ in 0..<len {
                s.append(alphabet[Int(next() % UInt64(alphabet.count))])
            }
            do {
                _ = try Parser().parse(s)
            } catch {
                // Expected: malformed input must throw, never trap.
            }
        }
    }

    /// Parse time must scale linearly with input size: 4× the input takes
    /// roughly 4× the time (ROADMAP P2.1: parse time linear).
    @Test func parseTimeIsLinear() throws {
        func chain(_ n: Int) -> String {
            var s = ""
            s.reserveCapacity(n * 4)
            for i in 0..<n {
                if i > 0 { s += " + " }
                s += "a"
            }
            return s
        }
        func attos(_ d: Duration) -> Int64 {
            d.components.seconds * 1_000_000_000_000_000_000 + d.components.attoseconds
        }
        _ = try Parser().parse(chain(2_000)) // warm-up
        let start1 = ContinuousClock.now
        _ = try Parser().parse(chain(2_000))
        let t1 = ContinuousClock.now - start1
        let start2 = ContinuousClock.now
        _ = try Parser().parse(chain(8_000))
        let t2 = ContinuousClock.now - start2
        // swiftlint:disable banned-double
        let ratio = Double(attos(t2)) / Double(attos(t1))
        // swiftlint:enable banned-double
        #expect(ratio > 1.5 && ratio < 10, "parse time ratio for 4x input was \(ratio)")
    }
}
