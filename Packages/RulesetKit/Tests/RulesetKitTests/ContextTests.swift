import CardExpr
import RulesetKit
import Testing

/// Contextual bindings, scoped variables, def checking (parameters,
/// recursion, host-only taint), typed-expression bindings, and DSL type
/// name parsing.
struct ContextTests {
    // MARK: Contextual bindings

    @Test func canonicalContextuals() throws {
        #expect(try Check.apply("dealer").type == .seat)
        #expect(try Check.apply("seat").type == .seat)
        #expect(try Check.apply("c.rank").type == .rank)
        #expect(try Check.apply("s").type == .seat)
        #expect(try Check.apply("t == opponents(t)").type == .bool)
        #expect(try Check.apply("call.strain").type == .suit)
        #expect(try Check.apply("choice(param, s)").type == .string)
        #expect(try Check.apply("isCrib").type == .bool)
        #expect(try Check.apply("tricksWon(awardee)").type == .int)
    }

    @Test func unknownNames() {
        #expect(Check.rejected("nope").contains("nope"))
        #expect(Check.rejected("match").contains("context root"))
        #expect(Check.rejected("deal").contains("context root"))
        #expect(Check.rejected("players").contains("context root"))
        #expect(Check.rejected("trick").contains("context root"))
    }

    // MARK: Scoped variables, options, players, trick

    @Test func matchAndDealVariables() throws {
        let configure: (inout TypeContext) -> Void = { context in
            context.vars["score"] = VarDecl(scope: .match, type: .int, initial: "0")
            context.vars["leadSuit"] = VarDecl(scope: .deal, type: .optional(.suit), initial: "null")
            context.vars["scoreTeam"] = VarDecl(scope: .teamMatch, type: .int, initial: "0")
            context.vars["taken"] = VarDecl(scope: .seatDeal, type: .list(.card), initial: "[]")
        }
        #expect(try Check.apply("match.score", configure: configure).type == .int)
        #expect(try Check.apply("deal.leadSuit == null", configure: configure).type == .bool)
        #expect(try Check.apply("match.scoreTeam[t]", configure: configure).type == .int)
        #expect(try Check.apply("deal.taken[s]", configure: configure).type == .list(.card))
        #expect(Check.rejected("match.leadSuit", configure: configure).contains("match.leadSuit"))
        #expect(Check.rejected("deal.score", configure: configure).contains("deal.score"))
        #expect(Check.rejected("match.nope", configure: configure).contains("nope"))
    }

    @Test func options() throws {
        let configure: (inout TypeContext) -> Void = { context in
            context.options["gameType"] = .string
            context.options["halfSuit"] = .optional(.suit)
        }
        #expect(try Check.apply("options.gameType == 'partner'", configure: configure).type == .bool)
        #expect(try Check.apply("options.halfSuit != null", configure: configure).type == .bool)
        #expect(Check.rejected("options.nope", configure: configure).contains("nope"))
    }

    @Test func playersAndTrick() throws {
        #expect(try Check.apply("players.count").type == .int)
        #expect(try Check.apply("players.count + players.active").type == .int)
        #expect(try Check.apply("trick.number").type == .int)
        #expect(try Check.apply("trick.leader").type == .seat)
        #expect(try Check.apply("trick.cards.size()").type == .int)
        #expect(try Check.apply("trick.ledSuit == null").type == .bool)
        #expect(try Check.apply("trick.winner == null").type == .bool)
        #expect(Check.rejected("players.nope").contains("nope"))
        #expect(Check.rejected("players.count(s)").contains("players.count"))
        #expect(Check.rejected("trick.nope").contains("nope"))
    }

    // MARK: Defs

    @Test func defParamsAndBodies() throws {
        let typed = try Check.def("isLeft(c: card, s: seat) -> bool", body: "s == dealer && c.rank == c.rank")
        #expect(typed.type == .bool)
        // A parameter shadows a canonical contextual binding.
        let shadowed = try Check.def("f(c: int) -> int", body: "c + 1")
        #expect(shadowed.type == .int)
        #expect(try Check.def("f() -> seat", body: "dealer").type == .seat)
        #expect(Check.rejectedDefs("f(x: card) -> bool", body: "x.nope").contains("nope"))
        #expect(Check.rejectedDefs("f(x: card) -> int", body: "x").contains("card"))
    }

