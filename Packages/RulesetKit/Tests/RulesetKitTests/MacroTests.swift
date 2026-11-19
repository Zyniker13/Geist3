import CardExpr
import RulesetKit
import Testing

/// Positive and negative checks for every collection macro (§7.1) and for
/// the operator and literal rules of the expression language (§7.4).
/// Macros exist only in method form (`xs.map(v, e)`), strings are single
/// quoted, and the null literal is `null` (§7.4).
/// A configure block adding `hands`, a list of each seat's dealt cards, for
/// macro targets.
private func withHands() -> (inout TypeContext) -> Void {
    { context in
        context.contextual["hands"] = .list(.list(.card))
    }
}

struct MacroTests {
    @Test func lambdaMacros() throws {
        let deal: (inout TypeContext) -> Void = { context in
            context.contextual["deal"] = .record(
                RecordType(
                    name: "deal",
                    fields: ["trump": .optional(.suit)]
                ))
        }
        #expect(try Check.apply("hands.map(h, h.size())", configure: withHands()).type == .list(.int))
        #expect(
            try Check.apply("cards.filter(c, c.suit == deal.trump)", configure: deal).type == .list(.card)
        )
        #expect(try Check.apply("cards.exists(c, c.rank == 'A')").type == .bool)
        #expect(try Check.apply("cards.all(c, c.suit != null)").type == .bool)
        #expect(try Check.apply("cards.count(c, c.suit == 'S')").type == .int)
        #expect(try Check.apply("cards.sortBy(s, rankCode(s.rank))").type == .list(.card))
        #expect(try Check.apply("cards.sortBy(c, c.id)").type == .list(.card))
        #expect(Check.rejected("hands.map(h)", configure: withHands()).contains("map"))
        #expect(Check.rejected("hands.map(1, h.size())", configure: withHands()).contains("map"))
        #expect(Check.rejected("1.map(h, h)", configure: withHands()).contains("map"))
        #expect(Check.rejected("cards.filter(c, c.suit)").contains("filter"))
        #expect(Check.rejected("cards.exists(c, c)").contains("exists"))
        #expect(Check.rejected("cards.all(c, c.suit == 'S' ? 1 : 0)").contains("all"))
        #expect(Check.rejected("cards.count(c, c)").contains("count"))
        #expect(Check.rejected("cards.sortBy(s, s)").contains("sortBy"))
    }

    @Test func nonLambdaMacros() throws {
        #expect(try Check.apply("hands.map(h, h.size()).sum()", configure: withHands()).type == .int)
        #expect(try Check.apply("seats().min()").type == .optional(.seat))
        #expect(try Check.apply("[1, 2, 3].max()").type == .optional(.int))
        #expect(try Check.apply("cards.size()").type == .int)
        #expect(try Check.apply("dealtHands().first()").type == .optional(.list(.card)))
        #expect(try Check.apply("[1, 2, 3].contains(1)").type == .bool)
        #expect(Check.rejected("cards.sum()").contains("sum"))
        #expect(Check.rejected("1.min()").contains("min"))
        #expect(Check.rejected("1.size()").contains("size"))
        #expect(Check.rejected("1.first()").contains("first"))
        #expect(Check.rejected("[1, 2, 3].contains(true)").contains("contains"))
    }

    @Test func cribbageFifteenSequence() throws {
        // ['J','Q','K'] writes a rank list; its elements unify with ranks.
        let typed = try Check.apply("['J', 'Q', 'K'].exists(r, r == c.rank)")
        #expect(typed.type == .bool)
        #expect(try Check.apply("cards.count(c, c.suit == null)").type == .int)
    }

    @Test func operators() throws {
        // Arithmetic takes int operands (§7.2); precedence is the parser's job.
        #expect(try Check.apply("1 + 2 * 3").type == .int)
        #expect(try Check.apply("cards.size() - 1").type == .int)
        #expect(try Check.apply("cards.size() / 2").type == .int)
        #expect(try Check.apply("cards.size() % 2").type == .int)
        #expect(try Check.apply("-cards.size() + trick.number").type == .int)
        #expect(Check.rejected("true + 1").contains("+"))
        #expect(Check.rejected("'A' * 2").contains("*"))
        #expect(Check.rejected("cards / 2").contains("/"))
        #expect(Check.rejected("1 % c").contains("%"))
        // `null` unifies with every type (§7.2), so it type-checks anywhere;
        // a null misuse at run time is an engine fault (§7.4), not a
        // compile-time error.
        #expect(try Check.apply("1 * null").type == .int)
    }

    @Test func comparisonsAndBoolean() throws {
        #expect(try Check.apply("cards.size() > 0").type == .bool)
        #expect(try Check.apply("cards.size() >= 0 && trick.number != 1").type == .bool)
        #expect(try Check.apply("!(isCrib || false)").type == .bool)
        #expect(try Check.apply("s == 'N'").type == .bool)
        #expect(try Check.apply("s == null").type == .bool)
        #expect(try Check.apply("c.suit != null").type == .bool)
        #expect(Check.rejected("s < 3").contains("<"))
        #expect(Check.rejected("1 == true").contains("=="))
        #expect(Check.rejected("t == s").contains("=="))
        #expect(Check.rejected("isCrib && 1").contains("&&"))
        #expect(try Check.apply("isCrib || null").type == .bool)
        #expect(Check.rejected("!c.rank").contains("!"))
    }

    @Test func membershipAndUnary() throws {
        #expect(try Check.apply("c in cards").type == .bool)
        #expect(try Check.apply("c in hands", configure: withHands()).type == .bool)
        #expect(Check.rejected("'A' in cards").contains("in"))
        #expect(Check.rejected("1 in cards").contains("in"))
        #expect(try Check.apply("-cards.size()").type == .int)
        #expect(try Check.apply("isCrib ? 1 : 0").type == .int)
        #expect(try Check.apply("isCrib ? c : top(1).first()").type == .optional(.card))
        #expect(Check.rejected("isCrib ? 1 : 'A'").contains("branches"))
        #expect(Check.rejected("1 ? 2 : 3").contains("condition"))
    }

    @Test func lists() throws {
        #expect(try Check.apply("[]").type == .list(.any))
        #expect(try Check.apply("[1, 2, 3]").type == .list(.int))
        #expect(Check.rejected("[1, 'A']").contains("list"))
    }

    @Test func recordMembersAndLiterals() throws {
        let bridge: (inout TypeContext) -> Void = { context in
            context.contextual["contract"] = .record(contractRecord)
        }
        #expect(try Check.apply("call.bid").type == .int)
        #expect(try Check.apply("call.doubled").type == .bool)
        let typed = try Check.apply(
            "bridge.score(contract, 1, contract.doubled, 'NT').total",
            configure: bridge
        )
        #expect(typed.type == .int)
        #expect(Check.rejected("call.nope").contains("nope"))
        #expect(Check.rejected("c.nope").contains("nope"))
        #expect(Check.rejected("bridge.score(call, 1, call.doubled, 'NT')", configure: bridge).contains("bridge.score"))
    }
}
