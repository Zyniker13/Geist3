import CardModel
@_spi(HostOnly) import RulesEngine
import Testing

// The exchange.pass mechanic (P3.1): staging, the simultaneous chess
// clock, direct one-way picks, reveal choices, and invalid-parameter
// rejections.
@Suite("Exchange pass mechanics (P3.1)")
struct ExchangePassTests {
    /// Fixture: one card per seat unless the hands say otherwise; cards
    /// in seat `s` have ids `s*13` upward.
    static func passEngine(
        hands: [[(String, String)]] = [[("S", "5")], [("H", "J")], [("D", "9")], [("C", "2")]],
        count: String, via: String?, simultaneous: Bool, revealTo: String,
        target: String = "leftSeat"
    ) -> Engine {
        let params = ExchangePassParams(
            from: "hand", via: via, to: "hand",
            count: ExprRef(pointer: "/phases/pass/count", source: count),
            target: ExprRef(pointer: "/phases/pass/target", source: target),
            simultaneous: simultaneous, revealTo: revealTo)
        return MechanicsFixtures.makeEngine(
            phases: [
                MechanicsFixtures.dealPhase(),
                PhaseConfig(id: "pass", mechanic: AnyMechanic(ExchangePassMechanic.self, params: params)),
                MechanicsFixtures.idlePhase("after"),
            ],
            setup: { state in
                for (seat, faces) in hands.enumerated() {
                    try MechanicsFixtures.dealHand(&state, seat: seat, faces: faces, base: UInt16(seat * 13))
                    if via != nil {
                        try MechanicsFixtures.declareSeat(&state, seat: seat, zone: "pass")
                    }
                }
            })
    }

    static func handCards(_ state: GameState, _ seat: Int) -> [CardID] {
        state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand")).map { $0.id }
    }

    @Test func simultaneousPassHoldsUntilEveryoneStaged() throws {
        let engine = Self.passEngine(count: "1", via: "pass", simultaneous: true, revealTo: "recipient")
        let started = try engine.start(seed: 7)
        var state = started.state
        #expect(state.phase.phaseID == "pass")
        // Seat 0 stages; nothing is delivered yet — the chess clock holds.
        let applied = try engine.apply(
            Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state)
        state = applied.state
        #expect(state.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "pass")).count == 1)
        #expect(!Self.handCards(state, 1).contains(CardID(0)))
        // The rest stage; the last pick delivers every passer's card.
        var last = applied
        for seat in 1...3 {
            last = try engine.apply(
                Action(seat: Seat(seat), intent: .play(CardID(UInt16(seat * 13))), expectedVersion: state.version),
                to: state)
            state = last.state
        }
        #expect(state.phase.phaseID == "done")
        for seat in 0...3 {
            let from = (seat + 3) % 4
            #expect(Self.handCards(state, seat) == [CardID(UInt16(from * 13))])
            #expect(state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "pass")).isEmpty)
        }
        // Recipient-only reveal: each seat knows its incoming card, and
        // nobody else does.
        #expect(state.knowledge.knows(CardID(39), Seat(0)))
        #expect(state.knowledge.knows(CardID(0), Seat(1)))
        #expect(!state.knowledge.knows(CardID(0), Seat(2)))
        #expect(last.events.contains(.received(seat: Seat(0), count: 1)))
    }

    @Test func sequentialPassDeliversAsEachSeatStages() throws {
        let hands = [
            [("S", "5"), ("S", "6")], [("H", "7"), ("H", "8")],
            [("D", "9"), ("D", "A")], [("C", "2"), ("C", "3")],
        ]
        let engine = Self.passEngine(
            hands: hands, count: "2", via: "pass", simultaneous: false, revealTo: "nobody",
            target: "rightSeat")
        let started = try engine.start(seed: 3)
        var state = started.state
        // Seat 0 stages both cards; they land with its target at once.
        for card in [CardID(0), CardID(1)] {
            state = try engine.apply(
                Action(seat: Seat(0), intent: .play(card), expectedVersion: state.version), to: state
            ).state
        }
        #expect(Set(Self.handCards(state, 3)) == Set([CardID(0), CardID(1), CardID(39), CardID(40)]))
        // `nobody` reveals nothing, even to the holder.
        #expect(!state.knowledge.knows(CardID(0), Seat(3)))
        // The remaining rotation completes the deal.
        for seat in [3, 2, 1] {
            for card in [CardID(UInt16(seat * 13)), CardID(UInt16(seat * 13 + 1))] {
                state = try engine.apply(
                    Action(seat: Seat(seat), intent: .play(card), expectedVersion: state.version), to: state
                ).state
            }
        }
        #expect(state.phase.phaseID == "done")
        for seat in 0...3 {
            let from = (seat + 1) % 4
            #expect(
                Set(Self.handCards(state, seat)) == Set([CardID(UInt16(from * 13)), CardID(UInt16(from * 13 + 1))]))
        }
    }

    @Test func directPassLandsImmediatelyAndRevealsAll() throws {
        let engine = Self.passEngine(count: "1", via: nil, simultaneous: false, revealTo: "all")
        let started = try engine.start(seed: 5)
        var state = started.state
        state = try engine.apply(
            Action(seat: Seat(1), intent: .play(CardID(13)), expectedVersion: state.version), to: state
        ).state
        // Without a staging zone the pick lands with its target at once,
        // and `all` tells every seat.
        for seat in 0...3 {
            #expect(state.knowledge.knows(CardID(13), Seat(seat)))
        }
        for seat in [0, 2, 3] {
            state = try engine.apply(
                Action(
                    seat: Seat(seat), intent: .play(CardID(UInt16(seat * 13))),
                    expectedVersion: state.version), to: state
            ).state
        }
        #expect(state.phase.phaseID == "done")
        for seat in 0...3 {
            #expect(Self.handCards(state, seat) == [CardID(UInt16(((seat + 3) % 4) * 13))])
        }
    }

    @Test func zeroCountPassCompletesWithoutPicks() throws {
        let engine = Self.passEngine(count: "0", via: "pass", simultaneous: true, revealTo: "nobody")
        let started = try engine.start(seed: 9)
        #expect(started.state.phase.phaseID == "done")
        for seat in 0...3 {
            #expect(Self.handCards(started.state, seat) == [CardID(UInt16(seat * 13))])
        }
    }

    @Test func passFaultsOnBadCountOrRevealTo() {
        let negative = Self.passEngine(count: "-3", via: "pass", simultaneous: true, revealTo: "nobody")
        #expect(throws: RuleViolation.self) { try negative.start(seed: 1) }
        let unknownReveal = Self.passEngine(count: "1", via: "pass", simultaneous: true, revealTo: "everyone")
        #expect(throws: RuleViolation.self) { try unknownReveal.start(seed: 1) }
    }

    @Test func passRejectsBadIntents() throws {
        let engine = Self.passEngine(count: "1", via: "pass", simultaneous: true, revealTo: "nobody")
        let started = try engine.start(seed: 2)
        let state = started.state
        // Only .play intents stage cards.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .call("pass"), expectedVersion: state.version), to: state)
        }
        // The card must come from the passer's own `from` zone.
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(13)), expectedVersion: state.version), to: state)
        }
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(999)), expectedVersion: state.version), to: state)
        }
        // Staging every staged card empties the seat's pending queue.
        let staged = try engine.apply(
            Action(seat: Seat(0), intent: .play(CardID(0)), expectedVersion: state.version), to: state)
        #expect(throws: RuleViolation.self) {
            try engine.apply(
                Action(seat: Seat(0), intent: .play(CardID(13)), expectedVersion: staged.state.version),
                to: staged.state)
        }
    }
}
