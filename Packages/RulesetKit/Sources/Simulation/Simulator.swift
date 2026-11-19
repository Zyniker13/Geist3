// P2.8: the deterministic deal simulator (ROADMAP §P2.8). Host tooling:
// compiles against the host-only engine SPI and consumes full state; it
// never logs card faces or sends state out (§9 redaction is unchanged).

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine

/// P2.8: the deterministic deal simulator (ROADMAP §P2.8). Runs one deal per
/// seed with a bot policy, checks the simulator-level invariants (card
/// conservation, stall cap), and reports a digest + exercised rule ids.
///
/// The simulator is host tooling: it compiles against the host-only engine
/// SPI and consumes full state. It never logs card faces or sends state out;
/// §9 redaction is unchanged.
@_spi(HostOnly)
public struct Simulator: Sendable {
    let engine: Engine
    public let seatCount: Int
    /// Rule ids declared in the document, for the unexercised report.
    let declaredRules: Set<String>

    public init(ruleset: ResolvedRuleset) throws {
        try self.init(ruleset: ruleset, maxActions: Simulator.actionCap)
    }

    /// `maxActions` overrides the runaway guard for tests that must exercise
    /// the cap; production runs use the default.
    public init(ruleset: ResolvedRuleset, maxActions: Int) throws {
        engine = try EngineBuilder.build(from: ruleset)
        seatCount = engine.seatCount
        declaredRules = Set((ruleset.document.rules ?? []).map(\.id))
        actionLimit = max(0, maxActions)
    }

    private let actionLimit: Int

    /// Run one full deal. `bot` decides among legal intents; the default is
    /// the seeded uniform bot. Deterministic: (ruleset, seed, bot) → run.
    public func runDeal(seed: UInt64, bot: any SimulatorBot = RandomLegalBot()) throws -> SimulationRun {
        var faults: [String] = []
        var exercised: Set<String> = []
        var actions = 0

        var state = try engine.start(seed: seed).state
        var totalCards = state.zones.totalCardCount

        while state.phase.phaseID != "done" {
            if actions >= actionLimit {
                faults.append("simulator.action-cap")
                break
            }
            guard let pick = pickAction(state: state, actions: actions, bot: bot) else {
                faults.append("simulator.stall at phase \(state.phase.phaseID)")
                break
            }
            do {
                let transition = try engine.apply(pick.action, to: state)
                state = transition.state
                for event in transition.events {
                    if case .scored(_, _, _, let ruleId?) = event { exercised.insert(ruleId) }
                }
            } catch let violation as RuleViolation {
                if case .illegal(let ruleId, _) = violation { exercised.insert(ruleId) }
                faults.append("violation: \(violation)")
                break
            }
            actions += 1
            // Conservation: cards are only created by the deal (setup) and
            // never destroyed; a count change mid-play is a simulator bug.
            let newTotal = state.zones.totalCardCount
            if newTotal != totalCards {
                faults.append("card conservation broke: \(totalCards) → \(newTotal)")
                totalCards = newTotal
            }
        }

        var hashHex = ""
        for byte in Engine.finalStateHash(state) {
            hashHex += String(format: "%02x", byte)
        }
        let unexercised = declaredRules.subtracting(exercised).sorted()
        return SimulationRun(
            seed: seed, actions: actions, done: state.phase.phaseID == "done",
            finalHash: hashHex, faults: faults, unexercisedRules: unexercised,
            finalState: state)
    }

    /// One round-robin turn: first seat with a legal intent acts. A bot that
    /// declines (nil) skips that seat; if every seat declines, the run stalls.
    private func pickAction(
        state: GameState, actions: Int,
        bot: any SimulatorBot
    ) -> (action: Action, intent: ActionIntent)? {
        for rawSeat in 0..<seatCount {
            let seat = Seat(rawSeat)
            let legal = engine.legalIntents(for: seat, in: state)
            guard !legal.isEmpty else { continue }
            guard let intent = bot.choose(legal: legal, seat: seat, actionIndex: actions) else {
                continue
            }
            return (Action(seat: seat, intent: intent, expectedVersion: state.version), intent)
        }
        return nil
    }

    /// Guard against runaway deals (a stuck phase would spin forever).
    static let actionCap = 4_000
}
