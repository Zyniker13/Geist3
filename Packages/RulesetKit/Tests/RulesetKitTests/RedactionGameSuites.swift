// P3.6 (ROADMAP): game-specific redaction property suites — 2,000 games
// per game, byte-scanning every viewer's observation after every step for
// faces that viewer must not know. The toy-game scan in RulesEngine's
// RedactionTests covers the mechanism; these suites cover the four shipped
// games' specific information flows:
//
// - **Hearts** — while a pass sits in the outbox, only the passer knows
//   its faces; the delivered cards become the recipient's knowledge and
//   nobody else's (§9.6 pass knowledge).
// - **Euchre** — the turned up-card is public from its face-up entry and
//   stays public even when turned down (knowledge is never removed); the
//   discard is known to the dealer alone (or public, if it is the turned
//   card); the kitty's untouched cards are known to nobody.
// - **Bridge** — before the opening lead only the dummy seat itself knows
//   the dummy's hand; after the reveal it is public for the rest of the
//   deal.
// - **Cribbage** — each crib card is known to at most its contributor
//   until the show reveals the whole crib.
//
// Structure: one generic driver (`run`) plays N seeded random-legal deals,
// and after every state change byte-scans the encoded `Observation` JSON
// of each viewer against the forbidden-face set derived from the knowledge
// store — the redaction authority since ADR-0038. A per-game structure
// probe additionally pins the game's knowledge invariants against the host
// state, so the specific flow named in the plan is asserted directly, not
// only via the absence of leaks.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing

@_spi(HostOnly) @testable import RulesetKit

struct RedactionGameSuites {

    // MARK: - Driver

    /// One game's redaction scan: how many byte-scan assertions ran, and
    /// any failures (collected, then asserted empty).
    struct ScanResult {
        var checks = 0
        var failures: [String] = []
        var dealsCompleted = 0
    }

    /// A per-state structure probe: failure text for any violated
    /// game-specific knowledge invariant. `@Sendable`: probes run inside
    /// the shard tasks (they only read the state they are handed).
    typealias StructureProbe = @Sendable (GameState, UInt64) -> [String]

    /// Play `deals` seeded deals, byte-scanning every step. `probe` (when
    /// given) runs the game's structure checks on every state, initial
    /// included. The random-legal walk is the same shape the P3.3
    /// simulation suites prove completes on these rulesets; a deal that
    /// cannot proceed just ends the walk early (its steps still scanned).
    ///
    /// Deals are sharded across a TaskGroup (~defaultParallelism shards).
    /// Every deal is keyed only by its seed — the engine is immutable
    /// configuration, `SeededRNG` is local to the deal, and nothing else
    /// is shared — so shard scheduling cannot change any result; the suite
    /// stays deterministic while running ~8× faster. Each shard stops at
    /// its first failure; the merged result reports what each shard saw.
    static func run(_ game: String, deals: Int, probe: StructureProbe? = nil) async throws -> ScanResult {
        var result = ScanResult()
        let resolved = try ConformanceRulesets.resolved(game: game)
        let engine = try EngineBuilder.build(from: resolved)
        let shardCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let shards: [Void] = Array(repeating: (), count: shardCount)
        let perShard = (deals + shardCount - 1) / shardCount

        let shardResults = await withTaskGroup(
            of: ScanResult.self, returning: [ScanResult].self
        ) { group in
            for shard in shards.indices {
                group.addTask { [engine] in
                    var shardResult = ScanResult()
                    let encoder = JSONEncoder()
                    for offset in 0..<perShard {
                        let seed = UInt64(shard * perShard + offset)
                        guard seed < UInt64(deals) else { break }
                        Self.playDeals(
                            engine, seed: seed, probe: probe, encoder: encoder,
                            into: &shardResult)
                        if !shardResult.failures.isEmpty { break }
                    }
                    return shardResult
                }
            }
            var all: [ScanResult] = []
            for await shardResult in group { all.append(shardResult) }
            return all
        }

        for shardResult in shardResults {
            result.checks += shardResult.checks
            result.dealsCompleted += shardResult.dealsCompleted
            result.failures.append(contentsOf: shardResult.failures)
        }
        return result
    }

    /// One seeded deal, probed and scanned at every step.
    static func playDeals(
        _ engine: Engine, seed: UInt64, probe: StructureProbe?, encoder: JSONEncoder,
        into result: inout ScanResult
    ) {
        guard var state = try? engine.start(seed: seed).state else {
            result.failures.append("seed \(seed): engine.start failed")
            return
        }
        if let probe { result.failures.append(contentsOf: probe(state, seed)) }
        scan(engine, state, seed, 0, encoder: encoder, into: &result)

        var rng = SeededRNG(seed: seed ^ 0xfeed_face_face_face)
        var steps = 0
        let stepCap = 1_000  // bounds a stuck deal; real deals are ≤ ~60
        while state.phase.phaseID != "done", steps < stepCap {
            steps += 1
            guard let (seat, intent) = pickRandomLegal(engine, state, &rng) else { break }
            do {
                state = try engine.apply(
                    Action(seat: seat, intent: intent, expectedVersion: state.version),
                    to: state
                ).state
            } catch {
                // A random walk can hit a legality the sim suites'
                // policies avoid; end this deal's walk, keep scanning
                // the final state it reached.
                break
            }
            if let probe { result.failures.append(contentsOf: probe(state, seed)) }
            scan(engine, state, seed, steps, encoder: encoder, into: &result)
        }
        if state.phase.phaseID == "done" { result.dealsCompleted += 1 }
    }

