import CardExpr
import RulesetKit
import Testing

/// Evaluation tests (P2.3): operator semantics, fault kinds, builtins,
/// scoped variable and option bindings, and fuel (ARCHITECTURE.md
/// §7.4, §7.6, §5.8).
enum Eval {
    /// A four-seat, two-team environment in play order N, E, S, W, with
    /// the canonical trick snapshot and a two-card `cards` context.
    static func bridge(_ env: inout EvaluationEnvironment) {
        env.seats = [.string("N"), .string("E"), .string("S"), .string("W")]
        env.teams = [.string("NS"), .string("EW")]
        env.teamOfSeat = ["N": "NS", "S": "NS", "E": "EW", "W": "EW"]
        env.activeSeats = ["N", "E", "S", "W"]
        env.playersCount = 4
        env.dealIndex = 2
        env.trick = EvaluationEnvironment.TrickSnapshot(
            number: .int(1), leader: .string("N"),
            cards: .list([.card(id: "2C", suit: "C", rank: "2")]),
            ledSuit: .null, winner: .null
        )
        env.contextual["c"] = .card(id: "2C", suit: "C", rank: "2")
        env.contextual["s"] = .string("H")
        env.contextual["seat"] = .string("W")
        env.contextual["dealer"] = .string("S")
        env.contextual["cards"] = .list([
            .card(id: "2C", suit: "C", rank: "2"),
            .card(id: "AH", suit: "H", rank: "A"),
        ])
    }

    /// The declared rule variable `scores`, per seat for this deal.
    static let scoresRef = VarRef(store: .deal, scope: .seatDeal, name: "scores")
    /// The declared rule variable `points`, per team for the match.
    static let pointsRef = VarRef(store: .match, scope: .teamMatch, name: "points")
    /// The declared rule variable `roundsPlayed` for the match.
    static let roundsRef = VarRef(store: .match, scope: .match, name: "roundsPlayed")

    /// Type-checks and evaluates the source in a `.host` context.
    /// Type and parse errors propagate to the test as thrown errors.
    static func run(
        _ source: String,
        configure: (inout TypeContext) -> Void = { _ in },
        env: (inout EvaluationEnvironment) -> Void = { _ in },
        fuel budget: Int = EvaluationFault.expressionBudget
    ) throws -> Value {
        var context = TypeContext(evaluation: .host)
        configure(&context)
        var checker = TypeChecker(context: context)
        let typed = try checker.check(try Parser().parse(source).ast)
        var environment = EvaluationEnvironment()
        env(&environment)
        var evaluator = Evaluator(context: context)
        return try evaluator.evaluate(
            typed, in: environment, fuel: budget, ruleId: "test", pointer: "/test")
    }

    /// Evaluates the source and returns the fault kind it throws.
    /// Fails the enclosing test when the source evaluates cleanly.
    static func fault(
        _ source: String,
        configure: (inout TypeContext) -> Void = { _ in },
        env: (inout EvaluationEnvironment) -> Void = { _ in },
        fuel budget: Int = EvaluationFault.expressionBudget
    ) -> EvaluationFault.Kind {
        do {
            _ = try run(source, configure: configure, env: env, fuel: budget)
        } catch let fault as EvaluationFault {
            return fault.kind
        } catch {
            Issue.record("unexpected error evaluating '\(source)': \(error)")
            return .unsupportedValue
        }
        Issue.record("'\(source)' evaluated without faulting")
        return .unsupportedValue
    }

    /// A configure block declaring the three rule variables used here.
    static func vars(_ context: inout TypeContext) {
        context.vars[roundsRef.name] = VarDecl(scope: .match, type: .int, initial: "0")
        context.vars[scoresRef.name] = VarDecl(scope: .seatDeal, type: .int, initial: "0")
        context.vars[pointsRef.name] = VarDecl(scope: .teamMatch, type: .int, initial: "0")
    }

    /// An env block with values for the three declared variables,
    /// ordered by the seat order (N, E, S, W) and team order (NS, EW).
    static func varValues(_ env: inout EvaluationEnvironment) {
        env.plainVars[roundsRef] = .int(2)
        env.indexedVars[scoresRef] = [.int(10), .int(20), .int(30), .int(40)]
        env.indexedVars[pointsRef] = [.int(5), .int(3)]
    }
}

struct EvaluatorArithmeticTests {
    @Test func precedenceAndArithmetic() throws {
        #expect(try Eval.run("1 + 2 * 3") == .int(7))
        #expect(try Eval.run("(1 + 2) * 3") == .int(9))
        #expect(try Eval.run("10 - 3 - 2") == .int(5))
        #expect(try Eval.run("-3 + 10") == .int(7))
        #expect(try Eval.run("7 / 2") == .int(3))
        #expect(try Eval.run("-7 / 2") == .int(-3))
        #expect(try Eval.run("7 % 3") == .int(1))
        #expect(try Eval.run("-7 % 3") == .int(-1))
    }

