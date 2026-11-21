import CardModel
@_spi(HostOnly) import RulesEngine
import Testing

// The show and score mechanics (P3.1): counted reveals in order with the
// starter counted in, award fallbacks and faults, and scoring effects
// gated by seat choices.
@Suite("Show and score mechanics (P3.1)")
struct ShowScoreTests {
    static func showEngine(
        hands: [[(String, String)]], crib: [(String, String)], starter: [(String, String)],
        entries: [ShowEntryParams], with: String?? = nil,
        points: ExprRef? = ExprRef(pointer: "/phases/show/points", source: "handPoints"),
        manual: ExprRef? = nil, muggins: ExprRef? = nil, pointsRule: String? = "CRB-5.2"
    ) -> Engine {
        let params = ShowParams(
            order: entries,
            with: with ?? "starter",
            points: points, pointsRule: pointsRule, manual: manual, muggins: muggins,
            awardName: "match.score", awardIndex: "awardee")
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(id: "show", mechanic: AnyMechanic(ShowMechanic.self, params: params)),
                MechanicsFixtures.idlePhase("after"),
            ],
            seats: 2, vars: ["score": MechanicsFixtures.scoreVar()],
            setup: { state in
                for (seat, faces) in hands.enumerated() {
                    try MechanicsFixtures.dealHand(&state, seat: seat, faces: faces, base: UInt16(seat * 13))
                }
                try MechanicsFixtures.sharedZone(&state, "crib", cards: crib, base: 50)
                try MechanicsFixtures.sharedZone(&state, "starter", cards: starter, base: 80)
            })
    }

    /// Pone and dealer hand entries plus the dealer's crib, cribbage-shaped.
    static func cribbageEntries() -> [ShowEntryParams] {
        [
            ShowEntryParams(
                zone: "hand", seat: ExprRef(pointer: "/phases/show/order0/seat", source: "pone"),
                award: ExprRef(pointer: "/phases/show/order0/award", source: "pone")),
            ShowEntryParams(
                zone: "hand", seat: ExprRef(pointer: "/phases/show/order1/seat", source: "dealer"),
                award: ExprRef(pointer: "/phases/show/order1/award", source: "dealer")),
            ShowEntryParams(
                zone: "crib", award: ExprRef(pointer: "/phases/show/order2/award", source: "dealer"),
                isCrib: true),
        ]
    }

    static func scoreEngine(
        effects: [EngineEffect], choices: [ScoreChoiceRef]? = nil,
        extraVars: [String: EngineVarDecl] = [:]
    ) -> Engine {
        var vars = [
            "verdict": MechanicsFixtures.matchStringVar("verdict"),
            "confession": MechanicsFixtures.matchStringVar("confession"),
        ]
        vars.merge(extraVars) { _, new in new }
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(
                    id: "score",
                    mechanic: AnyMechanic(ScoreMechanic.self, params: ScoreParams(effects: effects, choices: choices))),
                MechanicsFixtures.idlePhase("after"),
            ],
            seats: 2, vars: vars, setup: { _ in })
    }

    static func choice(
        _ id: String, seatSource: String, whenSource: String, values: [String]
    ) -> ScoreChoiceRef {
        ScoreChoiceRef(
            id: id,
            seat: ExprRef(pointer: "/phases/score/choices/\(id)/seat", source: seatSource),
            when: ExprRef(pointer: "/phases/score/choices/\(id)/when", source: whenSource),
            values: values)
    }

    // MARK: - show

    @Test func showScoresPilesInOrderWithStarter() throws {
        let hands = [[("S", "5"), ("S", "J")], [("D", "3"), ("D", "4")]]
        let engine = Self.showEngine(
            hands: hands, crib: [("H", "9"), ("D", "9")], starter: [("S", "A")],
            entries: Self.cribbageEntries())
        let started = try engine.start(seed: 25)
        let state = started.state
        // The show is automatic: `cards` binds the pile only (ADR-0029), so
        // the pone's hand is 7, the dealer's 15, and the crib 20.
        #expect(state.phase.phaseID == "done")
        #expect(MechanicsFixtures.scoreOf(state, 0) == .int(35))
        #expect(MechanicsFixtures.scoreOf(state, 1) == .int(7))
        #expect(
            started.events.contains(
                .revealed(zone: "crib", cards: state.zones.cards(in: ZoneKey(scope: .shared, id: "crib")))))
        #expect(started.events.contains(.scored(seat: Seat(1), points: 7, reason: "show", ruleId: "CRB-5.2")))
        // Every shown card is public knowledge.
        #expect(state.knowledge.isPublic(CardID(0)))
        #expect(state.knowledge.isPublic(CardID(50)))
    }

    @Test func showAwardFallsBackToSeatAndVariantsFault() throws {
        // An entry without `award` scores to its `seat`.
        let fallback = Self.showEngine(
            hands: [[("S", "5"), ("S", "J")], [("D", "3"), ("D", "4")]],
            crib: [], starter: [("S", "A")],
            entries: [
                ShowEntryParams(
                    zone: "hand", seat: ExprRef(pointer: "/phases/show/order0/seat", source: "pone"))
            ])
        let shown = try fallback.start(seed: 26)
        #expect(MechanicsFixtures.scoreOf(shown.state, 1) == .int(7))
        #expect(MechanicsFixtures.scoreOf(shown.state, 0) == .int(0))
        // An entry with neither seat nor award has no awardee (the pile
        // must score something for the fault to surface).
        let noAwardee = Self.showEngine(
            hands: [[], []], crib: [("H", "9")], starter: [],
            entries: [ShowEntryParams(zone: "crib", isCrib: false)])
        #expect(throws: RuleViolation.self) { try noAwardee.start(seed: 1) }
        // A non-integer points expression faults.
        let boolPoints = Self.showEngine(
            hands: [[], []], crib: [], starter: [], entries: Self.cribbageEntries(),
            points: ExprRef(pointer: "/p/x", source: "skipAlways"))
        #expect(throws: RuleViolation.self) { try boolPoints.start(seed: 1) }
        // An empty `with` zone name faults.
        let emptyWith = Self.showEngine(
            hands: [[("S", "5")], []], crib: [], starter: [], entries: Self.cribbageEntries(),
            with: .some(""))
        #expect(throws: RuleViolation.self) { try emptyWith.start(seed: 1) }
    }

    @Test func showWithoutStarterZoneScoresPilesAlone() throws {
        let hands = [[("S", "5"), ("S", "J")], [("D", "3"), ("D", "4")]]
        let engine = Self.showEngine(
            hands: hands, crib: [], starter: [], entries: Self.cribbageEntries(), with: .some(nil))
        let started = try engine.start(seed: 27)
        // No `with` zone: 15 for the dealer's hand plus the empty crib's
        // isCrib bonus, and 7 for the pone's hand.
        #expect(MechanicsFixtures.scoreOf(started.state, 0) == .int(17))
        #expect(MechanicsFixtures.scoreOf(started.state, 1) == .int(7))
    }

    @Test func showFaultsOnManualAndMuggins() throws {
        let manual = Self.showEngine(
            hands: [[], []], crib: [], starter: [], entries: Self.cribbageEntries(),
            manual: ExprRef(pointer: "/p/x", source: "skipAlways"))
        #expect(throws: RuleViolation.self) { try manual.start(seed: 1) }
        let muggins = Self.showEngine(
            hands: [[], []], crib: [], starter: [], entries: Self.cribbageEntries(),
            muggins: ExprRef(pointer: "/p/x", source: "skipAlways"))
        #expect(throws: RuleViolation.self) { try muggins.start(seed: 1) }
        // A disabled gate is fine.
        let offGate = Self.showEngine(
            hands: [[("S", "5")], []], crib: [], starter: [], entries: Self.cribbageEntries(),
            manual: ExprRef(pointer: "/p/x", source: "neverMoon"))
        let started = try offGate.start(seed: 1)
        #expect(started.state.phase.phaseID == "done")
    }

    @Test func showTakesNoIntents() throws {
        let engine = Self.showEngine(
            hands: [[("S", "5")], []], crib: [], starter: [], entries: Self.cribbageEntries())
        let started = try engine.start(seed: 28)
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .confirm, expectedVersion: started.state.version),
                to: started.state)
        }
    }

    // MARK: - score

    @Test func scoreRunsWithoutChoices() throws {
        let engine = Self.scoreEngine(
            effects: [.set(name: "match.verdict", index: nil, value: "alwaysHearts")])
        let started = try engine.start(seed: 29)
        #expect(started.state.phase.phaseID == "done")
        #expect(MechanicsFixtures.matchVar(started.state, "verdict") == .string("H"))
    }

    @Test func scoreChoiceGatesAndSettles() throws {
        let moon = Self.choice("moon", seatSource: "dealer", whenSource: "moonPossible", values: ["take", "drop"])
        let engine = Self.scoreEngine(
            effects: [.set(name: "match.verdict", index: nil, value: "chosenMoon")],
            choices: [moon])
        let started = try engine.start(seed: 30)
        var state = started.state
        #expect(state.phase.phaseID == "score")
        // The dealer owes the choice; nobody else may act.
        #expect(MechanicsFixtures.matchVar(state, "verdict") == .null)
        #expect(engine.legalIntents(for: Seat(0), in: state) == [.choose("take"), .choose("drop")])
        #expect(engine.legalIntents(for: Seat(1), in: state).isEmpty)
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .choose("moonwalk"), expectedVersion: state.version), to: state)
        }
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state)
        }
        state = try engine.apply(
            Action(seat: Seat(0), intent: .choose("take"), expectedVersion: state.version), to: state
        ).state
        #expect(MechanicsFixtures.matchVar(state, "verdict") == .string("take"))
        #expect(state.phase.phaseID == "done")
    }

    @Test func scoreGateFalseRunsEffectsImmediately() throws {
        let moon = Self.choice("moon", seatSource: "dealer", whenSource: "neverMoon", values: ["take"])
        let engine = Self.scoreEngine(
            effects: [.set(name: "match.verdict", index: nil, value: "alwaysHearts")],
            choices: [moon])
        let started = try engine.start(seed: 31)
        #expect(started.state.phase.phaseID == "done")
        #expect(MechanicsFixtures.matchVar(started.state, "verdict") == .string("H"))
    }

    @Test func scoreMultipleChoicesSettleInOrder() throws {
        let moon = Self.choice("moon", seatSource: "dealer", whenSource: "moonPossible", values: ["take", "drop"])
        let confess = Self.choice("confess", seatSource: "pone", whenSource: "moonPossible", values: ["yes", "no"])
        let engine = Self.scoreEngine(
            effects: [
                .set(name: "match.verdict", index: nil, value: "chosenMoon"),
                .set(name: "match.confession", index: nil, value: "chosenConfess"),
            ],
            choices: [moon, confess])
        let started = try engine.start(seed: 32)
        var state = started.state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .choose("drop"), expectedVersion: state.version), to: state
        ).state
        // One choice still pending: the effects have not run yet.
        #expect(state.phase.phaseID == "score")
        #expect(MechanicsFixtures.matchVar(state, "verdict") == .null)
        state = try engine.apply(
            Action(seat: Seat(1), intent: .choose("yes"), expectedVersion: state.version), to: state
        ).state
        #expect(MechanicsFixtures.matchVar(state, "verdict") == .string("drop"))
        #expect(MechanicsFixtures.matchVar(state, "confession") == .string("yes"))
        #expect(state.phase.phaseID == "done")
    }

    @Test func scoreFaultsOnBadChoiceConfig() {
        let noValues = Self.scoreEngine(
            effects: [],
            choices: [Self.choice("moon", seatSource: "dealer", whenSource: "moonPossible", values: [])])
        #expect(throws: RuleViolation.self) { try noValues.start(seed: 1) }
        let intGate = Self.scoreEngine(
            effects: [],
            choices: [Self.choice("moon", seatSource: "dealer", whenSource: "2", values: ["take"])])
        #expect(throws: RuleViolation.self) { try intGate.start(seed: 1) }
        let intSeat = Self.scoreEngine(
            effects: [],
            choices: [Self.choice("moon", seatSource: "2", whenSource: "moonPossible", values: ["take"])])
        #expect(throws: RuleViolation.self) { try intSeat.start(seed: 1) }
    }
}
