// Unit tests for KnowledgeStore, VarStore, VarPath, ZoneStore edge paths,
// SeededRNG helpers, DealMechanic fault paths, and Redactor event/zone paths
// (complements the property suites; supports the G1 coverage gate).

import CardModel
import Testing
import Foundation
@testable import RulesEngine
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) import ToyGame

struct KnowledgeStoreTests {
    @Test func revealAndViewers() {
        var k = KnowledgeStore()
        let id = CardID(7)
        #expect(!k.knows(id, Seat(0)))
        k.reveal(id, to: SeatSet(Seat(0)))
        #expect(k.knows(id, Seat(0)))
        #expect(!k.knows(id, Seat(1)))
        #expect(k.viewers(of: id).contains(Seat(0)))
        #expect(!k.viewers(of: id).contains(Seat(1)))
        #expect(!k.isPublic(id))
        k.makePublic(id)
        #expect(k.isPublic(id))
        #expect(k.viewers(of: id).bits == UInt64.max)
        #expect(k.viewers(of: CardID(8)).bits == 0) // unknown card
    }

    @Test func canonicalCodableRoundTrip() throws {
        var k = KnowledgeStore()
        k.reveal(CardID(9), to: SeatSet(Seat(2)))
        k.makePublic(CardID(3))
        let data = try JSONEncoder().encode(k)
        let back = try JSONDecoder().decode(KnowledgeStore.self, from: data)
        #expect(back == k)
        // Keys emitted in ascending order: {"known": [[3,mask],[9,mask]]}.
        let text = String(data: data, encoding: .utf8)!
        let three = text.range(of: "[[3,")
        let nine = text.range(of: "],[9,")
        #expect(three != nil && nine != nil)
        #expect(three!.lowerBound < nine!.lowerBound)
    }
}

struct VarStoreTests {
    @Test func declareSetGetAdd() {
        var store = VarStore()
        store.declare("score", VarDecl(scope: .match, initial: .int(0)))
        #expect(!store.isHidden("score"))
        let matchScore = VarPath("score")
        #expect(store.get(matchScore) == nil) // declared but unset
        store.set(matchScore, .int(5))
        #expect(store.get(matchScore) == .int(5))
        store.add(matchScore, 3)
        #expect(store.get(matchScore) == .int(8))
        // add on an unset variable starts from the delta.
        store.add(VarPath("fresh"), 2)
        #expect(store.get(VarPath("fresh")) == .int(2))
        // type mismatch is ignored in P1.
        store.add(matchScore, 1) // fine
        store.set(VarPath("text"), .string("x"))
        store.add(VarPath("text"), 1)
        #expect(store.get(VarPath("text")) == .string("x"))
    }

    @Test func hiddenDeclaration() {
        var store = VarStore()
        store.declare("tell", VarDecl(scope: .seatMatch, isHidden: true, initial: .bool(false)))
        #expect(store.isHidden("tell"))
        #expect(!store.isHidden("score"))
    }

    @Test func seatScopedStorageKeys() {
        #expect(VarPath("lead", 2).storageKey == "lead@2")
        #expect(VarPath("lead").storageKey == "lead")
        let back = VarPath(storageKey: "lead@2")
        #expect(back.name == "lead" && back.index == 2)
        let bare = VarPath(storageKey: "tricks")
        #expect(bare.name == "tricks" && bare.index == nil)
        // Seat-scoped vars are distinct storage slots.
        var store = VarStore()
        store.set(VarPath("hand", 0), .int(1))
        store.set(VarPath("hand", 1), .int(2))
        #expect(store.get(VarPath("hand", 0)) == .int(1))
        #expect(store.get(VarPath("hand", 1)) == .int(2))
    }

    @Test func codableRoundTrip() throws {
        var store = VarStore()
        store.set(VarPath("score"), .int(4))
        store.set(VarPath("tell", 1), .seat(Seat(1)))
        store.declare("tell", VarDecl(scope: .seatDeal, isHidden: true, initial: .bool(false)))
        let data = try JSONEncoder().encode(store)
        let back = try JSONDecoder().decode(VarStore.self, from: data)
        #expect(back == store)
    }
}