    /// A uniform random choice among one pending seat's legal intents.
    static func pickRandomLegal(
        _ engine: Engine, _ state: GameState, _ rng: inout SeededRNG
    ) -> (Seat, ActionIntent)? {
        let pending = engine.pendingSeats(in: state).sorted()
        guard !pending.isEmpty else { return nil }
        let seat = pending[rng.below(pending.count)]
        let legal = engine.legalIntents(for: seat, in: state)
        guard !legal.isEmpty else { return nil }
        return (seat, legal[rng.below(legal.count)])
    }

    /// Every viewer kind scanned: one per seat, plus table and spectator.
    /// (coachOf shares the seat branch of `Redactor.maySee`; the toy suite
    /// covers it, so the per-game suites skip the duplicate work.)
    static func viewers(seatCount: Int) -> [Viewer] {
        (0..<seatCount).map { Viewer.seat(Seat($0)) } + [.table, .spectator]
    }

    /// Faces a viewer must NOT see in this state, straight from the
    /// knowledge store (ADR-0038: knowledge is the redaction authority).
    static func forbiddenFaces(state: GameState, viewer: Viewer) -> Set<String> {
        var forbidden = Set<String>()
        switch viewer {
        case .replayAll:
            return forbidden  // sees everything by design
        case .table, .spectator:
            for (_, cards) in state.zones.zones {
                for card in cards where !state.knowledge.isPublic(card.id) {
                    forbidden.insert(card.face.id)
                }
            }
        case .seat(let seat), .coachOf(let seat):
            for (_, cards) in state.zones.zones {
                for card in cards where !state.knowledge.knows(card.id, seat) {
                    forbidden.insert(card.face.id)
                }
            }
        }
        return forbidden
    }

    /// Byte-scan one state for every viewer. The scan is field-wise, not a
    /// raw substring search over the whole encoding: an `Observation` also
    /// carries auction call strings (bridge's `legal` ladder and `.called`
    /// events), which legitimately spell card-face-like tokens ("5D",
    /// "6C" — the level-plus-strain bid vocabulary), so a whole-JSON scan
    /// would flag them as leaks. Faces can only enter an observation
    /// through the zone payloads and the event card payloads; those are
    /// exactly what gets scanned, mirroring the P1.6 toy-suite rule
    /// ("the JSON encoding of the observation contains no face unknown to
    /// that viewer") where no call vocabulary exists to collide with.
    static func scan(
        _ engine: Engine, _ state: GameState, _ seed: UInt64, _ step: Int,
        encoder: JSONEncoder, into result: inout ScanResult
    ) {
        for viewer in viewers(seatCount: engine.seatCount) {
            let forbidden = forbiddenFaces(state: state, viewer: viewer)
            guard !forbidden.isEmpty else { continue }
            let observation = engine.observation(of: state, for: viewer)

            // Zone payloads: card faces the observation exposes.
            var zoneFaces: [String] = []
            for (_, zone) in observation.zones {
                switch zone {
                case .visible(let cards): zoneFaces.append(contentsOf: cards.map { $0.face.id })
                case .hidden(_, let known): zoneFaces.append(contentsOf: known.map { $0.face.id })
                }
            }

            // Event payloads: the card faces any redacted event carries.
            var eventFaces: [String] = []
            for event in observation.lastEvents {
                switch event {
                case .dealt(_, let cards), .passed(_, _, let cards),
                    .trickWon(_, let cards), .revealed(_, let cards):
                    eventFaces.append(contentsOf: cards.map { $0.face.id })
                case .cardPlayed(_, let card):
                    eventFaces.append(card.face.id)
                default:
                    break
                }
            }

            let exposed = Set(zoneFaces + eventFaces)
            for face in forbidden {
                result.checks += 1
                if exposed.contains(face) {
                    result.failures.append(
                        "seed \(seed) step \(step): \(viewer) sees hidden face \(face)")
                }
            }
        }
    }

    // MARK: - Game probes

    /// Hearts: while a pass waits in a `passOut` zone, only the passer
    /// knows its faces.
    static func heartsPassProbe(_ state: GameState, _ seed: UInt64) -> [String] {
        var failures: [String] = []
        guard state.phase.phaseID == "pass" else { return failures }
        for (key, cards) in state.zones.zones where key.id == "passOut" {
            for card in cards {
                for knower in state.knowledge.viewers(of: card.id) {
                    if knower.raw != key.owner {
                        failures.append(
                            "seed \(seed): seat \(knower.raw) knows seat \(key.owner)'s"
                                + " passed \(card.face.id) before delivery")
                    }
                }
            }
        }
        return failures
    }

