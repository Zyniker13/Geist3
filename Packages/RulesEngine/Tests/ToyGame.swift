// The P1 toy game: a two-player "High Card Trick" with five tricks
// (ROADMAP §P1 goal). Ten cards — A K Q J 10 of spades and hearts — dealt
// five each; the higher card of the led suit wins each trick; most tricks
// wins the deal. Configured in Swift (the JSON DSL lands in P2).

import CardModel
@testable import RulesEngine
@_spi(HostOnly) import RulesEngine

enum ToyGame {
    static let seatCount = 2
    static let tricks = 5

    static func stockFaces() -> [CardFace] {
        var faces: [CardFace] = []
        for rank in ["A", "K", "Q", "J", "10"] {
            faces.append(CardFace(suit: .spades, rank: Rank(rank)))
            faces.append(CardFace(suit: .hearts, rank: Rank(rank)))
        }
        return faces
    }

    static func engine() -> Engine {
        let deal = AnyMechanic(DealMechanic.self, params: DealParams(
            source: "stock",
            packets: [DealPacket(to: Seat(0), each: 5), DealPacket(to: Seat(1), each: 5)],
            shuffleFirst: true,
            deckFaces: stockFaces()
        ))
        let trick = AnyMechanic(TrickPlayMechanic.self, params: TrickPlayParams(
            seatCount: seatCount,
            tricks: tricks,
            activeSeats: [Seat(0), Seat(1)],
            firstLeader: Seat(1), // left of dealer (seat 0) in a two-hand game
            winnerRule: .highestOfLed,
            followRuleId: "toy.follow"
        ))
        return Engine(
            phases: [
                PhaseConfig(id: "deal", mechanic: deal),
                PhaseConfig(id: "tricks", mechanic: trick),
            ],
            seatCount: seatCount
        )
    }

    /// Play one full deal with random legal intents; returns the final state.
    static func play(engine: Engine, seed: UInt64) throws -> GameState {
        let start = try engine.start(seed: seed)
        var state = start.state
        var rng = SeededRNG(seed: seed ^ 0x5eed_5eed_5eed_5eed)
        while state.phase.phaseID != "done" {
            var acted = false
            for seatRaw in 0..<seatCount {
                let seat = Seat(seatRaw)
                let legal = engine.legalIntents(for: seat, in: state)
                guard !legal.isEmpty else { continue }
                let pick = rng.below(legal.count)
                let action = Action(seat: seat, intent: legal[pick], expectedVersion: state.version)
                state = try engine.apply(action, to: state).state
                acted = true
                break // exactly one seat is pending at a time in this game
            }
            if !acted {
                // No pending seat but not done: stall (should not happen).
                throw RuleViolation.engineFault(ruleId: "toy.stall", pointer: "phase \(state.phase.phaseID)")
            }
        }
        return state
    }
}