struct ZoneStoreEdgeTests {
    private func deck(_ count: UInt16) -> [CardInstance] {
        (0..<count).map { CardInstance(id: CardID($0), face: CardFace(suit: .spades, rank: .ace)) }
    }

    @Test func batchMove() throws(ZoneStoreError) {
        var z = ZoneStore()
        z.declare(ZoneKey(scope: .shared, id: "a"))
        z.declare(ZoneKey(scope: .shared, id: "b"))
        for c in deck(3) { try z.place(c, in: ZoneKey(scope: .shared, id: "a")) }
        try z.move([CardID(0), CardID(1), CardID(2)], from: ZoneKey(scope: .shared, id: "a"), to: ZoneKey(scope: .shared, id: "b"))
        #expect(z.cards(in: ZoneKey(scope: .shared, id: "a")).isEmpty)
        #expect(z.cards(in: ZoneKey(scope: .shared, id: "b")).count == 3)
        #expect(z.zoneOf(CardID(1))?.id == "b")
    }

    @Test func placeCapacityFull() {
        var z = ZoneStore()
        let shared = ZoneKey(scope: .shared, id: "full")
        z.declare(shared, capacity: 1)
        try? z.place(deck(1)[0], in: shared)
        #expect(throws: ZoneStoreError.destinationFull(shared)) {
            try z.place(deck(2)[1], in: shared)
        }
    }

    @Test func placeRemovesFromPreviousZone() throws(ZoneStoreError) {
        var z = ZoneStore()
        let a = ZoneKey(scope: .shared, id: "a")
        let b = ZoneKey(scope: .shared, id: "b")
        z.declare(a)
        z.declare(b)
        let cards = deck(2)
        try z.place(cards[0], in: a)
        try z.place(cards[0], in: b) // moves it: conservation holds
        #expect(z.cards(in: a).isEmpty)
        #expect(z.cards(in: b).count == 1)
        #expect(z.zoneOf(cards[0].id)?.id == "b")
    }

    @Test func popTopEdges() throws {
        var z = ZoneStore()
        let empty = ZoneKey(scope: .shared, id: "empty")
        z.declare(empty)
        var poppedSomething = false
        do {
            poppedSomething = try z.popTop(from: empty) != nil // declared + empty → nil
        } catch {
            Issue.record("unexpected throw: \(error)")
        }
        #expect(!poppedSomething)
        do {
            _ = try z.popTop(from: ZoneKey(scope: .shared, id: "nope"))
            Issue.record("expected throw for undeclared zone")
        } catch {
            _ = error // expected: undeclared zone
        }
    }

    @Test func shuffleZoneAndQueries() throws(ZoneStoreError) {
        var z = ZoneStore()
        let shared = ZoneKey(scope: .shared, id: "pile")
        z.declare(shared)
        for c in deck(5) { try z.place(c, in: shared) }
        var rng = SeededRNG(seed: 99)
        z.shuffleZone(shared, using: &rng)
        #expect(z.allInstances.count == 5)
        #expect(z.zones[shared]?.count == 5)
        z.shuffleZone(ZoneKey(scope: .shared, id: "absent"), using: &rng) // no-op
        z.shuffleZone(shared, using: &rng) // count 5 still fine
    }

    @Test func codableRoundTrip() throws {
        var z = ZoneStore()
        let shared = ZoneKey(scope: .shared, id: "pile")
        z.declare(shared, capacity: 10)
        for c in deck(3) { try z.place(c, in: shared) }
        let data = try JSONEncoder().encode(z)
        let back = try JSONDecoder().decode(ZoneStore.self, from: data)
        #expect(back == z)
        #expect(back.zoneOf(CardID(2))?.id == "pile")
    }
}

struct SeededRNGHelperTests {
    @Test func allZeroStateGuard() {
        var rng = SeededRNG(s0: 0, s1: 0, s2: 0, s3: 0)
        // The guard prevents an all-zero state (stuck at zero forever); the
        // first outputs from [0,0,0,1] are 0 but the state must not stay zero.
        var sawNonZero = false
        for _ in 0..<8 {
            if rng.nextUInt64() != 0 { sawNonZero = true }
        }
        #expect(sawNonZero)
    }