    @Test func comparisonsAndLogic() throws {
        #expect(try Eval.run("2 < 3") == .bool(true))
        #expect(try Eval.run("3 <= 3") == .bool(true))
        #expect(try Eval.run("3 > 4") == .bool(false))
        #expect(try Eval.run("'2C' == '2C'") == .bool(true))
        #expect(try Eval.run("'2C' != '3C'") == .bool(true))
        #expect(try Eval.run("!false") == .bool(true))
        #expect(try Eval.run("true && false || true") == .bool(true))
        #expect(try Eval.run("true || false && false") == .bool(true))
    }

    @Test func ternarySelectsTheTakenBranch() throws {
        #expect(try Eval.run("true ? 1 : 2") == .int(1))
        #expect(try Eval.run("1 > 2 ? 1 : 2") == .int(2))
        #expect(try Eval.run("1 > 2 ? 1 / 0 : 7") == .int(7))
    }

    @Test func overflowFaults() {
        #expect(Eval.fault("9223372036854775807 + 1") == .integerOverflow)
        #expect(Eval.fault("0 - 9223372036854775807 - 2") == .integerOverflow)
        #expect(Eval.fault("9223372036854775807 * 2") == .integerOverflow)
        #expect(Eval.fault("-9223372036854775807 - 2") == .integerOverflow)
    }

    @Test func divisionByZeroFaults() {
        #expect(Eval.fault("1 / 0") == .divisionByZero)
        #expect(Eval.fault("1 % 0") == .divisionByZero)
        #expect(Eval.fault("1 / (2 - 2)") == .divisionByZero)
    }

    @Test func shortCircuitSkipsTheUntakenBranch() throws {
        // The untaken branch must neither fault nor spend its fuel:
        // if `1 / 0 == 0` were evaluated the run would exhaust the
        // small budget or raise divisionByZero.
        #expect(try Eval.run("false && 1 / 0 == 0", fuel: 4) == .bool(false))
        #expect(try Eval.run("true || 1 / 0 == 0", fuel: 4) == .bool(true))
        #expect(try Eval.run("false && 1 / 0 == 0") == .bool(false))
        #expect(try Eval.run("true || 1 / 0 == 0") == .bool(true))
    }

    @Test func indexOutOfRangeFaults() throws {
        let conf: (inout TypeContext) -> Void = { $0.contextual["xs"] = .list(.int) }
        let env: (inout EvaluationEnvironment) -> Void = {
            $0.contextual["xs"] = .list([.int(10), .int(20)])
        }
        #expect(try Eval.run("xs[1]", configure: conf, env: env) == .int(20))
        #expect(Eval.fault("xs[2]", configure: conf, env: env) == .indexOutOfRange)
        #expect(Eval.fault("xs[99]", configure: conf, env: env) == .indexOutOfRange)
    }

    @Test func nullComparisonsAreStrict() throws {
        #expect(try Eval.run("trick.winner") == .null)
        #expect(try Eval.run("trick.ledSuit") == .null)
        #expect(try Eval.run("trick.ledSuit == null") == .bool(true))
        #expect(try Eval.run("trick.ledSuit == 'H'") == .bool(false))
        // Ordering and arithmetic on null dereference instead of
        // silently treating null as a value (§7.6). Optional ints
        // type-check by unwrapping; a null operand faults at runtime.
        let nullableInt: (inout TypeContext) -> Void = { $0.contextual["n"] = .optional(.int) }
        let nullInt: (inout EvaluationEnvironment) -> Void = { $0.contextual["n"] = .null }
        #expect(Eval.fault("n < 1", configure: nullableInt, env: nullInt) == .nullDereference)
        #expect(Eval.fault("n + 1", configure: nullableInt, env: nullInt) == .nullDereference)
    }

    @Test func fuelExhaustionFaults() throws {
        #expect(Eval.fault("1 + 2", fuel: 1) == .fuelExhausted)
        #expect(Eval.fault("1 + 2", fuel: 0) == .fuelExhausted)
        #expect(try Eval.run("1 + 2", fuel: 3) == .int(3))
    }

    @Test func recursiveDefBodiesAreRejected() throws {
        let oddBody = try Parser().parse("n == 0 ? false : even(n - 1)").ast
        let evenBody = try Parser().parse("n == 0 ? true : odd(n - 1)").ast
        let conf: (inout TypeContext) -> Void = { context in
            context.defs["odd"] = .init(
                name: "odd", params: ["n"], types: [.int], result: .bool, body: oddBody)
            context.defs["even"] = .init(
                name: "even", params: ["n"], types: [.int], result: .bool, body: evenBody)
        }
        // The plan bans def recursion (§7.2): the cycle is reported when the
        // def whose body closes it is checked, not at fuel exhaustion (§11.4).
        #expect(throws: TypeError.self) { try Check.apply("even(21)", configure: conf) }
    }
}

