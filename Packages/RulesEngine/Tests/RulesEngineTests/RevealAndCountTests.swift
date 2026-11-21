import CardModel
@_spi(HostOnly) import RulesEngine
import Testing

// The reveal.starter and count-play mechanics (P3.1): the cribbage cut
// with seeded depth, after-effects, and the pegging wave — running
// count, pairs on play, go handling, exact-limit bonus, card returns,
// and invalid-parameter rejections.
@Suite("Starter and count-play mechanics (P3.1)")
struct RevealAndCountTests {
    static func starterEngine(
        stock: [(String, String)], minCutDepth: Int? = 4,
        cutBy: ExprRef?? = nil, after: [EngineEffect] = []
    ) -> Engine {
        let params = RevealStarterParams(
            cutBy: cutBy ?? ExprRef(pointer: "/phases/starter/cutBy", source: "pone"),
            from: "stock", to: "starter", minCutDepth: minCutDepth, afterEffects: after)
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(id: "starter", mechanic: AnyMechanic(RevealStarterMechanic.self, params: params)),
                MechanicsFixtures.idlePhase("after"),
            ],
            vars: ["score": MechanicsFixtures.scoreVar()],
            setup: { state in
                try MechanicsFixtures.sharedZone(&state, "stock", cards: stock, base: 60)
                try MechanicsFixtures.sharedZone(&state, "starter", cards: [], base: 80)
            })
    }

    /// Four non-jacks, then four jacks: any cut depth 4–7 lands a jack.
    static func jackStock() -> [(String, String)] {
        [("H", "2"), ("D", "3"), ("C", "4"), ("S", "5"), ("S", "J"), ("H", "J"), ("D", "J"), ("C", "J")]
    }

    static func peggingEngine(
        hands: [[(String, String)]], limit: Int, goLast: Int = 1, goExact: Int = 2,
        firstPlayer: String = "pone", sequence: String = "count"
    ) -> Engine {
        let params = CountPlayParams(
            from: "hand", to: "pegged", runZone: "count", sequence: sequence,
            firstPlayer: ExprRef(pointer: "/phases/pegging/firstPlayer", source: firstPlayer),
            valueOf: ExprRef(pointer: "/phases/pegging/valueOf", source: "cardValue"),
            limit: limit, goLastCardPoints: goLast, goExactLimitPoints: goExact,
            pointsOnPlay: ExprRef(pointer: "/phases/pegging/pointsOnPlay", source: "pegPairs"),
            pointsRule: "CRB-4.3", awardName: "match.score", awardIndex: "seat",
            returnCards: true)
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(id: "pegging", mechanic: AnyMechanic(CountPlayMechanic.self, params: params)),
                MechanicsFixtures.idlePhase("after"),
            ],
            seats: 2, vars: ["score": MechanicsFixtures.scoreVar()],
            setup: { state in
                for (seat, faces) in hands.enumerated() {
                    try MechanicsFixtures.dealHand(&state, seat: seat, faces: faces, base: UInt16(seat * 13))
                    try MechanicsFixtures.declareSeat(&state, seat: seat, zone: "pegged")
                }
                try MechanicsFixtures.sharedZone(&state, "count", cards: [], base: 40)
            })
    }

    static func handCards(_ state: GameState, _ seat: Int) -> [CardID] {
        state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand")).map { $0.id }
    }

    // MARK: - reveal.starter

    @Test func starterIsRevealedPubliclyWithCutRecorded() throws {
        let engine = Self.starterEngine(stock: Self.jackStock())
        let started = try engine.start(seed: 7)
        let state = started.state
        // The cut is automatic: the engine rests after the deal ends.
        #expect(state.phase.phaseID == "done")
        let starterKey = ZoneKey(scope: .shared, id: "starter")
        let starter = state.zones.cards(in: starterKey)
        #expect(starter.count == 1)
        #expect(state.zones.cards(in: ZoneKey(scope: .shared, id: "stock")).count == 7)
        let depth = Int(state.phaseOptions["cutDepth"] ?? "-1") ?? -1
        #expect((4...7).contains(depth))
        #expect(state.phaseOptions["cutBy"] == "1")
        // The starter is face up: every seat knows it.
        for seat in 0...3 {
            #expect(state.knowledge.knows(starter[0].id, Seat(seat)))
        }
        #expect(started.events.contains(.revealed(zone: "starter", cards: [starter[0]])))
    }

    @Test func cutDepthAlwaysRespectsFloorAcrossSeeds() throws {
        for seed in UInt64(0)..<20 {
            let engine = Self.starterEngine(stock: Self.jackStock())
            let state = try engine.start(seed: seed).state
            let depth = Int(state.phaseOptions["cutDepth"] ?? "-1") ?? -1
            #expect((4...7).contains(depth))
        }
    }

    @Test func nilCutterStillRecordsDepth() throws {
        let engine = Self.starterEngine(stock: Self.jackStock(), cutBy: .some(nil))
        let state = try engine.start(seed: 21).state
        #expect(state.phaseOptions["cutBy"] == "-1")
        #expect(state.zones.cards(in: ZoneKey(scope: .shared, id: "starter")).count == 1)
    }

    @Test func afterEffectsAwardHisHeels() throws {
        let heels = EngineEffect.ifElse(
            condition: "starterIsJack",
            thenBranch: [.add(name: "match.score", index: "cut", value: "2", event: "hisHeels")],
            elseBranch: [])
        let engine = Self.starterEngine(stock: Self.jackStock(), after: [heels])
        let started = try engine.start(seed: 3)
        let state = started.state
        // The starter is always a jack here, so the cut seat (pone, S2)
        // scores 2 through the after-effect.
        #expect(MechanicsFixtures.scoreOf(state, 1) == .int(2))
        #expect(started.events.contains(.emitted(name: "hisHeels")))
    }

    @Test func starterFaultsOnBadZoneOrThinStock() {
        let unknown = Self.starterEngine(stock: [])
        #expect(throws: RuleViolation.self) { try unknown.start(seed: 1) }
        let thin = Self.starterEngine(stock: [("S", "2"), ("H", "3"), ("D", "4")], minCutDepth: 4)
        #expect(throws: RuleViolation.self) { try thin.start(seed: 1) }
    }

    // MARK: - count-play

    @Test func peggingCountsPairsAndGo() throws {
        let hands = [[("S", "5"), ("H", "9"), ("D", "K")], [("C", "5"), ("S", "6"), ("H", "7")]]
        let engine = Self.peggingEngine(hands: hands, limit: 31)
        let started = try engine.start(seed: 17)
        var state = started.state
        var allEvents = started.events
        #expect(state.phase.phaseID == "pegging")
        func act(_ seat: Seat, _ intent: ActionIntent) throws {
            let next = try engine.apply(
                Action(seat: seat, intent: intent, expectedVersion: state.version), to: state)
            state = next.state
            allEvents += next.events
        }
        // Pone (S2) leads; the pair scores for the second five's player.
        try act(Seat(1), .play(CardID(13)))
        try act(Seat(0), .play(CardID(0)))
        #expect(state.phaseOptions["count"] == "10")
        try act(Seat(1), .play(CardID(14)))
        try act(Seat(0), .play(CardID(1)))
        #expect(state.phaseOptions["count"] == "25")
        // S2's seven busts the limit: go is the only legal intent.
        #expect(engine.legalIntents(for: Seat(1), in: state) == [.choose("go")])
        try act(Seat(1), .choose("go"))
        #expect(engine.legalIntents(for: Seat(0), in: state) == [.choose("go")])
        try act(Seat(0), .choose("go"))
        // The go closes the run: one point to the last player, cards rest.
        #expect(state.phaseOptions["count"] == "0")
        #expect(Self.sharedIDs(state).isEmpty)
        // The fresh run: S2's seven, then S1's king fit under the limit.
        try act(Seat(1), .play(CardID(15)))
        try act(Seat(0), .play(CardID(2)))
        #expect(state.phase.phaseID == "done")
        // `returnCards` rebuilds both hands for the show.
        #expect(Self.handCards(state, 0).count == 3)
        #expect(Self.handCards(state, 1).count == 3)
        #expect(MechanicsFixtures.scoreOf(state, 0) == .int(3))
        #expect(MechanicsFixtures.scoreOf(state, 1) == .int(0))
        #expect(allEvents.contains(.scored(seat: Seat(0), points: 2, reason: "pegging", ruleId: "count-play")))
        #expect(allEvents.contains(.scored(seat: Seat(0), points: 1, reason: "go", ruleId: "count-play")))
    }

    @Test func exactLimitClosesRunAndAwardsBonus() throws {
        let hands = [[("S", "7"), ("S", "3")], [("H", "8"), ("H", "4")]]
        let engine = Self.peggingEngine(hands: hands, limit: 15)
        var state = try engine.start(seed: 18).state
        state = try engine.apply(
            Action(seat: Seat(1), intent: .play(CardID(13)), expectedVersion: state.version), to: state
        ).state
        // Landing exactly on 15 closes the run and pays the bonus.
        state = try engine.apply(
            Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state
        ).state
        #expect(state.phaseOptions["count"] == "0")
        #expect(MechanicsFixtures.scoreOf(state, 0) == .int(2))
        state = try engine.apply(
            Action(seat: Seat(1), intent: .play(CardID(14)), expectedVersion: state.version), to: state
        ).state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .play(CardID(1)), expectedVersion: state.version), to: state
        ).state
        #expect(state.phase.phaseID == "done")
        #expect(Self.handCards(state, 0).count == 2)
        #expect(MechanicsFixtures.scoreOf(state, 1) == .int(0))
    }

    @Test func goOnlyWhenNothingFits() throws {
        let hands = [[("S", "7")], [("H", "9")]]
        let engine = Self.peggingEngine(hands: hands, limit: 15)
        let started = try engine.start(seed: 19)
        var state = started.state
        // S2's nine fits an empty run: go is illegal.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(1), intent: .choose("go"), expectedVersion: state.version), to: state)
        }
        state = try engine.apply(
            Action(seat: Seat(1), intent: .play(CardID(13)), expectedVersion: state.version), to: state
        ).state
        // 9 + 7 busts 15: S1's go is legal and closes the run.
        state = try engine.apply(
            Action(seat: Seat(0), intent: .choose("go"), expectedVersion: state.version), to: state
        ).state
        #expect(MechanicsFixtures.scoreOf(state, 1) == .int(1))
        #expect(MechanicsFixtures.scoreOf(state, 0) == .int(0))
        state = try engine.apply(
            Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state
        ).state
        #expect(state.phase.phaseID == "done")
        #expect(Self.handCards(state, 0).count == 1)
    }

    @Test func peggingRejectsBadIntentsAndParams() throws {
        let hands = [[("S", "9")], [("H", "9")]]
        let engine = Self.peggingEngine(hands: hands, limit: 12)
        let started = try engine.start(seed: 20)
        var state = started.state
        state = try engine.apply(
            Action(seat: Seat(1), intent: .play(CardID(13)), expectedVersion: state.version), to: state
        ).state
        // The play would run the count to 18, past the limit.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state)
        }
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .call("bid"), expectedVersion: state.version), to: state)
        }
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .choose("knock"), expectedVersion: state.version), to: state)
        }
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(999)), expectedVersion: state.version), to: state)
        }
        // Parameter validation at entry.
        let zeroLimit = Self.peggingEngine(hands: hands, limit: 0)
        #expect(throws: RuleViolation.self) { try zeroLimit.start(seed: 1) }
        let badSequence = Self.peggingEngine(hands: hands, limit: 31, sequence: "sum")
        #expect(throws: RuleViolation.self) { try badSequence.start(seed: 1) }
        let badFirst = Self.peggingEngine(hands: hands, limit: 31, firstPlayer: "2")
        #expect(throws: RuleViolation.self) { try badFirst.start(seed: 1) }
    }

    @Test func nonTurnSeatCannotAct() throws {
        let hands = [[("S", "9")], [("H", "9")]]
        let engine = Self.peggingEngine(hands: hands, limit: 31)
        let started = try engine.start(seed: 22)
        let state = started.state
        // Pone (S2) leads; S1 is not on turn.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state)
        }
    }

    static func sharedIDs(_ state: GameState) -> [CardID] {
        state.zones.cards(in: ZoneKey(scope: .shared, id: "count")).map { $0.id }
    }
}