    @Test func dealSeedAndSplitMixDerive() {
        let a = SeededRNG.dealSeed(sessionSeed: 42, index: 0)
        let b = SeededRNG.dealSeed(sessionSeed: 42, index: 1)
        #expect(a != b)
        #expect(a == SeededRNG.dealSeed(sessionSeed: 42, index: 0)) // deterministic
    }

    @Test func belowIntAndInRange() {
        var rng = SeededRNG(seed: 7)
        var sawMax = false
        var sawMin = false
        for _ in 0..<1_000 {
            let v = rng.below(6)
            #expect(v >= 0 && v < 6)
            let r = rng.in(3..<9)
            #expect(r >= 3 && r < 9)
            sawMax = sawMax || r == 8
            sawMin = sawMin || r == 3
        }
        #expect(sawMax && sawMin)
    }

    @Test func belowRejectionLoop() {
        var rng = SeededRNG(seed: 1234)
        // bound = 2^63+1 puts the rejection threshold at 2^63-1: about half
        // the first draws take the rejection/re-draw branch. Rejection is
        // transparent by design, so only the output range is observable.
        let bound = (UInt64(1) << 63) + 1
        for _ in 0..<2_000 {
            #expect(rng.below(bound) < bound)
        }
    }

    @Test func shuffledArray() {
        var rng = SeededRNG(seed: 5)
        let original = Array(0..<10)
        let shuffled = rng.shuffled(original)
        #expect(shuffled.sorted() == original)
        #expect(shuffled != original) // 10! to 1 against identity
        let single = rng.shuffled([1])
        #expect(single == [1])
        let empty = rng.shuffled([] as [Int])
        #expect(empty.isEmpty)
    }
}

struct DealMechanicEdgeTests {
    private func context() -> (GameState, EvalContext) {
        let state = GameState(rng: SeededRNG(seed: 11))
        return (state, EvalContext(seatCount: 2))
    }