    @Test func recursiveDefsAreRejected() throws {
        let leftBody = try Parser().parse("isRight(c)").ast
        let rightBody = try Parser().parse("isLeft(c)").ast
        let isLeft = DefSignature(name: "isLeft", params: ["c"], types: [.card], result: .bool, body: leftBody)
        let isRight = DefSignature(name: "isRight", params: ["c"], types: [.card], result: .bool, body: rightBody)
        var checker = TypeChecker(context: TypeContext(defs: ["isLeft": isLeft, "isRight": isRight]))
        #expect(throws: TypeError.self) {
            try checker.checkDef(isLeft)
        }
        let selfRecursive = DefSignature(
            name: "isLeft", params: ["c"], types: [.card], result: .bool, body: leftBody
        )
        var alone = TypeChecker(context: TypeContext(defs: ["isLeft": selfRecursive]))
        #expect(throws: TypeError.self) {
            try alone.checkDef(selfRecursive)
        }
    }

    @Test func defCallsResolve() throws {
        let helper = try Parser().parse("c.rank == 'A'").ast
        let caller = try Parser().parse("isAce(c) && cards.size() > 2").ast
        let isAce = DefSignature(name: "isAce", params: ["c"], types: [.card], result: .bool, body: helper)
        let main = DefSignature(name: "main", params: [], types: [], result: .bool, body: caller)
        var checker = TypeChecker(context: TypeContext(defs: ["isAce": isAce]))
        let typed = try checker.checkDef(main)
        #expect(typed.type == .bool)
    }

    // MARK: Host-only taint (§7.5)

    @Test func hostOnlyContextsRejectHostOnlyCalls() {
        #expect((try? Check.apply("holderOf('AH')", evaluation: .host)) != nil)
        #expect(Check.rejected("holderOf('AH')", evaluation: .ai).contains("host-only"))
        #expect(Check.rejected("holderOf('AH')", evaluation: .ui).contains("host-only"))
    }

    @Test func defHostOnlyTaint() throws {
        let hostOnly = try Check.def("f() -> seat", body: "holderOf('AH')")
        #expect(hostOnly.type == .seat)
        // A def that calls a host-only def is host-only too.
        let direct = DefSignature(
            name: "direct",
            params: [],
            types: [],
            result: .seat,
            body: try Parser().parse("holderOf('AH')").ast
        )
        let indirect = DefSignature(
            name: "indirect",
            params: [],
            types: [],
            result: .seat,
            body: try Parser().parse("direct()").ast
        )
        var checker = TypeChecker(context: TypeContext(defs: ["direct": direct, "indirect": indirect]))
        #expect(try checker.checkDef(indirect).type == .seat)
        #expect(checker.isHostOnlyDef("indirect"))
        // A def that never calls host-only functions is clean.
        #expect(try Check.def("h() -> int", body: "1 + 1").type == .int)
    }

    @Test func taintedDefCallsAreRejectedOutsideHost() {
        #expect(
            Check.rejectedDefs(
                "f() -> seat",
                body: "holderOf('AH')",
                evaluation: .ai
            ).contains("host-only"))
        #expect(
            Check.rejectedDefs(
                "f() -> list<card>",
                body: "zone('hidden')",
                evaluation: .ui,
                configure: Check.zones()
            ).contains("host-only"))
        #expect(
            (try? Check.def(
                "f() -> int",
                body: "zone('hand', seat).size()",
                evaluation: .ai
            )) != nil)
    }

    // MARK: Typed expression bindings

    @Test func bindings() throws {
        let configure: (inout TypeContext) -> Void = { context in
            context.options["gameType"] = .string
            context.vars["score"] = VarDecl(scope: .match, type: .int, initial: "0")
        }
        #expect(try Check.apply("options.gameType", configure: configure).binding == .option("gameType"))
        #expect(
            try Check.apply("match.score", configure: configure).binding
                == .variable(VarRef(store: .match, scope: .match, name: "score")))
        #expect(try Check.apply("c").binding == .contextual("c"))
        #expect(try Check.apply("dealer").binding == .contextual("dealer"))
        #expect(try Check.apply("left(dealer, 1)").binding == .builtin(.left))
        #expect(try Check.apply("cribbage.handScore(cards, c, isCrib)").binding == .native("cribbage.handScore"))
        #expect(try Check.apply("1 + 2").binding == nil)
    }

    // MARK: Type name parsing

    @Test func typeNameParsing() throws {
        #expect(try RulesetTypeNames.parse("int") == .int)
        #expect(try RulesetTypeNames.parse("suit?") == .optional(.suit))
        #expect(try RulesetTypeNames.parse("list<card>") == .list(.card))
        #expect(try RulesetTypeNames.parse("list<suit?>") == .list(.optional(.suit)))
        #expect(try RulesetTypeNames.parse("contract") == .record(contractRecord))
        #expect(try RulesetTypeNames.parse("any") == .any)
        #expect(throws: TypeError.self) {
            try RulesetTypeNames.parse("nope")
        }
    }

    @Test func defSignatureParsing() throws {
        let header = try RulesetTypeNames.parseDefSignature("pone(c: card) -> bool")
        #expect(header.name == "pone")
        #expect(header.params == ["c"])
        #expect(header.types == [.card])
        #expect(header.result == .bool)
        let zero = try RulesetTypeNames.parseDefSignature("kitty() -> list<card>")
        #expect(zero.params.isEmpty)
        let bridge = try RulesetTypeNames.parseDefSignature(
            "honors(hands: list<list<card>>, trump: suit?) -> int"
        )
        #expect(bridge.types == [.list(.list(.card)), .optional(.suit)])
        #expect(throws: TypeError.self) {
            try RulesetTypeNames.parseDefSignature("f(c: card)")
        }
        #expect(throws: TypeError.self) {
            try RulesetTypeNames.parseDefSignature("f(c: nope) -> bool")
        }
        #expect(throws: TypeError.self) {
            try RulesetTypeNames.parseDefSignature("(c: card) -> bool")
        }
        #expect(throws: TypeError.self) {
            try RulesetTypeNames.parseDefSignature("f(x) -> bool")
        }
    }
}

/// `Check.rejected` for def bodies: parses the signature, then returns the
/// type-error message from checking the body.
extension Check {
    static func rejectedDefs(
        _ signature: String,
        body: String,
        evaluation: TypeContext.EvaluationContext = .host
    ) -> String {
        do {
            _ = try def(signature, body: body, evaluation: evaluation)
        } catch let error as TypeError {
            return error.message
        } catch {
            return "unexpected non-type error: \(error)"
        }
        Issue.record("expected def '\(signature)' to be rejected")
        return ""
    }
}
