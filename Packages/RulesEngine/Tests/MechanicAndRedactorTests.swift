// Unit tests for DealMechanic fault paths and Redactor event/zone paths
// (complements the property suites; supports the G1 coverage gate).

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

struct DealMechanicEdgeTests {
    private func context() -> (GameState, EvalContext) {
        let state = GameState(rng: SeededRNG(seed: 11))
        return (state, EvalContext(seatCount: 2))
    }

    private func context(eval: @escaping @Sendable (EvalCall, GameState) throws(EvalFailure) -> EvalValue)
        -> (GameState, EvalContext)
    {
        let state = GameState(rng: SeededRNG(seed: 11))
        return (state, EvalContext(seatCount: 2, eval: eval))
    }

    @Test func exhaustedSourceThrows() {
        let (state, ctx) = context()
        var s = state
        let params = DealParams(
            source: "stock",
            packets: [DealPacket(to: Seat(0), each: 3)],
            shuffleFirst: false,
            deckFaces: [
                CardFace(suit: .hearts, rank: .two),
                CardFace(suit: .hearts, rank: .three),
            ]
        )
        #expect(throws: RuleViolation.self) {
            _ = try DealMechanic.enter(params, state: &s, ctx: ctx)
        }
    }

    @Test func cutDepthAndFaceUpReveal() throws {
        let (state, ctx) = context()
        var s = state
        let params = DealParams(
            source: "stock",
            packets: [
                DealPacket(to: Seat(0), each: 2),
                DealPacket(to: Seat(1), each: 2, faceUp: true),
            ],
            shuffleFirst: false,
            cutDepth: 1,
            deckFaces: [
                CardFace(suit: .hearts, rank: .two),
                CardFace(suit: .hearts, rank: .three),
                CardFace(suit: .hearts, rank: .four),
                CardFace(suit: .hearts, rank: .five),
            ]
        )
        let events = try DealMechanic.enter(params, state: &s, ctx: ctx)
        #expect(events.count == 2)
        // Face-up packet: everyone knows those faces.
        let seat1Hand = s.zones.cards(in: ZoneKey(scope: .seat, owner: 1, id: "hand"))
        #expect(seat1Hand.count == 2)
        for card in seat1Hand {
            #expect(s.knowledge.viewers(of: card.id).contains(Seat(0)))
        }
        // Face-down packet: only the owner knows.
        let seat0Hand = s.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "hand"))
        for card in seat0Hand {
            #expect(s.knowledge.viewers(of: card.id).contains(Seat(0)))
            #expect(!s.knowledge.viewers(of: card.id).contains(Seat(1)))
        }
    }

    @Test func shuffleFirstShufflesDeterministically() throws {
        func dealt(seed: UInt64, shuffle: Bool) throws -> [String] {
            var s = GameState(rng: SeededRNG(seed: seed))
            let params = DealParams(
                source: "stock",
                packets: [DealPacket(to: Seat(0), each: 2), DealPacket(to: Seat(1), each: 2)],
                shuffleFirst: shuffle,
                deckFaces: [
                    CardFace(suit: .hearts, rank: .two),
                    CardFace(suit: .hearts, rank: .three),
                    CardFace(suit: .hearts, rank: .four),
                    CardFace(suit: .hearts, rank: .five),
                ]
            )
            _ = try DealMechanic.enter(params, state: &s, ctx: EvalContext(seatCount: 2))
            return
                (s.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "hand"))
                + s.zones.cards(in: ZoneKey(scope: .seat, owner: 1, id: "hand")))
                .map { $0.face.id }
        }
        // Unshuffled deals land in a fixed deck order; the seeded shuffle
        // is reproducible per seed and reorders for some seed.
        let ordered = try dealt(seed: 5, shuffle: false)
        #expect(ordered.count == 4)
        let shuffledOnce = try dealt(seed: 5, shuffle: true)
        let shuffledAgain = try dealt(seed: 5, shuffle: true)
        #expect(shuffledOnce == shuffledAgain)
        #expect(shuffledOnce.count == 4)
        var sawReorder = false
        for seed in UInt64(0)..<40 where try dealt(seed: seed, shuffle: true) != ordered {
            sawReorder = true
        }
        #expect(sawReorder)
    }

    @Test func dealIsAutomatic() throws {
        let (_, ctx) = context()
        #expect(
            DealMechanic.legalIntents(
                DealParams(source: "stock", packets: [], shuffleFirst: false),
                state: GameState(rng: SeededRNG(seed: 1)), seat: Seat(0), ctx: ctx
            ).isEmpty)
        #expect(
            DealMechanic.pendingSeats(
                DealParams(source: "stock", packets: [], shuffleFirst: false),
                state: GameState(rng: SeededRNG(seed: 1)), ctx: ctx
            ).bits == 0)
        #expect(
            DealMechanic.isComplete(
                DealParams(source: "stock", packets: [], shuffleFirst: false),
                state: GameState(rng: SeededRNG(seed: 1)), ctx: ctx) == .complete)
        var s = GameState(rng: SeededRNG(seed: 1))
        #expect(throws: RuleViolation.self) {
            _ = try DealMechanic.apply(
                DealParams(source: "stock", packets: [], shuffleFirst: false),
                intent: .confirm, by: Seat(0), state: &s, ctx: ctx)
        }
    }

    /// Expression `each` overrides the fixed count at deal time (§5.6).
    @Test func expressionEachResolvesAtDealTime() throws {
        let (state, ctx) = context { _, _ in .int(3) }
        var s = state
        let hand0 = ZoneKey(scope: .seat, owner: 0, id: "hand")
        let hand1 = ZoneKey(scope: .seat, owner: 1, id: "hand")
        let params = DealParams(
            source: "stock",
            packets: [
                DealPacket(to: hand0, each: 0, eachExpr: DealCountExpr(source: "3", pointer: "/0/each")),
                DealPacket(to: hand1, each: 0, eachExpr: DealCountExpr(source: "3", pointer: "/1/each")),
            ],
            shuffleFirst: false,
            deckFaces: [
                CardFace(suit: .hearts, rank: .two),
                CardFace(suit: .hearts, rank: .three),
                CardFace(suit: .hearts, rank: .four),
                CardFace(suit: .hearts, rank: .five),
                CardFace(suit: .hearts, rank: .six),
                CardFace(suit: .hearts, rank: .seven),
            ]
        )
        let events = try DealMechanic.enter(params, state: &s, ctx: ctx)
        #expect(events.count == 2)
        #expect(s.zones.cards(in: hand0).count == 3)
        #expect(s.zones.cards(in: hand1).count == 3)
    }

    /// Expression `count` overrides `each * packets` at deal time.
    @Test func expressionCountOverridesEach() throws {
        let (state, ctx) = context { _, _ in .int(2) }
        var s = state
        let hand0 = ZoneKey(scope: .seat, owner: 0, id: "hand")
        let hand1 = ZoneKey(scope: .seat, owner: 1, id: "hand")
        let params = DealParams(
            source: "stock",
            packets: [
                DealPacket(to: hand0, each: 10, packets: 5, countExpr: DealCountExpr(source: "2", pointer: "/0/count")),
                DealPacket(to: hand1, each: 10, packets: 5, countExpr: DealCountExpr(source: "2", pointer: "/1/count")),
            ],
            shuffleFirst: false,
            deckFaces: (2..<6).map { i in CardFace(suit: .hearts, rank: .two) }
        )
        let events = try DealMechanic.enter(params, state: &s, ctx: ctx)
        #expect(events.count == 2)
        #expect(s.zones.cards(in: hand0).count == 2)
        #expect(s.zones.cards(in: hand1).count == 2)
    }

    /// A non-integer expression count is an engine fault with the JSON pointer.
    @Test func nonIntegerCountExpressionFaults() {
        let (state, ctx) = context { _, _ in .string("x") }
        var s = state
        let hand = ZoneKey(scope: .seat, owner: 0, id: "hand")
        let params = DealParams(
            source: "stock",
            packets: [DealPacket(to: hand, each: 0, eachExpr: DealCountExpr(source: "\"x\"", pointer: "/0/each"))],
            shuffleFirst: false,
            deckFaces: [CardFace(suit: .hearts, rank: .two)]
        )
        #expect(throws: RuleViolation.self) {
            _ = try DealMechanic.enter(params, state: &s, ctx: ctx)
        }
    }

    /// A negative expression count is an engine fault.
    @Test func negativeCountExpressionFaults() {
        let (state, ctx) = context { _, _ in .int(-1) }
        var s = state
        let hand = ZoneKey(scope: .seat, owner: 0, id: "hand")
        let params = DealParams(
            source: "stock",
            packets: [DealPacket(to: hand, each: 0, eachExpr: DealCountExpr(source: "-1", pointer: "/0/each"))],
            shuffleFirst: false,
            deckFaces: [CardFace(suit: .hearts, rank: .two)]
        )
        #expect(throws: RuleViolation.self) {
            _ = try DealMechanic.enter(params, state: &s, ctx: ctx)
        }
    }

    /// Deal with no expression runtime installed faults on expression count.
    @Test func dealCountWithoutRuntimeFaults() {
        let (state, ctx) = context()
        var s = state
        let hand = ZoneKey(scope: .seat, owner: 0, id: "hand")
        let params = DealParams(
            source: "stock",
            packets: [DealPacket(to: hand, each: 0, eachExpr: DealCountExpr(source: "3", pointer: "/0/each"))],
            shuffleFirst: false,
            deckFaces: [CardFace(suit: .hearts, rank: .two)]
        )
        #expect(throws: RuleViolation.self) {
            _ = try DealMechanic.enter(params, state: &s, ctx: ctx)
        }
    }

    @Test func allSeatsHelper() {
        let set = SeatSet.allSeats(3)
        #expect(set.contains(Seat(0)) && set.contains(Seat(2)))
        #expect(!set.contains(Seat(3)))
    }
}

