// Unit tests for KnowledgeStore, VarStore, VarPath, ZoneStore edge paths,
// and SeededRNG helpers (complements the property suites; supports the
// G1 coverage gate).

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

struct KnowledgeStoreTests {
    @Test func revealAndViewers() {
        var store = KnowledgeStore()
        let id = CardID(7)
        #expect(!store.knows(id, Seat(0)))
        store.reveal(id, to: SeatSet(Seat(0)))
        #expect(store.knows(id, Seat(0)))
        #expect(!store.knows(id, Seat(1)))
        #expect(store.viewers(of: id).contains(Seat(0)))
        #expect(!store.viewers(of: id).contains(Seat(1)))
        #expect(!store.isPublic(id))
        store.makePublic(id)
        #expect(store.isPublic(id))
        #expect(store.viewers(of: id).bits == UInt64.max)
        #expect(store.viewers(of: CardID(8)).bits == 0)  // unknown card
    }

    @Test func canonicalCodableRoundTrip() throws {
        var store = KnowledgeStore()
        store.reveal(CardID(9), to: SeatSet(Seat(2)))
        store.makePublic(CardID(3))
        let data = try JSONEncoder().encode(store)
        let back = try JSONDecoder().decode(KnowledgeStore.self, from: data)
        #expect(back == store)
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
        #expect(store.get(matchScore) == nil)  // declared but unset
        store.set(matchScore, .int(5))
        #expect(store.get(matchScore) == .int(5))
        store.add(matchScore, 3)
        #expect(store.get(matchScore) == .int(8))
        // add on an unset variable starts from the delta.
        store.add(VarPath("fresh"), 2)
        #expect(store.get(VarPath("fresh")) == .int(2))
        // type mismatch is ignored in P1.
        store.add(matchScore, 1)  // fine
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

    @Test func seatScopedStorageKeys() throws {
        // Seat-scoped vars are distinct storage slots.
        var store = VarStore()
        store.set(VarPath("hand", 0), .int(1))
        store.set(VarPath("hand", 1), .int(2))
        #expect(store.get(VarPath("hand", 0)) == .int(1))
        #expect(store.get(VarPath("hand", 1)) == .int(2))
        // Canonical storage key "name@index" is observable in the JSON encoding.
        let text = String(data: try JSONEncoder().encode(store), encoding: .utf8)!
        #expect(text.contains("\"hand@0\""))
        #expect(text.contains("\"hand@1\""))
        #expect(!text.contains("\"hand\""))
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
        for card in deck(3) { try z.place(card, in: ZoneKey(scope: .shared, id: "a")) }
        try z.move(
            [CardID(0), CardID(1), CardID(2)], from: ZoneKey(scope: .shared, id: "a"),
            to: ZoneKey(scope: .shared, id: "b"))
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
        let zoneA = ZoneKey(scope: .shared, id: "a")
        let zoneB = ZoneKey(scope: .shared, id: "b")
        z.declare(zoneA)
        z.declare(zoneB)
        let cards = deck(2)
        try z.place(cards[0], in: zoneA)
        try z.place(cards[0], in: zoneB)  // moves it: conservation holds
        #expect(z.cards(in: zoneA).isEmpty)
        #expect(z.cards(in: zoneB).count == 1)
        #expect(z.zoneOf(cards[0].id)?.id == "b")
    }

    @Test func popTopEdges() throws {
        var z = ZoneStore()
        let empty = ZoneKey(scope: .shared, id: "empty")
        z.declare(empty)
        var poppedSomething = false
        do {
            poppedSomething = try z.popTop(from: empty) != nil  // declared + empty → nil
        } catch {
            Issue.record("unexpected throw: \(error)")
        }
        #expect(!poppedSomething)
        do {
            _ = try z.popTop(from: ZoneKey(scope: .shared, id: "nope"))
            Issue.record("expected throw for undeclared zone")
        } catch {
            _ = error  // expected: undeclared zone
        }
    }

    @Test func shuffleZoneAndQueries() throws(ZoneStoreError) {
        var z = ZoneStore()
        let shared = ZoneKey(scope: .shared, id: "pile")
        z.declare(shared)
        for card in deck(5) { try z.place(card, in: shared) }
        var rng = SeededRNG(seed: 99)
        z.shuffleZone(shared, using: &rng)
        #expect(z.allInstances.count == 5)
        #expect(z.zones[shared]?.count == 5)
        z.shuffleZone(ZoneKey(scope: .shared, id: "absent"), using: &rng)  // no-op
        z.shuffleZone(shared, using: &rng)  // count 5 still fine
    }

    @Test func codableRoundTrip() throws {
        var z = ZoneStore()
        let shared = ZoneKey(scope: .shared, id: "pile")
        z.declare(shared, capacity: 10)
        for card in deck(3) { try z.place(card, in: shared) }
        let data = try JSONEncoder().encode(z)
        let back = try JSONDecoder().decode(ZoneStore.self, from: data)
        #expect(back == z)
        #expect(back.zoneOf(CardID(2))?.id == "pile")
    }
}

struct SeededRNGHelperTests {
    @Test func allZeroStateGuard() {
        var rng = SeededRNG(lane0: 0, lane1: 0, lane2: 0, lane3: 0)
        // The guard prevents an all-zero state (stuck at zero forever); the
        // first outputs from [0,0,0,1] are 0 but the state must not stay zero.
        var sawNonZero = false
        let outputs = (0..<8).map { _ in rng.nextUInt64() }
        for output in outputs where output != 0 {
            sawNonZero = true
        }
        #expect(sawNonZero)
    }

    @Test func dealSeedAndSplitMixDerive() {
        let seedA = SeededRNG.dealSeed(sessionSeed: 42, index: 0)
        let seedB = SeededRNG.dealSeed(sessionSeed: 42, index: 1)
        #expect(seedA != seedB)
        #expect(seedA == SeededRNG.dealSeed(sessionSeed: 42, index: 0))  // deterministic
    }

    @Test func belowIntAndInRange() {
        var rng = SeededRNG(seed: 7)
        var sawMax = false
        var sawMin = false
        for _ in 0..<1_000 {
            let value = rng.below(6)
            #expect(value >= 0 && value < 6)
            let inRange = rng.in(3..<9)
            #expect(inRange >= 3 && inRange < 9)
            sawMax = sawMax || inRange == 8
            sawMin = sawMin || inRange == 3
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
        #expect(shuffled != original)  // 10! to 1 against identity
        let single = rng.shuffled([1])
        #expect(single == [1])
        let empty = rng.shuffled([] as [Int])
        #expect(empty.isEmpty)
    }
}