struct EvaluatorBuiltinTests {
    @Test func seatArithmeticWrapsTheTable() throws {
        #expect(try Eval.run("left('N', 1)", env: Eval.bridge) == .string("E"))
        #expect(try Eval.run("left('W', 1)", env: Eval.bridge) == .string("N"))
        #expect(try Eval.run("right('N', 1)", env: Eval.bridge) == .string("W"))
        #expect(try Eval.run("left('N', 4)", env: Eval.bridge) == .string("N"))
        #expect(try Eval.run("left('N', 5)", env: Eval.bridge) == .string("E"))
        #expect(try Eval.run("left('N', -3)", env: Eval.bridge) == .string("E"))
    }

    @Test func partnerTeamAndOpponents() throws {
        #expect(try Eval.run("partner('N')", env: Eval.bridge) == .string("S"))
        #expect(try Eval.run("team('N')", env: Eval.bridge) == .string("NS"))
        #expect(try Eval.run("team('E')", env: Eval.bridge) == .string("EW"))
        #expect(try Eval.run("opponents('NS')", env: Eval.bridge) == .string("EW"))
    }

    @Test func partnerAndOpponentsFaultOnWrongShape() throws {
        // Three seats all on one team: no unique mate for partner('N'),
        // and no opposing team for opponents('NS').
        let lopsided: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            env.seats = [.string("N"), .string("S"), .string("W")]
            env.teamOfSeat = ["N": "NS", "S": "NS", "W": "NS"]
            env.teams = [.string("NS")]
        }
        #expect(Eval.fault("partner('N')", env: lopsided) == .unsupportedValue)
        #expect(Eval.fault("opponents('NS')", env: lopsided) == .unsupportedValue)
        #expect(Eval.fault("team('X')", env: Eval.bridge) == .unsupportedValue)
    }

    @Test func nextActiveFollowsPlayOrder() throws {
        #expect(try Eval.run("nextActive('N')", env: Eval.bridge) == .string("E"))
        let solo: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            env.activeSeats = ["N"]
        }
        #expect(try Eval.run("nextActive('N')", env: solo) == .string("N"))
    }

    @Test func zoneReads() throws {
        let env: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            env.zoneContents["hand"] = [
                .card(id: "2C", suit: "C", rank: "2"),
                .card(id: "AH", suit: "H", rank: "A"),
            ]
            env.zoneReader = { _, owner in
                owner == .string("W") ? [.card(id: "2C", suit: "C", rank: "2")] : []
            }
        }
        #expect(try Eval.run("zone('hand').size()", env: env) == .int(2))
        #expect(try Eval.run("zone('hand').contains(c)", env: env) == .bool(true))
        #expect(try Eval.run("zone('hand', 'W').size()", env: env) == .int(1))
        #expect(Eval.fault("zone('discards').size()", env: env) == .unsupportedValue)
    }

    @Test func stateReadsThroughHostClosures() throws {
        let conf: (inout TypeContext) -> Void = {
            $0.contextual["t"] = .team
            $0.contextual["s"] = .seat
        }
        let env: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            env.contextual["t"] = .string("NS")
            env.contextual["s"] = .string("N")
            env.holderOf = { faceId in faceId == "AH" ? .string("E") : .null }
            env.tricksWon = { team in team == .string("NS") ? 3 : 1 }
            env.playedBy = { seat in
                seat == "N" ? [.card(id: "AH", suit: "H", rank: "A")] : []
            }
            env.choice = { id, seat in
                id == "calledSuit" && seat == "W" ? .string("H") : .null
            }
            env.dealtHands = {
                [
                    .card(id: "2C", suit: "C", rank: "2"), .card(id: "3D", suit: "D", rank: "3"),
                    .card(id: "4H", suit: "H", rank: "4"), .card(id: "5S", suit: "S", rank: "5"),
                ]
            }
        }
        #expect(try Eval.run("holderOf('AH')", env: env) == .string("E"))
        #expect(try Eval.run("holderOf('XX')", env: env) == .null)
        #expect(try Eval.run("tricksWon(t)", configure: conf, env: env) == .int(3))
        #expect(try Eval.run("tricksWon(s)", configure: conf, env: env) == .int(1))
        #expect(try Eval.run("playedBy('N').size()", env: env) == .int(1))
        #expect(try Eval.run("choice('calledSuit', 'W')", env: env) == .string("H"))
        #expect(try Eval.run("dealtHands().size()", env: env) == .int(4))
    }

    @Test func rankOrdersCodesAndColors() throws {
        let env: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            env.orders["standard"] = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]
        }
        #expect(try Eval.run("rankIndex('standard', '2')", env: env) == .int(0))
        #expect(try Eval.run("rankIndex('standard', 'A')", env: env) == .int(12))
        #expect(try Eval.run("rankCode('7')", env: env) == .int(7))
        #expect(try Eval.run("rankCode('10')", env: env) == .int(10))
        #expect(try Eval.run("rankCode('A')", env: env) == .int(14))
        #expect(try Eval.run("colorOf('H')", env: env) == .string("red"))
        #expect(try Eval.run("colorOf('D')", env: env) == .string("red"))
        #expect(try Eval.run("colorOf('S')", env: env) == .string("black"))
        #expect(try Eval.run("colorOf('C')", env: env) == .string("black"))
        #expect(Eval.fault("rankIndex('other', 'A')", env: env) == .unsupportedValue)
        #expect(Eval.fault("rankCode('B')", env: env) == .unsupportedValue)
        #expect(Eval.fault("colorOf('X')", env: env) == .unsupportedValue)
    }

    @Test func topPrefixesTheInspectedList() throws {
        #expect(try Eval.run("top(1).size()", env: Eval.bridge) == .int(1))
        #expect(try Eval.run("top(9).size()", env: Eval.bridge) == .int(2))
        #expect(try Eval.run("top(0).size()", env: Eval.bridge) == .int(0))
    }

    @Test func nativeFaultsPropagate() throws {
        // Named function, not a closure literal: Swift 6.3 mis-types the
        // thrown expression as `any Error` inside a closure literal
        // annotated with a typed-throws type (fixed in 6.4).
        @Sendable func throwingNative(_ args: [Value]) throws(EvaluationFault) -> Value {
            throw EvaluationFault(
                kind: .unsupportedValue, ruleId: nil, pointer: "/native", message: "boom")
        }
        let conf: (inout TypeContext) -> Void = {
            $0.natives["deal.shuffle"] = .init([.int], result: .int)
        }
        let env: (inout EvaluationEnvironment) -> Void = {
            $0.natives["deal.shuffle"] = { _ in .int(6) }
        }
        #expect(try Eval.run("deal.shuffle(2)", configure: conf, env: env) == .int(6))
        let throwing: (inout EvaluationEnvironment) -> Void = {
            $0.natives["deal.shuffle"] = throwingNative
        }
        #expect(Eval.fault("deal.shuffle(2)", configure: conf, env: throwing) == .unsupportedValue)
    }
}