    /// Euchre: kitty cards are known to nobody (except the formerly turned
    /// up-card, which stays public); discard cards are known to the dealer
    /// alone (or public, when the discarded card is the turned up-card).
    static func euchreHiddenZonesProbe(_ state: GameState, _ seed: UInt64) -> [String] {
        var failures: [String] = []
        for (key, cards) in state.zones.zones {
            guard key.id == "kitty" || key.id == "discard", !cards.isEmpty else { continue }
            let dealerSet = SeatSet(Seat(state.dealer.raw))
            for card in cards {
                let knowers = state.knowledge.viewers(of: card.id)
                if state.knowledge.isPublic(card.id) { continue }
                if key.id == "kitty" {
                    if !knowers.isEmpty {
                        failures.append(
                            "seed \(seed): kitty face \(card.face.id) known to \(knowers.count) seat(s)")
                    }
                } else if !(knowers == dealerSet || knowers.isEmpty) {
                    failures.append(
                        "seed \(seed): discard face \(card.face.id) known beyond the dealer")
                }
            }
        }
        return failures
    }

    /// Bridge: with a declarer set, the dummy's remaining hand is either
    /// fully public (after the opening lead's reveal) or known to the
    /// dummy seat alone (before it).
    static func bridgeDummyProbe(_ state: GameState, _ seed: UInt64) -> [String] {
        var failures: [String] = []
        guard case .seat(let declarer)? = state.dealVars.get(VarPath("declarer")) else {
            return failures  // no declarer until the auction completes
        }
        let dummy = (declarer.raw + 2) % 4
        let dummyCards = state.zones.cards(in: ZoneKey(scope: .seat, owner: dummy, id: "hand"))
        guard !dummyCards.isEmpty else { return failures }
        if dummyCards.allSatisfy({ state.knowledge.isPublic($0.id) }) {
            return failures  // revealed; knowledge never un-published
        }
        for card in dummyCards {
            for knower in state.knowledge.viewers(of: card.id) where knower.raw != dummy {
                failures.append(
                    "seed \(seed): seat \(knower.raw) knows dummy face \(card.face.id) before the reveal")
            }
        }
        return failures
    }

    /// Cribbage: before the show, each crib card is known to at most one
    /// seat (its contributor — attribution to the *right* contributor is
    /// not recoverable from post-show state, so the count is the
    /// invariant); while the show phase steps through its order entries
    /// (ADR-0032: one reveal per step) a not-yet-revealed crib is fine;
    /// CRB-6.1 lets a win land mid-show, so a `done` deal may leave the
    /// remaining entries unrevealed — that is correct play, not a leak,
    /// and the show's own reveal behavior is covered by conformance.
    static func cribHiddenProbe(_ state: GameState, _ seed: UInt64) -> [String] {
        var failures: [String] = []
        guard state.phase.phaseID != "show", state.phase.phaseID != "done" else {
            return failures
        }
        for (key, cards) in state.zones.zones where key.id == "crib" {
            for card in cards {
                if state.knowledge.viewers(of: card.id).count > 1 {
                    failures.append(
                        "seed \(seed): crib face \(card.face.id) known to both players before the show")
                }
            }
        }
        return failures
    }

    // MARK: - The four suites (2,000 deals each, P3.6)

    @Test func heartsRedaction() async throws {
        let result = try await Self.run("hearts.standard", deals: 2_000, probe: Self.heartsPassProbe)
        #expect(
            result.failures.isEmpty,
            Comment(stringLiteral: result.failures.prefix(8).joined(separator: "; ")))
        #expect(result.checks > 100_000, Comment(stringLiteral: "only \(result.checks) byte-scan checks"))
    }

    @Test func euchreRedaction() async throws {
        let result = try await Self.run("euchre.standard", deals: 2_000, probe: Self.euchreHiddenZonesProbe)
        #expect(
            result.failures.isEmpty,
            Comment(stringLiteral: result.failures.prefix(8).joined(separator: "; ")))
        #expect(result.checks > 100_000, Comment(stringLiteral: "only \(result.checks) byte-scan checks"))
    }

    @Test func bridgeRedaction() async throws {
        let result = try await Self.run("contract-bridge.rubber", deals: 2_000, probe: Self.bridgeDummyProbe)
        #expect(
            result.failures.isEmpty,
            Comment(stringLiteral: result.failures.prefix(8).joined(separator: "; ")))
        #expect(result.checks > 100_000, Comment(stringLiteral: "only \(result.checks) byte-scan checks"))
    }

    @Test func cribbageRedaction() async throws {
        let result = try await Self.run("cribbage.six-card", deals: 2_000, probe: Self.cribHiddenProbe)
        #expect(
            result.failures.isEmpty,
            Comment(stringLiteral: result.failures.prefix(8).joined(separator: "; ")))
        #expect(result.checks > 100_000, Comment(stringLiteral: "only \(result.checks) byte-scan checks"))
    }
}
