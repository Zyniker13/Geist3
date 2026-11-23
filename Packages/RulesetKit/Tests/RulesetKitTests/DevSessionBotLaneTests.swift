import CardModel
import Foundation
import RulesEngine
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) import RulesetKit
import Testing

/// P3.7 debugging: the dev play session's exact algorithm — a fixed human
/// seat that always plays the FIRST legal intent, then bots round-robin —
/// must complete a deal for every base game. Reproduces the UI-test hangs
/// (bots "moving" forever, no legal intent for anyone) headless.
struct DevSessionBotLaneTests {
    /// Resolves a ruleset from the repository's Resources/Rulesets directory.
    /// #filePath → Packages/RulesetKit/Tests/RulesetKitTests/…; the repo root
    /// is five levels up.
    func resolvedRuleset(_ id: String) throws -> ResolvedRuleset {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RulesetKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RulesetKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Resources/Rulesets/\(id).ruleset.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        let document = try RulesetDocument(json: try JSONParser.parse(text), path: "$")
        return try Resolver.resolve(base: document)
    }

    /// The PlaySession algorithm, headless: human seat acts when pending,
    /// then `runBots` (verbatim shape: first non-human pending seat plays a
    /// uniform-seeded legal intent, repeat until no non-human seat is
    /// pending). Returns `stalled` when a round produces no progress —
    /// the hang signature (a pending seat with no legal intents).
    func playSessionLike(_ ruleset: ResolvedRuleset, seed: UInt64, cap: Int = 600) throws
        -> (state: GameState, humanActions: Int, stalled: Bool, phase: String?, debug: String)
    {
        let engine = try EngineBuilder.build(from: ruleset)
        let start = try engine.start(seed: seed)
        var state = start.state
        var botRNG = SeededRNG(seed: seed ^ 0xfeed_face_face_face)
        let human = Seat(0)
        var actions = 0
        while !state.matchOver && actions < cap {
            var progressed = false
            if engine.pendingSeats(in: state).contains(human),
                let intent = engine.legalIntents(for: human, in: state).first
            {
                let t = try engine.apply(
                    Action(seat: human, intent: intent, expectedVersion: state.version),
                    to: state)
                state = t.state
                actions += 1
                progressed = true
            }
            // Bot lane: PlaySession.runBots, verbatim.
            while !state.matchOver {
                let pending = engine.pendingSeats(in: state).sorted()
                guard let seat = pending.first(where: { $0 != human }) else { break }
                let legal = engine.legalIntents(for: seat, in: state)
                guard !legal.isEmpty else {
                    let desc = pending.map { "S\($0.raw)" }.joined(separator: ",")
                    return (
                        state, actions, true, state.phase.phaseID,
                        "empty-legals for S\(seat.raw); pending=[\(desc)] opts=\(state.phaseOptions)"
                    )
                }
                let pick = legal[botRNG.below(legal.count)]
                guard
                    let t = try? engine.apply(
                        Action(seat: seat, intent: pick, expectedVersion: state.version),
                        to: state)
                else {
                    return (
                        state, actions, true, state.phase.phaseID,
                        "apply threw for S\(seat.raw)"
                    )
                }
                state = t.state
                progressed = true
            }
            if !progressed {
                let pend = engine.pendingSeats(in: state).sorted()
                    .map { "S\($0.raw)" }.joined(separator: ",")
                return (
                    state, actions, true, state.phase.phaseID,
                    "no-progress: pending=[\(pend)] opts=\(state.phaseOptions)"
                )
            }
        }
        return (state, actions, false, state.phase.phaseID, "")
    }

    @Test func euchreHumanFirstSeatCompletesADeal() throws {
        let ruleset = try resolvedRuleset("euchre.standard")
        var stalledSeeds: [UInt64] = []
        var debug = ""
        for seed: UInt64 in 1...64 {
            let (_, _, stalled, phase, d) = try playSessionLike(ruleset, seed: seed)
            if stalled {
                stalledSeeds.append(seed)
                debug = "phase=\(phase ?? "-") \(d)"
            }
        }
        #expect(stalledSeeds.isEmpty, "euchre stalls on seeds \(stalledSeeds): \(debug)")
    }

    @Test func heartsHumanFirstSeatCompletesADeal() throws {
        let (state, actions, stalled, phase, d) = try playSessionLike(
            try resolvedRuleset("hearts.standard"), seed: 7)
        #expect(
            !stalled,
            "hearts seed 7: stalled in phase \(phase ?? "-") after \(actions) human actions: \(d)")
        #expect(state.dealIndex >= 1 || state.matchOver)
    }

    @Test func bridgeHumanFirstSeatCompletesADeal() throws {
        let (state, actions, stalled, phase, d) = try playSessionLike(
            try resolvedRuleset("contract-bridge.rubber"), seed: 7)
        #expect(
            !stalled,
            "bridge seed 7: stalled in phase \(phase ?? "-") after \(actions) human actions: \(d)")
        #expect(state.dealIndex >= 1 || state.matchOver)
    }

    @Test func cribbageHumanFirstSeatCompletesADeal() throws {
        let (state, actions, stalled, phase, d) = try playSessionLike(
            try resolvedRuleset("cribbage.six-card"), seed: 7)
        #expect(
            !stalled,
            "cribbage seed 7: stalled in phase \(phase ?? "-") after \(actions) human actions: \(d)")
        #expect(state.dealIndex >= 1 || state.matchOver)
    }
}