struct RedactorUnitTests {
    private func instance(_ raw: UInt16) -> CardInstance {
        CardInstance(id: CardID(raw), face: CardFace(suit: .clubs, rank: .queen))
    }

    private var knowledge: KnowledgeStore {
        var ks = KnowledgeStore()
        ks.makePublic(CardID(1))  // card 1 is public knowledge
        return ks
    }

    @Test func maySeeViewerKinds() {
        let ks = knowledge
        let hidden = CardID(2)
        #expect(Redactor.maySee(hidden, viewer: .replayAll, knowledge: ks, publicCard: false))
        #expect(!Redactor.maySee(hidden, viewer: .table, knowledge: ks, publicCard: false))
        #expect(Redactor.maySee(hidden, viewer: .table, knowledge: ks, publicCard: true))
        #expect(!Redactor.maySee(hidden, viewer: .spectator, knowledge: ks, publicCard: false))
        #expect(!Redactor.maySee(hidden, viewer: .seat(Seat(0)), knowledge: ks, publicCard: false))
        #expect(
            !Redactor.maySee(hidden, viewer: .coachOf(Seat(0)), knowledge: ks, publicCard: false))
        // Public via knowledge: a spectator may see card 1.
        #expect(Redactor.maySee(CardID(1), viewer: .spectator, knowledge: ks, publicCard: false))
    }

    @Test func eventRedactionDealt() {
        let ks = knowledge
        let cards = [instance(1), instance(2)]  // 1 public, 2 hidden
        // dealt to another seat: only public cards survive
        let r0 = Redactor.redact(
            .dealt(to: Seat(1), cards: cards),
            viewer: .seat(Seat(0)), knowledge: ks)
        if case .dealt(_, let out) = r0 {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected dealt event")
        }
        // dealt to me: full hand
        let r1 = Redactor.redact(
            .dealt(to: Seat(0), cards: cards),
            viewer: .seat(Seat(0)), knowledge: ks)
        if case .dealt(_, let out) = r1 {
            #expect(out.count == 2)
        } else {
            Issue.record("expected dealt event")
        }
    }

    @Test func eventRedactionOther() {
        let ks = knowledge
        let cards = [instance(1), instance(2)]  // 1 public, 2 hidden
        // passed: involved seat sees all, stranger sees only public
        let r2 = Redactor.redact(
            .passed(from: Seat(0), to: Seat(1), cards: cards),
            viewer: .seat(Seat(1)), knowledge: ks)
        if case .passed(_, _, let out) = r2 {
            #expect(out.count == 2)
        } else {
            Issue.record("expected passed event")
        }
        let r3 = Redactor.redact(
            .passed(from: Seat(0), to: Seat(1), cards: cards),
            viewer: .seat(Seat(2)), knowledge: ks)
        if case .passed(_, _, let out) = r3 {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected passed event")
        }
        // trickWon and revealed filter hidden faces
        let r4 = Redactor.redact(
            .trickWon(seat: Seat(0), cards: cards),
            viewer: .spectator, knowledge: ks)
        if case .trickWon(_, let out) = r4 {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected trickWon event")
        }
        let r5 = Redactor.redact(
            .revealed(zone: "table", cards: cards),
            viewer: .spectator, knowledge: ks)
        if case .revealed(_, let out) = r5 {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected revealed event")
        }
        // cardPlayed and non-card events pass through unchanged
        #expect(
            Redactor.redact(
                .cardPlayed(seat: Seat(0), card: instance(2)),
                viewer: .spectator, knowledge: ks)
                == .cardPlayed(seat: Seat(0), card: instance(2)))
        #expect(Redactor.redact(.dealEnded, viewer: .spectator, knowledge: ks) == .dealEnded)
    }

    @Test func zoneRedactionWrapper() {
        var ks = knowledge
        // No knowledge about card 2: hidden everywhere, even a shared zone.
        let redacted = Redactor.redact(
            [instance(1), instance(2)],
            key: ZoneKey(scope: .shared, id: "trick"), viewer: .spectator, knowledge: ks)
        if case .hidden(let count, let known) = redacted {
            #expect(count == 2)
            #expect(known.map(\.id.raw) == [1])
        } else {
            Issue.record("expected hidden zone")
        }
        // Once the mechanic makes card 2 public, the zone shows everything.
        ks.makePublic(CardID(2))
        let revealed = Redactor.redact(
            [instance(1), instance(2)],
            key: ZoneKey(scope: .shared, id: "trick"), viewer: .spectator, knowledge: ks)
        if case .visible(let cards) = revealed {
            #expect(cards.map(\.id.raw) == [1, 2])
        } else {
            Issue.record("expected visible zone")
        }
        // Another player's hand: count plus already-known faces only
        // (fresh knowledge: card 2 is unknown here again).
        var fresh = KnowledgeStore()
        fresh.makePublic(CardID(1))
        let hand = Redactor.redact(
            [instance(1), instance(2)],
            key: ZoneKey(scope: .seat, owner: 1, id: "hand"), viewer: .spectator, knowledge: fresh)
        if case .hidden(let count, let known) = hand {
            #expect(count == 2)
            #expect(known.map(\.id.raw) == [1])  // public card survives
        } else {
            Issue.record("expected hidden zone")
        }
    }

    @Test func observedZoneCodableBothCases() throws {
        let visible = ObservedZone.visible([instance(3)])
        let hidden = ObservedZone.hidden(count: 4, known: [instance(1)])
        for zone in [visible, hidden] {
            let data = try JSONEncoder().encode(zone)
            let back = try JSONDecoder().decode(ObservedZone.self, from: data)
            #expect(back == zone)
        }
        // hidden with no known cards omits the known key.
        let data = try JSONEncoder().encode(ObservedZone.hidden(count: 2, known: []))
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("count"))
        #expect(!text.contains("known"))
    }
}
