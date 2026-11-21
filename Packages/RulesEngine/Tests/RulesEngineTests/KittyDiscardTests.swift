import CardModel
@_spi(HostOnly) import RulesEngine
import Testing

// The exchange.kitty and exchange.discardTo mechanics (P3.1): euchre's
// pick-up, cribbage's lay-away, knowledge boundaries, and
// invalid-parameter rejections.
@Suite("Kitty and discard-to mechanics (P3.1)")
struct KittyDiscardTests {
    static func kittyEngine(
        hands: [[(String, String)]] = [[("S", "5"), ("S", "6"), ("H", "7"), ("H", "8"), ("D", "9")], [], [], []],
        upcard: [(String, String)] = [("C", "Q")], kitty: [(String, String)] = [],
        take: ExprRef?, discard: ExprRef?, discardTo: ExprRef?, skipIf: ExprRef? = nil,
        seat: ExprRef? = ExprRef(pointer: "/phases/pickup/seat", source: "dealer")
    ) -> Engine {
        let params = ExchangeKittyParams(
            seat: seat, take: take, discard: discard, discardTo: discardTo, skipIf: skipIf)
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(id: "pickup", mechanic: AnyMechanic(ExchangeKittyMechanic.self, params: params)),
                MechanicsFixtures.idlePhase("after"),
            ],
            setup: { state in
                for (seatIndex, faces) in hands.enumerated() {
                    try MechanicsFixtures.dealHand(
                        &state, seat: seatIndex, faces: faces, base: UInt16(seatIndex * 13))
                }
                try MechanicsFixtures.sharedZone(&state, "upcard", cards: upcard, base: 60, publicToAll: true)
                try MechanicsFixtures.sharedZone(&state, "kitty", cards: kitty, base: 50)
                try MechanicsFixtures.sharedZone(&state, "discard", cards: [], base: 70)
            })
    }

    static func discardToEngine(
        hands: [[(String, String)]], toScope: String, count: String,
        revealTo: String, simultaneous: Bool = true
    ) -> Engine {
        let params = ExchangeDiscardToParams(
            from: "hand", to: "crib", toScope: toScope,
            count: ExprRef(pointer: "/phases/layAway/count", source: count),
            revealTo: revealTo, simultaneous: simultaneous)
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(id: "layAway", mechanic: AnyMechanic(ExchangeDiscardToMechanic.self, params: params)),
                MechanicsFixtures.idlePhase("after"),
            ],
            setup: { state in
                for (seat, faces) in hands.enumerated() {
                    try MechanicsFixtures.dealHand(&state, seat: seat, faces: faces, base: UInt16(seat * 13))
                    try MechanicsFixtures.declareSeat(&state, seat: seat, zone: "crib")
                }
                try MechanicsFixtures.sharedZone(&state, "crib", cards: [], base: 50)
            })
    }

    static func handCards(_ state: GameState, _ seat: Int) -> [CardID] {
        state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand")).map { $0.id }
    }

    static func sharedIDs(_ state: GameState, _ zone: String) -> [CardID] {
        state.zones.cards(in: ZoneKey(scope: .shared, id: zone)).map { $0.id }
    }

    // MARK: - exchange.kitty

    @Test func dealerTakesUpcardThenDiscardsOne() throws {
        let engine = Self.kittyEngine(
            take: ExprRef(pointer: "/phases/pickup/take", source: "takeUpcard"),
            discard: ExprRef(pointer: "/phases/pickup/discard", source: "1"),
            discardTo: ExprRef(pointer: "/phases/pickup/discardTo", source: "zoneKitty"))
        let started = try engine.start(seed: 4)
        var state = started.state
        // The take happens at entry: the upcard joined the dealer's hand
        // (a fresh state deals seat 0).
        #expect(state.phase.phaseID == "pickup")
        #expect(Self.sharedIDs(state, "upcard").isEmpty)
        #expect(Self.handCards(state, 0).count == 6)
        // The dealer lays one card away, face down to the kitty.
        #expect(engine.legalIntents(for: Seat(0), in: state).count == 6)
        state = try engine.apply(
            Action(seat: Seat(0), intent: .discard([CardID(4)]), expectedVersion: state.version), to: state
        ).state
        #expect(Self.sharedIDs(state, "kitty") == [CardID(4)])
        #expect(Self.handCards(state, 0).count == 5)
        #expect(state.phase.phaseID == "done")
        // The laid-away card stays known to its discarder only.
        #expect(state.knowledge.knows(CardID(4), Seat(0)))
        #expect(!state.knowledge.knows(CardID(4), Seat(1)))
    }

    @Test func takeByCountFromKittyZone() throws {
        let kitty: [(String, String)] = [("H", "A"), ("D", "K")]
        let engine = Self.kittyEngine(
            kitty: kitty,
            take: ExprRef(pointer: "/phases/pickup/take", source: "2"),
            discard: nil, discardTo: nil)
        let started = try engine.start(seed: 6)
        // No discard step: the phase completed at entry.
        #expect(started.state.phase.phaseID == "done")
        #expect(Self.sharedIDs(started.state, "kitty").isEmpty)
        #expect(Self.handCards(started.state, 0).count == 7)
        #expect(started.state.knowledge.knows(CardID(50), Seat(0)))
        #expect(!started.state.knowledge.knows(CardID(50), Seat(1)))
    }

    @Test func skipIfEndsPhaseBeforeAnyMove() throws {
        let engine = Self.kittyEngine(
            take: ExprRef(pointer: "/phases/pickup/take", source: "takeUpcard"),
            discard: ExprRef(pointer: "/phases/pickup/discard", source: "1"),
            discardTo: ExprRef(pointer: "/phases/pickup/discardTo", source: "zoneKitty"),
            skipIf: ExprRef(pointer: "/phases/pickup/skipIf", source: "skipAlways"))
        let started = try engine.start(seed: 8)
        #expect(started.state.phase.phaseID == "done")
        #expect(Self.sharedIDs(started.state, "upcard") == [CardID(60)])
        #expect(Self.handCards(started.state, 0).count == 5)
    }

    @Test func kittyFaultsOnBadParams() {
        let zone = ExprRef(pointer: "/p/x", source: "takeUpcard")
        let noSeat = Self.kittyEngine(take: zone, discard: nil, discardTo: nil, seat: nil)
        #expect(throws: RuleViolation.self) { try noSeat.start(seed: 1) }
        let boolTake = Self.kittyEngine(
            take: ExprRef(pointer: "/p/x", source: "skipAlways"), discard: nil, discardTo: nil)
        #expect(throws: RuleViolation.self) { try boolTake.start(seed: 1) }
        let stringDiscard = Self.kittyEngine(
            take: zone, discard: ExprRef(pointer: "/p/x", source: "zoneKitty"), discardTo: nil)
        #expect(throws: RuleViolation.self) { try stringDiscard.start(seed: 1) }
        let intDiscardTo = Self.kittyEngine(
            take: zone, discard: nil, discardTo: ExprRef(pointer: "/p/x", source: "2"))
        #expect(throws: RuleViolation.self) { try intDiscardTo.start(seed: 1) }
        let intSkip = Self.kittyEngine(
            take: zone, discard: nil, discardTo: nil,
            skipIf: ExprRef(pointer: "/p/x", source: "1"))
        #expect(throws: RuleViolation.self) { try intSkip.start(seed: 1) }
    }

    @Test func kittyRejectsBadIntents() throws {
        let hands: [[(String, String)]] = [[("S", "5")], [], [], [("S", "6"), ("H", "7")]]
        let engine = Self.kittyEngine(
            hands: hands,
            take: ExprRef(pointer: "/phases/pickup/take", source: "takeUpcard"),
            discard: ExprRef(pointer: "/phases/pickup/discard", source: "1"),
            discardTo: ExprRef(pointer: "/phases/pickup/discardTo", source: "zoneKitty"))
        let started = try engine.start(seed: 10)
        let state = started.state
        // Only the acting seat (the dealer, seat 0) may act.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(1), intent: .discard([CardID(39)]), expectedVersion: state.version), to: state)
        }
        // Only one-card discard intents.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(39)), expectedVersion: state.version), to: state)
        }
        // The laid-away card must come from the actor's own hand.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .discard([CardID(39)]), expectedVersion: state.version), to: state)
        }
    }

    // MARK: - exchange.discardTo

    @Test func everySeatDiscardsToSharedCrib() throws {
        let hands = Array(repeating: [("S", "5"), ("S", "6"), ("H", "7"), ("H", "8")], count: 4)
        let engine = Self.discardToEngine(
            hands: hands, toScope: "shared", count: "2", revealTo: "nobody")
        let started = try engine.start(seed: 11)
        var state = started.state
        #expect(state.phase.phaseID == "layAway")
        // One multi-card intent lays two cards away at once.
        state = try engine.apply(
            Action(seat: Seat(0), intent: .discard([CardID(0), CardID(1)]), expectedVersion: state.version),
            to: state
        ).state
        #expect(Self.sharedIDs(state, "crib").count == 2)
        // Finished seats leave the pending set.
        #expect(engine.legalIntents(for: Seat(0), in: state).isEmpty)
        for seat in 1...3 {
            state = try engine.apply(
                Action(
                    seat: Seat(seat),
                    intent: .discard([CardID(UInt16(seat * 13)), CardID(UInt16(seat * 13 + 1))]),
                    expectedVersion: state.version), to: state
            ).state
        }
        #expect(state.phase.phaseID == "done")
        #expect(Self.sharedIDs(state, "crib").count == 8)
        for seat in 0...3 {
            #expect(Self.handCards(state, seat).count == 2)
        }
        // Private discards: only the discarder still knows their cards.
        #expect(state.knowledge.knows(CardID(0), Seat(0)))
        #expect(!state.knowledge.knows(CardID(0), Seat(1)))
    }

    @Test func seatScopedDiscardKeepsPilesSeparate() throws {
        let hands = Array(repeating: [("S", "5"), ("S", "6")], count: 4)
        let engine = Self.discardToEngine(
            hands: hands, toScope: "seat", count: "2", revealTo: "nobody")
        let started = try engine.start(seed: 12)
        var state = started.state
        for seat in 0...3 {
            state = try engine.apply(
                Action(
                    seat: Seat(seat),
                    intent: .discard([CardID(UInt16(seat * 13)), CardID(UInt16(seat * 13 + 1))]),
                    expectedVersion: state.version), to: state
            ).state
        }
        #expect(state.phase.phaseID == "done")
        for seat in 0...3 {
            #expect(state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "crib")).count == 2)
        }
        #expect(Self.sharedIDs(state, "crib").isEmpty)
    }

    @Test func revealToAllPublishesDiscards() throws {
        let hands = Array(repeating: [("S", "5")], count: 4)
        let engine = Self.discardToEngine(
            hands: hands, toScope: "shared", count: "1", revealTo: "all")
        let started = try engine.start(seed: 13)
        var state = started.state
        state = try engine.apply(
            Action(seat: Seat(0), intent: .discard([CardID(0)]), expectedVersion: state.version), to: state
        ).state
        #expect(state.knowledge.isPublic(CardID(0)))
    }

    @Test func shortHoldingDiscardsWholeHand() throws {
        var hands = Array(repeating: [("S", "5"), ("S", "6")], count: 4)
        hands[2] = [("H", "9")]
        let engine = Self.discardToEngine(
            hands: hands, toScope: "shared", count: "2", revealTo: "nobody")
        let started = try engine.start(seed: 14)
        var state = started.state
        for seat in 0...3 {
            let ids = Self.handCards(state, seat).map { $0 }
            state = try engine.apply(
                Action(seat: Seat(seat), intent: .discard(ids), expectedVersion: state.version), to: state
            ).state
        }
        #expect(state.phase.phaseID == "done")
        #expect(Self.sharedIDs(state, "crib").count == 7)
        #expect(Self.handCards(state, 2).isEmpty)
    }

    @Test func emptyHandSeatIsSkipped() throws {
        var hands = Array(repeating: [("S", "5")], count: 4)
        hands[1] = []
        let engine = Self.discardToEngine(
            hands: hands, toScope: "shared", count: "1", revealTo: "nobody")
        let started = try engine.start(seed: 15)
        var state = started.state
        #expect(engine.legalIntents(for: Seat(1), in: started.state).isEmpty)
        for seat in [0, 2, 3] {
            state = try engine.apply(
                Action(seat: Seat(seat), intent: .discard([CardID(UInt16(seat * 13))]), expectedVersion: state.version),
                to: state
            ).state
        }
        #expect(state.phase.phaseID == "done")
    }

    @Test func discardToFaultsOnBadParams() {
        let hands = Array(repeating: [("S", "5")], count: 4)
        let zeroCount = Self.discardToEngine(hands: hands, toScope: "shared", count: "0", revealTo: "nobody")
        #expect(throws: RuleViolation.self) { try zeroCount.start(seed: 1) }
        let badScope = Self.discardToEngine(hands: hands, toScope: "team", count: "1", revealTo: "nobody")
        #expect(throws: RuleViolation.self) { try badScope.start(seed: 1) }
        let badReveal = Self.discardToEngine(hands: hands, toScope: "shared", count: "1", revealTo: "recipient")
        #expect(throws: RuleViolation.self) { try badReveal.start(seed: 1) }
    }

    @Test func discardToRejectsBadIntents() throws {
        let hands = Array(repeating: [("S", "5"), ("S", "6"), ("H", "7")], count: 4)
        let engine = Self.discardToEngine(
            hands: hands, toScope: "shared", count: "2", revealTo: "nobody")
        let started = try engine.start(seed: 16)
        let state = started.state
        // Only discard intents.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state)
        }
        // The count caps each seat: three cards exceed a count of two.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(
                    seat: Seat(0), intent: .discard([CardID(0), CardID(1), CardID(2)]),
                    expectedVersion: state.version), to: state)
        }
        // Unknown card ids are not in anyone's hand.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .discard([CardID(999)]), expectedVersion: state.version), to: state)
        }
    }
}
