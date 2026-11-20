// JSON-configured deal tests (P3.1 Slice 2).
// Verifies that expression-based deal counts resolve correctly through
// the full JSON → validate → resolve → build → deal pipeline.

import CardModel
import Foundation
import Testing
@_spi(HostOnly) @testable import RulesEngine
@testable @_spi(HostOnly) import RulesetKit

struct DealConfigTests {

    /// Build a Simulator from an inline JSON ruleset document.
    private func makeSimulator(_ json: String) throws -> Simulator {
        let report = RulesetValidator.validate(text: json, byteCount: json.utf8.count)
        #expect(report.errors.isEmpty, "validation errors: \(report.errors.map(\.description).joined(separator: "; "))")
        let document = try RulesetDocument(json: try JSONParser.parse(json), path: "$")
        let resolved = try Resolver.resolve(base: document)
        return try Simulator(ruleset: resolved)
    }

    /// Minimal JSON deal-only document with expression-based `each`.
    private var dealExprDoc: String {
        """
        {
          "format": "parlor.ruleset/1",
          "id": "parlor.deal.expr",
          "game": "deal-expr",
          "kind": "standard",
          "version": "1.0.0",
          "name": {"default": "Deal Expression Test"},
          "players": {"counts": [4], "default": 4, "teams": "none"},
          "deck": {"base": "french-52"},
          "zones": [
            {"id": "stock", "scope": "shared", "visibility": "none", "capacity": 52},
            {"id": "hand", "scope": "seat", "visibility": "owner", "capacity": 13}
          ],
          "vars": {"score": {"scope": "seatMatch", "type": "int", "initial": "0"}},
          "setup": {"firstDealer": "highCut", "dealerRotation": "left"},
          "phases": [
            {"id": "deal", "mechanic": "deal", "params": {
              "source": "stock",
              "packets": [
                {"to": "hand", "each": "players.count"}
              ]
            }}
          ],
          "end": {"rank": "descending(match.score)", "ties": "shared", "check": "afterDeal", "maxDeals": 1}
        }
        """
    }

    /// JSON deal-only document with face-up packets.
    private var dealFaceUpDoc: String {
        """
        {
          "format": "parlor.ruleset/1",
          "id": "parlor.deal.faceup",
          "game": "deal-faceup",
          "kind": "standard",
          "version": "1.0.0",
          "name": {"default": "Deal FaceUp Test"},
          "players": {"counts": [4], "default": 4, "teams": "none"},
          "deck": {"base": "french-52"},
          "zones": [
            {"id": "stock", "scope": "shared", "visibility": "none", "capacity": 52},
            {"id": "hand", "scope": "seat", "visibility": "owner", "capacity": 13},
            {"id": "starter", "scope": "shared", "visibility": "public", "capacity": 4}
          ],
          "vars": {"score": {"scope": "seatMatch", "type": "int", "initial": "0"}},
          "setup": {"firstDealer": "highCut", "dealerRotation": "left"},
          "phases": [
            {"id": "deal", "mechanic": "deal", "params": {
              "source": "stock",
              "packets": [
                {"to": "hand", "each": "players.count"},
                {"to": "starter", "each": 1, "faceUp": true}
              ]
            }}
          ],
          "end": {"rank": "descending(match.score)", "ties": "shared", "check": "afterDeal", "maxDeals": 1}
        }
        """
    }

    // MARK: - Expression each

    @Test func dealEachExprGivesPlayersCountCards() throws {
        let sim = try makeSimulator(dealExprDoc)
        let run = try sim.runDeal(seed: 42)
        #expect(run.faults.isEmpty, "faults: \(run.faults.joined(separator: "; "))")
        let state = run.finalState
        // 4 players × players.count = 4 cards each
        for seat in 0..<4 {
            let cards = state.zones.cards(
                in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
            #expect(cards.count == 4, "Seat \(seat) hand size: \(cards.count)")
        }
        // 16 dealt from 52 → 36 remain in stock
        let stock = state.zones.cards(in: ZoneKey(scope: .shared, id: "stock"))
        #expect(stock.count == 36)
    }

    // MARK: - Expression count (fixed)

    @Test func dealCountFixedOverridesEach() throws {
        let sim = try makeSimulator(dealCountFixedDoc)
        let run = try sim.runDeal(seed: 42)
        #expect(run.faults.isEmpty, "faults: \(run.faults.joined(separator: "; "))")
        let state = run.finalState
        // count = 3 overrides each*packets = 50
        for seat in 0..<4 {
            let cards = state.zones.cards(
                in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
            #expect(cards.count == 3, "Seat \(seat) hand size: \(cards.count)")
        }
        let stock = state.zones.cards(in: ZoneKey(scope: .shared, id: "stock"))
        #expect(stock.count == 40)
    }

    /// JSON deal-only document with fixed `count`.
    private var dealCountFixedDoc: String {
        """
        {
          "format": "parlor.ruleset/1",
          "id": "parlor.deal.countfixed",
          "game": "deal-countfixed",
          "kind": "standard",
          "version": "1.0.0",
          "name": {"default": "Deal Count Fixed Test"},
          "players": {"counts": [4], "default": 4, "teams": "none"},
          "deck": {"base": "french-52"},
          "zones": [
            {"id": "stock", "scope": "shared", "visibility": "none", "capacity": 52},
            {"id": "hand", "scope": "seat", "visibility": "owner", "capacity": 13}
          ],
          "vars": {"score": {"scope": "seatMatch", "type": "int", "initial": "0"}},
          "setup": {"firstDealer": "highCut", "dealerRotation": "left"},
          "phases": [
            {"id": "deal", "mechanic": "deal", "params": {
              "source": "stock",
              "packets": [
                {"to": "hand", "each": 10, "count": 3}
              ]
            }}
          ],
          "end": {"rank": "descending(match.score)", "ties": "shared", "check": "afterDeal", "maxDeals": 1}
        }
        """
    }

    // MARK: - Face-up packets

    @Test func dealFaceUpRevealsToAll() throws {
        let sim = try makeSimulator(dealFaceUpDoc)
        let run = try sim.runDeal(seed: 42)
        #expect(run.faults.isEmpty, "faults: \(run.faults.joined(separator: "; "))")
        let state = run.finalState
        // Hand sizes: 4 each
        for seat in 0..<4 {
            let cards = state.zones.cards(
                in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
            #expect(cards.count == 4)
            // Owner-only knowledge
            for card in cards {
                #expect(state.knowledge.viewers(of: card.id).contains(Seat(seat)))
                if seat != 0 {
                    #expect(!state.knowledge.viewers(of: card.id).contains(Seat(0)))
                }
            }
        }
        // Starter zone: 1 face-up card, visible to everyone
        let starter = state.zones.cards(in: ZoneKey(scope: .shared, id: "starter"))
        #expect(starter.count == 1)
        for card in starter {
            let viewers = state.knowledge.viewers(of: card.id)
            #expect(viewers.contains(Seat(0)))
            #expect(viewers.contains(Seat(1)))
            #expect(viewers.contains(Seat(2)))
            #expect(viewers.contains(Seat(3)))
        }
    }
}
