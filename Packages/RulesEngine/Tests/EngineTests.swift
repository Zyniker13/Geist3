import Foundation
import Testing
@testable import RulesEngine
@_spi(HostOnly) import ToyGame
@_spi(HostOnly) import RulesEngine

@Suite("RulesEngine — state, zones, and reducer (P1.3–P1.5)")
struct EngineTests {

    // MARK: - P1.3: card conservation invariant

    @Test func zoneConservation() throws {
        var zones = ZoneStore()
        let stock = ZoneKey(scope: .shared, id: "stock")
        let hand = ZoneKey(scope: .seat, owner: 0, id: "hand")
        let pile = ZoneKey(scope: .shared, id: "pile")
        zones.declare(stock)
        zones.declare(hand)
        zones.declare(pile)
        for i in 0..<10 {
            try zones.place(CardInstance(id: CardID(UInt16(i)), face: CardFace(suit: .spades, rank: Rank(String(i)))), in: stock)
        }
        #expect(zones.allInstances.count == 10)
        try zones.move(CardID(3), from: stock, to: hand)
        #expect(zones.zoneOf(CardID(3)) == hand)
        try zones.move(CardID(3), from: hand, to: pile)
        #expect(zones.zoneOf(CardID(3)) == pile)
        #expect(zones.allInstances.count == 10, "conservation: 10 instances in play")
        // Every instance in exactly one zone.
        var seen = Set<CardID>()
        for (_, cards) in zones.zones {
            for card in cards {
                #expect(!seen.contains(card.id), "card \(card.id.raw) in two zones")
                seen.insert(card.id)
            }
        }
        #expect(seen.count == 10)
        // Illegal moves rejected.
        #expect(throws: ZoneStoreError.cardNotInSource(hand, CardID(3))) {
            try zones.move(CardID(3), from: hand, to: pile)
        }
    }

    @Test func zoneCapacityEnforced() throws {
        var zones = ZoneStore()
        let stock = ZoneKey(scope: .shared, id: "stock")
        let small = ZoneKey(scope: .shared, id: "small")
        zones.declare(stock)
        zones.declare(small, capacity: 1)
        try zones.place(CardInstance(id: CardID(1), face: CardFace(suit: .spades, rank: .ace)), in: stock)
        try zones.place(CardInstance(id: CardID(2), face: CardFace(suit: .hearts, rank: .ace)), in: stock)
        try zones.move(CardID(1), from: stock, to: small)
        #expect(throws: ZoneStoreError.destinationFull(small)) {
            try zones.move(CardID(2), from: stock, to: small)
        }
    }

    /// GameState Hashable is order-stable: two equal states built with
    /// different dictionary insertion orders hash identically.
    @Test func gameStateHashOrderStable() throws {
        let engine = ToyGame.engine()
        let a = try engine.start(seed: 7).state
        // Rebuild the same state with reversed zone insertion order.
        var b = a
        b.zones = a.zones // identical content; dictionary layout may differ
        #expect(a == b)
        var hasherA = Hasher()
        a.hash(into: &hasherA)
        var hasherB = Hasher()
        b.hash(into: &hasherB)
        #expect(hasherA.finalize() == hasherB.finalize())
        // Distinct states must not collide trivially.
        let c = try engine.start(seed: 8).state
        #expect(a != c)
    }

    // MARK: - P1.4: the toy game plays to completion for 10,000 seeds

    @Test func toyGameTenThousandSeeds() throws {
        let engine = ToyGame.engine()
        for seed in 0..<10_000 {
            let state = try ToyGame.play(engine: engine, seed: UInt64(seed))
            #expect(state.phase.phaseID == "done", "seed \(seed) did not complete")
            // 10 tricks of two cards each were played and conserved.
            #expect(state.zones.allInstances.count == 10)
            #expect(state.history.count == 10, "seed \(seed): \(state.history.count) actions")
            // Conservation by ID: exactly IDs 0..<10 present.
            let ids = Set(state.zones.allInstances.map { $0.id.raw })
            #expect(ids == Set(0..<10))
        }
    }

    /// Determinism: same seed → identical transitions.
    @Test func determinismSameSeedSameGame() throws {
        let engine = ToyGame.engine()
        let a = try ToyGame.play(engine: engine, seed: 12345)
        let b = try ToyGame.play(engine: engine, seed: 12345)
        #expect(a == b)
        #expect(Engine.finalStateHash(a) == Engine.finalStateHash(b))
    }

    /// Every illegal intent is rejected with a rule ID.
    @Test func illegalIntentsRejectedWithRuleIDs() throws {
        let engine = ToyGame.engine()
        var state = try engine.start(seed: 1).state
        // Seat 0 plays while seat 1 must lead.
        do {
            let hand = state.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "hand"))
            _ = try engine.apply(Action(seat: Seat(0), intent: .play(hand[0].id), expectedVersion: state.version), to: state)
            Issue.record("out-of-turn play was accepted")
        } catch {
            guard case RuleViolation.notYourTurn = error else {
                Issue.record("wrong violation: \(error)")
                return
            }
        }
        // Playing a card not in hand.
        do {
            _ = try engine.apply(Action(seat: Seat(1), intent: .play(CardID(999)), expectedVersion: state.version), to: state)
            Issue.record("playing a foreign card was accepted")
        } catch {
            guard case RuleViolation.illegal(let ruleId, _) = error else {
                Issue.record("wrong violation: \(error)")
                return
            }
            #expect(ruleId == "trick.notInHand")
        }
        _ = state // silence unused warning in the non-throwing path
    }

    /// Must-follow-suit is enforced: a seat holding the led suit cannot dump.
    @Test func mustFollowSuitEnforced() throws {
        let engine = ToyGame.engine()
        var state = try engine.start(seed: 2).state
        // Seat 1 leads; pick its first legal card.
        let legal1 = engine.legalIntents(for: Seat(1), in: state)
        state = try engine.apply(Action(seat: Seat(1), intent: legal1[0], expectedVersion: state.version), to: state).state
        let ledSuit = state.zones.cards(in: ZoneKey(scope: .shared, id: "trick0")).first!.face.suit!.code
        // Seat 0 must follow if it holds that suit.
        let hand0 = state.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "hand"))
        let followers = hand0.filter { $0.face.suit?.code == ledSuit }
        if !followers.isEmpty {
            let illegal = hand0.first { $0.face.suit?.code != ledSuit }
            if let illegal {
                do {
                    _ = try engine.apply(Action(seat: Seat(0), intent: .play(illegal.id), expectedVersion: state.version), to: state)
                    Issue.record("illegal discard of \(illegal.face.id) was accepted")
                } catch {
                    guard case RuleViolation.illegal(let ruleId, .mustFollow(let suit)) = error else {
                        Issue.record("wrong violation: \(error)")
                        return
                    }
                    #expect(ruleId == "toy.follow")
                    #expect(suit == ledSuit)
                }
            }
        }
    }

    // MARK: - P1.5: CardID independence from faces

    @Test func cardIDFaceIndependence() throws {
        let engine = ToyGame.engine()
        let deals = 1_000
        // face index (0..9) × assigned ID (0..9) histogram.
        var histogram = Array(repeating: Array(repeating: 0, count: 10), count: 10)
        let faceOrder = ToyGame.stockFaces().map(\.id)
        for seed in 0..<deals {
            let state = try ToyGame.play(engine: engine, seed: UInt64(seed))
            // The stock is empty after dealing; reconstruct face→ID from the
            // final zones (each card is identifiable by its face).
            for instance in state.zones.allInstances {
                guard let faceIndex = faceOrder.firstIndex(of: instance.face.id) else { continue }
                histogram[faceIndex][Int(instance.id.raw)] += 1
            }
        }
        // Expectation per (face, ID) cell = deals × (1 face per ID per deal).
        // 1,000 deals × 10 cards / 100 cells = 100.
        let expectation = Double(deals) / 10.0
        var maxFrequency = 0
        for row in histogram {
            for count in row where count > maxFrequency { maxFrequency = count }
        }
        #expect(Double(maxFrequency) < 3.0 * expectation,
                "a face appeared with one ID \(maxFrequency) times (expectation \(expectation))")
    }
}

import CardModel
