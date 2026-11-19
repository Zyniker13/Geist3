import CardExpr
import RulesetKit
import Testing

/// Positive and negative checks for every built-in function (§7.3).
/// String literals name enum values (§7.4), so `'N'` unifies with `seat`.
struct BuiltinTests {
    @Test func seatsTeamsDealtHands() throws {
        #expect(try Check.apply("seats()").type == .list(.seat))
        #expect(try Check.apply("teams()").type == .list(.team))
        #expect(try Check.apply("dealtHands()").type == .list(.list(.card)))
        #expect(Check.rejected("seats(1)").contains("seats"))
        #expect(Check.rejected("teams(1)").contains("teams"))
        #expect(Check.rejected("dealtHands(dealer)").contains("dealtHands"))
    }

    @Test func seating() throws {
        #expect(try Check.apply("left(dealer, 1)").type == .seat)
        #expect(try Check.apply("left('N', 1)").type == .seat)
        #expect(try Check.apply("right(dealer, 1)").type == .seat)
        #expect(try Check.apply("partner(s)").type == .seat)
        #expect(try Check.apply("team(s)").type == .team)
        #expect(try Check.apply("opponents(t)").type == .team)
        #expect(try Check.apply("nextActive(s)").type == .seat)
        #expect(Check.rejected("left(dealer)").contains("left"))
        #expect(Check.rejected("left(dealer, true)").contains("left"))
        #expect(Check.rejected("right(1, 1)").contains("right"))
        #expect(Check.rejected("partner(1)").contains("partner"))
        #expect(Check.rejected("team(1)").contains("team"))
        #expect(Check.rejected("opponents(s)").contains("opponents"))
        #expect(Check.rejected("nextActive(t)").contains("nextActive"))
    }

    @Test func zone() throws {
        let zones = Check.zones()
        // Public zones read anywhere; owner/none zones are host-only unless
        // the owner argument is exactly `seat` (§7.5).
        #expect(try Check.apply("zone('hand')", configure: zones).type == .list(.card))
        #expect(try Check.apply("zone('hand', s)", configure: zones).type == .list(.card))
        #expect(try Check.apply("zone('hand', t)", configure: zones).type == .list(.card))
        #expect(try Check.apply("zone('hidden')", configure: zones).type == .list(.card))
        #expect(try Check.apply("zone('hidden', seat)", configure: zones).type == .list(.card))
        #expect(Check.rejected("zone('hidden')", evaluation: .ai, configure: zones).contains("not publicly visible"))
        #expect(
            Check.rejected("zone('pile', dealer)", evaluation: .ai, configure: zones).contains("not publicly visible"))
        #expect(try Check.apply("zone('hidden', seat)", evaluation: .ai, configure: zones).type == .list(.card))
        #expect(Check.rejected("zone('none')", configure: zones).contains("zone"))
        #expect(Check.rejected("zone(1)", configure: zones).contains("zone"))
    }

    @Test func holderOfIsHostOnly() {
        #expect((try? Check.apply("holderOf('AH')").type) == .seat)
        #expect(Check.rejected("holderOf('AH')", evaluation: .ai).contains("host-only"))
        #expect(Check.rejected("holderOf('AH')", evaluation: .ui).contains("host-only"))
        #expect(Check.rejected("holderOf(1)").contains("holderOf"))
    }

    @Test func tricksWonAndPlayedBy() throws {
        #expect(try Check.apply("tricksWon(t)").type == .int)
        #expect(try Check.apply("tricksWon(s)").type == .int)
        #expect(try Check.apply("playedBy(s)").type == .list(.card))
        #expect(Check.rejected("tricksWon('N')").contains("tricksWon"))
        #expect(Check.rejected("playedBy(t)").contains("playedBy"))
    }

    @Test func rankHelpers() throws {
        #expect(try Check.apply("rankIndex('A', c.rank)").type == .int)
        #expect(try Check.apply("rankCode(c.rank)").type == .int)
        #expect(try Check.apply("colorOf(c.suit)").type == .string)
        #expect(Check.rejected("rankIndex(1, c.rank)").contains("rankIndex"))
        #expect(Check.rejected("rankIndex('A', 1)").contains("rankIndex"))
        #expect(Check.rejected("rankCode(s)").contains("rankCode"))
        #expect(Check.rejected("colorOf(c.rank)").contains("colorOf"))
    }

    @Test func topAndChoice() throws {
        #expect(try Check.apply("top(5)").type == .list(.card))
        #expect(try Check.apply("choice('pass', s)").type == .string)
        #expect(Check.rejected("top(c.rank)").contains("top"))
        #expect(Check.rejected("choice(1, s)").contains("choice"))
        #expect(Check.rejected("choice('pass')").contains("choice"))
    }

    // ADR-0024 anchor cases: expressions the reference rulesets need.

    @Test func euchreColorOfOptionalTrump() throws {
        // `deal.trump` is a deal-scoped variable of type `suit?`;
        // colorOf unifies optional-to-value.
        let configure: (inout TypeContext) -> Void = { context in
            context.vars["trump"] = VarBinding(scope: .deal, type: .optional(.suit), initial: "null")
        }
        #expect(try Check.apply("colorOf(deal.trump)", configure: configure).type == .string)
    }

    @Test func bridgeScoreByOpponentsTeam() throws {
        let configure: (inout TypeContext) -> Void = { context in
            context.contextual["dt"] = .team
            context.vars["score"] = VarBinding(scope: .teamMatch, type: .int, initial: "0")
        }
        let typed = try Check.apply("match.score[opponents(dt)]", configure: configure)
        #expect(typed.type == .int)
    }

    @Test func cribbagePoneDef() throws {
        let typed = try Check.def("pone() -> seat", body: "left(dealer, 1)")
        #expect(typed.type == .seat)
    }

    @Test func cribbageHandScoreNative() throws {
        let typed = try Check.apply("cribbage.handScore(cards, c, isCrib)")
        #expect(typed.type == .int)
        #expect(typed.binding == .native("cribbage.handScore"))
        #expect(Check.rejected("cribbage.handScore(cards, c)").contains("cribbage.handScore"))
    }
}
