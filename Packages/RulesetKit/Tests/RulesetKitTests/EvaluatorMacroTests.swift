import CardExpr
import RulesetKit
import Testing

/// Macro and def evaluation tests (P2.3): lambda and aggregate macros,
/// and def calls with parameters, state access and chaining
/// (ARCHITECTURE.md §7.4, §7.2).

struct EvaluatorMacroTests {
    @Test func lambdaMacros() throws {
        let conf: (inout TypeContext) -> Void = { $0.contextual["xs"] = .list(.int) }
        let env: (inout EvaluationEnvironment) -> Void = {
            $0.contextual["xs"] = .list([.int(1), .int(2), .int(3)])
        }
        #expect(
            try Eval.run("xs.map(x, x + 1)", configure: conf, env: env)
                == .list([.int(2), .int(3), .int(4)]))
        #expect(
            try Eval.run("xs.filter(x, x > 1)", configure: conf, env: env)
                == .list([.int(2), .int(3)]))
        #expect(try Eval.run("xs.exists(x, x == 2)", configure: conf, env: env) == .bool(true))
        #expect(try Eval.run("xs.all(x, x > 0)", configure: conf, env: env) == .bool(true))
        #expect(try Eval.run("xs.count(x, x > 1)", configure: conf, env: env) == .int(2))
        #expect(
            try Eval.run("xs.sortBy(x, -x)", configure: conf, env: env)
                == .list([.int(3), .int(2), .int(1)]))
    }

    @Test func aggregateMacros() throws {
        let conf: (inout TypeContext) -> Void = { $0.contextual["xs"] = .list(.int) }
        let env: (inout EvaluationEnvironment) -> Void = {
            $0.contextual["xs"] = .list([.int(3), .int(1), .int(2)])
        }
        #expect(try Eval.run("xs.sum()", configure: conf, env: env) == .int(6))
        #expect(try Eval.run("xs.min()", configure: conf, env: env) == .int(1))
        #expect(try Eval.run("xs.max()", configure: conf, env: env) == .int(3))
        #expect(try Eval.run("xs.size()", configure: conf, env: env) == .int(3))
        let empty: (inout EvaluationEnvironment) -> Void = {
            $0.contextual["xs"] = .list([])
        }
        #expect(try Eval.run("xs.sum()", configure: conf, env: empty) == .int(0))
        #expect(try Eval.run("xs.first()", configure: conf, env: empty) == .null)
    }

    @Test func sumOverflowFaults() throws {
        let conf: (inout TypeContext) -> Void = { $0.contextual["xs"] = .list(.int) }
        let env: (inout EvaluationEnvironment) -> Void = {
            $0.contextual["xs"] = .list([.int(Int64.max), .int(1)])
        }
        #expect(Eval.fault("xs.sum()", configure: conf, env: env) == .integerOverflow)
    }

    @Test func macrosComposeAndNest() throws {
        #expect(try Eval.run("cards.filter(c, c.suit == 'H').size()", env: Eval.bridge) == .int(1))
        #expect(try Eval.run("cards.exists(c, c.rank == 'A')", env: Eval.bridge) == .bool(true))
        let conf: (inout TypeContext) -> Void = { $0.contextual["hands"] = .list(.list(.int)) }
        let env: (inout EvaluationEnvironment) -> Void = {
            $0.contextual["hands"] = .list([.list([.int(1), .int(2)]), .list([.int(3)])])
        }
        #expect(try Eval.run("hands.map(h, h.size()).sum()", configure: conf, env: env) == .int(3))
        #expect(try Eval.run("hands.contains([1, 2])", configure: conf, env: env) == .bool(true))
        #expect(try Eval.run("hands.contains([9])", configure: conf, env: env) == .bool(false))
    }
}

struct EvaluatorDefTests {
    @Test func defCallsBindParams() throws {
        var context = TypeContext(evaluation: .host)
        context.defs["square"] = .init(
            name: "square", params: ["n"], types: [.int], result: .int,
            body: try Parser().parse("n * n").ast)
        var checker = TypeChecker(context: context)
        let checked = try checker.check(try Parser().parse("square(3)").ast)
        var evaluator = Evaluator(context: context)
        #expect(
            try evaluator.evaluate(checked, in: EvaluationEnvironment(), pointer: "/t")
                == .int(9))
    }

    @Test func defsWithStateAndChains() throws {
        var context = TypeContext(evaluation: .host)
        context.vars["scores"] = VarDecl(scope: .seatDeal, type: .int, initial: "0")
        context.defs["leadScore"] = .init(
            name: "leadScore", params: ["s"], types: [.seat], result: .int,
            body: try Parser().parse("deal.scores[s]").ast)
        context.defs["leadEdge"] = .init(
            name: "leadEdge", params: ["s"], types: [.seat], result: .int,
            body: try Parser().parse("leadScore(s) * 2").ast)

        var env = EvaluationEnvironment()
        env.seats = [.string("N"), .string("E"), .string("S"), .string("W")]
        env.indexedVars[VarRef(store: .deal, scope: .seatDeal, name: "scores")] =
            [.int(1), .int(2), .int(3), .int(4)]
        var checker = TypeChecker(context: context)
        var evaluator = Evaluator(context: context)
        #expect(
            try evaluator.evaluate(
                try checker.check(try Parser().parse("leadScore('W')").ast), in: env, pointer: "/t")
                == .int(4))
        #expect(
            try evaluator.evaluate(
                try checker.check(try Parser().parse("leadEdge('W')").ast), in: env, pointer: "/t")
                == .int(8))
    }
}
