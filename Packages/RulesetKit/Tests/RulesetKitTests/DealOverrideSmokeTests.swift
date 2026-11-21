// P3.4 p34-2 acceptance: the stacked-deck harness runs a scripted hearts
// deal end to end. Test 1 pins the injection contract (seat-major hands,
// exact faces, conservation, disabled pass phase). Test 2 drives scripted
// plays: the 2C holder leads (HRT-3.1's mandate) and a follower holding a
// club is rejected for playing off-suit (HRT-3.2 through the violation
// path). Test 3 runs the SPI Simulator path with the same stack.
//
// CardIDs are assigned fresh each deal in dealing order (§9.5), so scripts
// reference cards by finding the ID in a seat's hand from host state
// (`cardInHand`), never by a hard-coded ID.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) @_spi(HostDealOverride) import RulesetKit
import Testing

struct DealOverrideSmokeTests {
    static let noPass: [String: JSON] = ["passSchedule": .string("none")]

    /// Hearts A..2, first listed dealt first.
    static let heartsOrder = [
        "AH", "KH", "QH", "JH", "10H", "9H", "8H", "7H", "6H", "5H", "4H", "3H", "2H",
    ]
    /// Spades A..2.
    static let spadesOrder = [
        "AS", "KS", "QS", "JS", "10S", "9S", "8S", "7S", "6S", "5S", "4S", "3S", "2S",
    ]
    /// Clubs A..2 (2C last in the block).
    static let clubsOrder = [
        "AC", "KC", "QC", "JC", "10C", "9C", "8C", "7C", "6C", "5C", "4C", "3C", "2C",
    ]
    /// Diamonds A..2.
    static let diamondsOrder = [
        "AD", "KD", "QD", "JD", "10D", "9D", "8D", "7D", "6D", "5D", "4D", "3D", "2D",
    ]

    /// Seat-major with hearts' single `each: 13` packet: seat 0 clubs,
    /// seat 1 diamonds, seat 2 hearts, seat 3 spades.
    static var full52: [String] { clubsOrder + diamondsOrder + heartsOrder + spadesOrder }

    /// Violation stack: seat 1 leads 2C (holding 12 hearts), seat 2 holds
    /// AC but tries a diamond — the must-follow rejection. Seat-major.
    static var violation52: [String] {
        [
            // Seat 0: AD + AH + spades 3..K.
            "AD", "AH", "KS", "QS", "JS", "10S", "9S", "8S", "7S", "6S", "5S", "4S", "3S",
            // Seat 1: 2C + hearts K..2 (leads 2C).
            "2C", "KH", "QH", "JH", "10H", "9H", "8H", "7H", "6H", "5H", "4H", "3H", "2H",
            // Seat 2: AC + diamonds K..2 (holds the club, tries KD).
            "AC", "KD", "QD", "JD", "10D", "9D", "8D", "7D", "6D", "5D", "4D", "3D", "2D",
            // Seat 3: clubs K..3 + AS + 2S.
            "KC", "QC", "JC", "10C", "9C", "8C", "7C", "6C", "5C", "4C", "3C", "AS", "2S",
        ]
    }

    @Test func stackedDealLandsExactlyWhereListed() throws {
        let engine = try ConformanceRulesets.riggedEngine(
            game: "hearts.standard", tableOptions: Self.noPass, deal: Self.full52)
        let start = try engine.start(seed: 1)
        let state = start.state

        #expect(
            state.zones.cards(in: ZoneKey(scope: .seat, owner: 0, id: "hand")).map { $0.face.id }
                == Self.clubsOrder.map { face($0).id })
        #expect(
            state.zones.cards(in: ZoneKey(scope: .seat, owner: 1, id: "hand")).map { $0.face.id }
                == Self.diamondsOrder.map { face($0).id })
        #expect(
            state.zones.cards(in: ZoneKey(scope: .seat, owner: 2, id: "hand")).map { $0.face.id }
                == Self.heartsOrder.map { face($0).id })
        #expect(
            state.zones.cards(in: ZoneKey(scope: .seat, owner: 3, id: "hand")).map { $0.face.id }
                == Self.spadesOrder.map { face($0).id })

        // Conservation: 52 dealt, deck empty, play phase (pass disabled).
        #expect(state.zones.totalCardCount == 52)
        #expect(state.zones.cards(in: ZoneKey(scope: .shared, id: "deck")).isEmpty)
        #expect(state.phase.phaseID == "play")

        // The dealt record captured every hand (§7.5).
        #expect(state.dealt[0]?.count == 13)
        #expect(state.dealt[1]?.count == 13)
        #expect(state.dealt[2]?.count == 13)
        #expect(state.dealt[3]?.count == 13)
    }

    @Test func scriptedFollowViolationFires() throws {
        let engine = try ConformanceRulesets.riggedEngine(
            game: "hearts.standard", tableOptions: Self.noPass, deal: Self.violation52)
        let start = try engine.start(seed: 1)
        #expect(start.state.phase.phaseID == "play")

        // The 2C holder (seat 1) leads it; seat 2 holds AC but plays KD.
        let steps: [ConformanceStep] = [
            ConformanceStep(
                action: Seat(1), .play(cardInHand(1, "2C", in: start.state)),
                .phase("play"), .turn([2])
            ),
            ConformanceStep(
                action: Seat(2), .play(cardInHand(2, "KD", in: start.state)),
                expectViolation: "HRT-3.2", .turn([2])
            ),
        ]
        let outcome = try ConformanceRunner.play(steps, engine: engine, seed: 1)
        #expect(
            outcome.failures.isEmpty,
            Comment(stringLiteral: "scripted hearts failed: " + outcome.failures.joined(separator: "; ")))
        #expect(outcome.fired.contains("HRT-3.2"))
    }

    @Test func simulatorPathRunsWithStackedDeal() throws {
        let resolved = try ConformanceRulesets.resolved(
            game: "hearts.standard", tableOptions: Self.noPass)
        let simulator = try Simulator(
            ruleset: resolved, maxActions: 8_000, dealOverride: faces(Self.full52))
        let run = try simulator.runDeal(seed: 3)
        #expect(
            run.faults.isEmpty,
            Comment(stringLiteral: "stacked sim must run clean: " + run.faults.joined(separator: "; ")))
        #expect(run.done)
    }
}

/// A card's ID in a seat's hand (host state, tests only).
func cardInHand(_ seat: Int, _ faceId: String, in state: GameState) -> CardID {
    let hand = state.zones.cards(in: ZoneKey(scope: .seat, owner: seat, id: "hand"))
    return hand.first { $0.face.id == faceId }?.id ?? CardID(9999)
}