struct EvaluatorBindingTests {
    @Test func cardAndTrickBindings() throws {
        #expect(
            try Eval.run("c.id == '2C' && c.suit == 'C' && c.rank == '2'", env: Eval.bridge)
                == .bool(true))
        #expect(
            try Eval.run("trick.number == 1 && trick.leader == 'N'", env: Eval.bridge)
                == .bool(true))
        #expect(try Eval.run("trick.cards.size() == 1", env: Eval.bridge) == .bool(true))
    }

    @Test func seatPlayersAndDealBindings() throws {
        #expect(try Eval.run("seat == 'W' && dealer == 'S'", env: Eval.bridge) == .bool(true))
        #expect(
            try Eval.run("players.count == 4 && players.active == 4", env: Eval.bridge)
                == .bool(true))
        #expect(try Eval.run("deal.index == 2", env: Eval.bridge) == .bool(true))
    }

    @Test func optionReads() throws {
        let conf: (inout TypeContext) -> Void = {
            $0.options["breakingHearts"] = .bool
        }
        let env: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            env.optionValues["breakingHearts"] = .bool(true)
        }
        #expect(try Eval.run("options.breakingHearts", configure: conf, env: env) == .bool(true))
    }

    @Test func scopedVariableReads() throws {
        let env: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            Eval.varValues(&env)
        }
        #expect(try Eval.run("match.roundsPlayed", configure: Eval.vars, env: env) == .int(2))
        #expect(try Eval.run("deal.scores['N']", configure: Eval.vars, env: env) == .int(10))
        #expect(try Eval.run("deal.scores['S']", configure: Eval.vars, env: env) == .int(30))
        #expect(try Eval.run("deal.scores[seat]", configure: Eval.vars, env: env) == .int(40))
        #expect(try Eval.run("match.points['NS']", configure: Eval.vars, env: env) == .int(5))
        #expect(try Eval.run("match.points['EW']", configure: Eval.vars, env: env) == .int(3))
    }

    @Test func scopedVariableIndexFaults() throws {
        let conf: (inout TypeContext) -> Void = { context in
            Eval.vars(&context)
            context.contextual["p"] = .seat
        }
        let env: (inout EvaluationEnvironment) -> Void = { env in
            Eval.bridge(&env)
            Eval.varValues(&env)
            env.contextual["p"] = .string("X")
        }
        #expect(Eval.fault("deal.scores[p]", configure: conf, env: env) == .indexOutOfRange)
    }
}
