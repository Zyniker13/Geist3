import CardExpr
import RulesetKit
import Testing

/// Deterministic evaluation tests (P2.3): repeated-evaluation agreement,
/// integer-arithmetic sweeps, constant folding with the compiled
/// expression cache, and the release-mode performance budget
/// (ARCHITECTURE.md §7.4, §7.6, §5.8).

struct EvaluatorDeterminismTests {
    /// The leadAllowed-shaped expression evaluated under several
    /// environments; every run must produce the same result for the
    /// same environment, across evaluator instances.
    private static let combo =
        "left(seat, 1) == 'N' && cards.size() == 2 && trick.number == 1 && rankCode(c.rank) == 2"

    @Test func repeatedEvaluationsAgree() throws {
        for _ in 0..<25 {
            let value = try Eval.run(EvaluatorDeterminismTests.combo, env: Eval.bridge)
            #expect(value == .bool(true))
        }
    }

    @Test func pureArithmeticSweepMatchesIntegerMath() throws {
        for i in 0..<32 {
            let x = Int64(i) - 16
            let expected = Value.int(x * x + 2 * x)
            #expect(try Eval.run("(\(i) - 16) * (\(i) - 16) + 2 * (\(i) - 16)") == expected)
        }
    }

    @Test func defChainSweepIsDeterministic() throws {
        var context = TypeContext(evaluation: .host)
        context.defs["wobble"] = .init(
            name: "wobble", params: ["n"], types: [.int], result: .int,
            body: try Parser().parse("(n - 16) * (n - 16) + 2 * (n - 16)").ast)
        var checker = TypeChecker(context: context)
        var evaluator = Evaluator(context: context)
        for i in 0..<20 {
            let n = i * 50
            let expected = Int64((n - 16) * (n - 16) + 2 * (n - 16))
            let typed = try checker.check(try Parser().parse("wobble(\(n))").ast)
            #expect(
                try evaluator.evaluate(typed, in: EvaluationEnvironment(), pointer: "/t")
                    == .int(expected))
        }
    }
}

struct EvaluatorFoldingTests {
    private func folded(
        _ source: String,
        configure: (inout TypeContext) -> Void = { _ in }
    ) throws -> TypedExpr {
        let typed = try Check.apply(source, configure: configure)
        return ConstantFolder().fold(typed)
    }

    @Test func constantsFold() throws {
        #expect(try folded("1 + 2 * 3").constant == .int(7))
        #expect(try folded("true ? 5 : 9").constant == .int(5))
        #expect(try folded("!(2 < 3)").constant == .bool(false))
        #expect(try folded("[1, 2, 3]").constant == .list([.int(1), .int(2), .int(3)]))
    }

    @Test func shortCircuitPrunesFaultingBranches() throws {
        #expect(try folded("false && 1 / 0 == 0").constant == .bool(false))
        #expect(try folded("true || 1 / 0 == 0").constant == .bool(true))
    }

    @Test func impureSubtreesStayUnfolded() throws {
        let conf: (inout TypeContext) -> Void = {
            $0.contextual["x"] = .int
            $0.contextual["cards"] = .list(.card)
        }
        #expect(try folded("x + 1", configure: conf).constant == nil)
        #expect(try folded("cards.size()", configure: conf).constant == nil)
    }

    @Test func faultingConstantsStayUnfolded() throws {
        #expect(try folded("1 / 0").constant == nil)
        let typed = try Check.apply("1 / 0")
        var evaluator = Evaluator(context: TypeContext(evaluation: .host))
        #expect(throws: EvaluationFault.self) {
            _ = try evaluator.evaluate(typed, in: EvaluationEnvironment(), pointer: "/t")
        }
    }

    @Test func foldedConstantsEvaluateWithoutEnvironment() throws {
        let typed = try folded("1 + 2 * 3")
        var evaluator = Evaluator(context: TypeContext(evaluation: .host))
        #expect(
            try evaluator.evaluate(typed, in: EvaluationEnvironment(), pointer: "/t")
                == .int(7))
    }

    @Test func cacheRoundTrip() throws {
        var cache = CompiledExpressionCache(capacity: 2)
        let key = CompiledExpressionCache.Key(rulesetHash: "h", pointer: "/a")
        #expect(cache.get(key) == nil)
        let typed = try Check.apply("1 + 2")
        cache.insert(key, typed)
        #expect(cache.get(key) != nil)
        #expect(cache.count == 1)
    }
}

#if !DEBUG
    struct EvaluatorPerfTests {
        /// The `leadAllowed`-sized expression must evaluate in a median of
        /// 1 µs or less (release builds; §7.4 performance budget).
        @Test func leadAllowedMedianUnderMicrosecond() throws {
            let source =
                "trick.number == 1 ? c.id == '2C' : (!options.breakingHearts || deal.heartsBroken || c.suit != 'H')"
            var context = TypeContext(evaluation: .host)
            context.options["breakingHearts"] = .bool
            context.contextual["deal"] = .record(RecordType(name: "deal", fields: ["heartsBroken": .bool]))
            var checker = TypeChecker(context: context)
            let typed = try checker.check(try Parser().parse(source).ast)

            var env = EvaluationEnvironment()
            Eval.bridge(&env)
            env.optionValues["breakingHearts"] = .bool(false)
            env.contextual["deal"] = .record(name: "deal", fields: ["heartsBroken": .bool(false)])

            var evaluator = Evaluator(context: context)
            let clock = ContinuousClock()
            var samples: [Int64] = []
            samples.reserveCapacity(4000)
            for i in 0..<4000 {
                // Alternate through the three branches so no path is
                // measured exclusively.
                switch i % 3 {
                case 0:
                    env.trick.number = .int(1)
                case 1:
                    env.trick.number = .int(2)
                    env.contextual["c"] = .card(id: "5C", suit: "C", rank: "5")
                default:
                    env.trick.number = .int(2)
                    env.contextual["c"] = .card(id: "5H", suit: "H", rank: "5")
                    env.optionValues["breakingHearts"] = .bool(true)
                }
                let start = clock.now
                _ = try evaluator.evaluate(
                    typed, in: env, fuel: EvaluationFault.expressionBudget, pointer: "/perf")
                let elapsed = clock.now - start
                samples.append(elapsed.components.seconds * 1_000_000_000_000 + elapsed.components.attoseconds)
            }
            samples.sort()
            let median = samples[samples.count / 2]
            print("perf: leadAllowed median \(median / 1_000_000_000) ns")
            #expect(median < 1_000_000_000_000, "median evaluation took \(median / 1_000_000_000_000) µs")
        }
    }
#endif