    @Test func exhaustedSourceThrows() {
        let (state, ctx) = context()
        var s = state
        let params = DealParams(
            source: "stock",
            packets: [DealPacket(to: Seat(0), each: 3)],
            shuffleFirst: false,
            deckFaces: [CardFace(suit: .hearts, rank: .two), CardFace(suit: .hearts, rank: .three)]
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
            packets: [DealPacket(to: Seat(0), each: 2), DealPacket(to: Seat(1), each: 2, faceUp: true)],
            shuffleFirst: false,
            cutDepth: 1,
            deckFaces: [
                CardFace(suit: .hearts, rank: .two),
                CardFace(suit: .hearts, rank: .three),
                CardFace(suit: .hearts, rank: .four),
                CardFace(suit: .hearts, rank: .five)
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

    @Test func dealIsAutomatic() throws {
        let (_, ctx) = context()
        #expect(DealMechanic.legalIntents(DealParams(source: "stock", packets: [], shuffleFirst: false), state: GameState(rng: SeededRNG(seed: 1)), seat: Seat(0), ctx: ctx).isEmpty)
        #expect(DealMechanic.pendingSeats(DealParams(source: "stock", packets: [], shuffleFirst: false), state: GameState(rng: SeededRNG(seed: 1)), ctx: ctx).bits == 0)
        #expect(DealMechanic.isComplete(DealParams(source: "stock", packets: [], shuffleFirst: false), state: GameState(rng: SeededRNG(seed: 1)), ctx: ctx) == .complete)
        var s = GameState(rng: SeededRNG(seed: 1))
        #expect(throws: RuleViolation.self) {
            _ = try DealMechanic.apply(DealParams(source: "stock", packets: [], shuffleFirst: false), intent: .confirm, by: Seat(0), state: &s, ctx: ctx)
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
        var k = KnowledgeStore()
        k.makePublic(CardID(1)) // card 1 is public knowledge
        return k
    }

    @Test func maySeeViewerKinds() {
        let k = knowledge
        let hidden = CardID(2)
        #expect(Redactor.maySee(hidden, viewer: .replayAll, knowledge: k, publicCard: false))
        #expect(!Redactor.maySee(hidden, viewer: .table, knowledge: k, publicCard: false))
        #expect(Redactor.maySee(hidden, viewer: .table, knowledge: k, publicCard: true))
        #expect(!Redactor.maySee(hidden, viewer: .spectator, knowledge: k, publicCard: false))
        #expect(!Redactor.maySee(hidden, viewer: .seat(Seat(0)), knowledge: k, publicCard: false))
        #expect(!Redactor.maySee(hidden, viewer: .coachOf(Seat(0)), knowledge: k, publicCard: false))
        #expect(Redactor.maySee(CardID(1), viewer: .spectator, knowledge: k, publicCard: false)) // public via knowledge
    }

    @Test func eventRedactionCases() {
        let k = knowledge
        let cards = [instance(1), instance(2)] // 1 public, 2 hidden
        // dealt to another seat: only public cards survive
        if case .dealt(_, let out) = Redactor.redact(.dealt(to: Seat(1), cards: cards), viewer: .seat(Seat(0)), knowledge: k) {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected dealt event")
        }
        // dealt to me: full hand
        if case .dealt(_, let out) = Redactor.redact(.dealt(to: Seat(0), cards: cards), viewer: .seat(Seat(0)), knowledge: k) {
            #expect(out.count == 2)
        } else {
            Issue.record("expected dealt event")
        }
        // passed: involved seat sees all, stranger sees only public
        if case .passed(_, _, let out) = Redactor.redact(.passed(from: Seat(0), to: Seat(1), cards: cards), viewer: .seat(Seat(1)), knowledge: k) {
            #expect(out.count == 2)
        } else {
            Issue.record("expected passed event")
        }
        if case .passed(_, _, let out) = Redactor.redact(.passed(from: Seat(0), to: Seat(1), cards: cards), viewer: .seat(Seat(2)), knowledge: k) {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected passed event")
        }
        // trickWon and revealed filter hidden faces
        if case .trickWon(_, let out) = Redactor.redact(.trickWon(seat: Seat(0), cards: cards), viewer: .spectator, knowledge: k) {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected trickWon event")
        }
        if case .revealed(_, let out) = Redactor.redact(.revealed(zone: "table", cards: cards), viewer: .spectator, knowledge: k) {
            #expect(out.map(\.id.raw) == [1])
        } else {
            Issue.record("expected revealed event")
        }
        // cardPlayed and non-card events pass through unchanged
        #expect(Redactor.redact(.cardPlayed(seat: Seat(0), card: instance(2)), viewer: .spectator, knowledge: k) == .cardPlayed(seat: Seat(0), card: instance(2)))
        #expect(Redactor.redact(.dealEnded, viewer: .spectator, knowledge: k) == .dealEnded)
    }

    @Test func zoneRedactionWrapper() {
        var k = KnowledgeStore()
        k.makePublic(CardID(1)) // card 1 is public knowledge
        // No knowledge about card 2: hidden everywhere, even a shared zone.
        let redacted = Redactor.redact([instance(1), instance(2)], key: ZoneKey(scope: .shared, id: "trick"), viewer: .spectator, knowledge: k)
        if case .hidden(let count, let known) = redacted {
            #expect(count == 2)
            #expect(known.map(\.id.raw) == [1])
        } else {
            Issue.record("expected hidden zone")
        }
        // Once the mechanic makes card 2 public, the zone shows everything.
        k.makePublic(CardID(2))
        let revealed = Redactor.redact([instance(1), instance(2)], key: ZoneKey(scope: .shared, id: "trick"), viewer: .spectator, knowledge: k)
        if case .visible(let cards) = revealed {
            #expect(cards.map(\.id.raw) == [1, 2])
        } else {
            Issue.record("expected visible zone")
        }
        // Another player's hand: count plus already-known faces only.
        var fresh = KnowledgeStore()
        fresh.makePublic(CardID(1))
        let hand = Redactor.redact([instance(1), instance(2)], key: ZoneKey(scope: .seat, owner: 1, id: "hand"), viewer: .spectator, knowledge: fresh)
        if case .hidden(let count, let known) = hand {
            #expect(count == 2)
            #expect(known.map(\.id.raw) == [1]) // public card survives
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
        #expect(String(data: data, encoding: .utf8)!.contains("count"))
        #expect(!String(data: data, encoding: .utf8)!.contains("known"))
    }
}
