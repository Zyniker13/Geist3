// Golden-replay generator for the four base games (P3.5, §10.4): plays 20
// deterministic deals per game through the Simulator (the seeded uniform
// bot), writes one JSON replay file per deal into the requested directory,
// and verifies each written file replays to the recorded final-state hash.
//
// Replay file format `parlor.replay/1` (the same layout the toy-game
// replays use):
//
//   format         "parlor.replay/1"
//   rulesetHash    SHA-256 of the resolved ruleset (hex)
//   seed           the run seed
//   seatCount      seats in the game
//   actions[]      { seat, intent, version } in applied order
//   finalStateHash SHA-256 of the terminal GameState JSON (hex)
//
// Intent encoding: `play:<raw CardID>`, `call:<text>`, `pass:<raw,raw…>`,
// `discard:<raw,raw…>`, `drawFrom:<zone>`, `meld:<raw,raw…>`,
// `choose:<text>`, `claim:<n>`, `acceptClaim:<true|false>`,
// `cut:<depth>`, `count:<points>`, `confirm`. Version is the state
// version the action was applied against (stale versions are rejected,
// so the number matters).
//
// Determinism: the bot is the seeded uniform RandomLegalBot seeded from
// the run seed, so (ruleset, seed) → full action list and final state;
// no clock, no system randomness. The generator refuses to write a file
// whose recorded actions do not reproduce the recorded final-state hash
// via Engine.replay (self-verification before anything is committed).
//
// Usage: RulesetKitGoldenGen <output-directory> [<game>…]
//   <game> is a base ruleset stem, e.g. "hearts.standard". With no game
//   arguments, all four base games are generated (hearts.standard,
//   euchre.standard, contract-bridge.rubber, cribbage.six-card), 20 each.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import RulesetKit
@_spi(HostOnly) import RulesetKit

struct Golden: Codable {
    let format: String
    let rulesetHash: String
    let seed: UInt64
    let seatCount: Int
    let actions: [Line]
    let finalStateHash: String

    struct Line: Codable {
        let seat: Int
        let intent: String
        let version: UInt64
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func encodeIntent(_ intent: ActionIntent) -> String {
    func list(_ cards: [CardID]) -> String { cards.map { "\($0.raw)" }.joined(separator: ",") }
    switch intent {
    case .play(let id): return "play:\(id.raw)"
    case .call(let text): return "call:\(text)"
    case .pass(let cards): return "pass:\(list(cards))"
    case .discard(let cards): return "discard:\(list(cards))"
    case .drawFrom(let zone): return "drawFrom:\(zone)"
    case .meld(let cards): return "meld:\(list(cards))"
    case .choose(let text): return "choose:\(text)"
    case .claim(let n): return "claim:\(n)"
    case .acceptClaim(let yes): return "acceptClaim:\(yes ? "true" : "false")"
    case .cut(let depth): return "cut:\(depth)"
    case .count(let points): return "count:\(points)"
    case .confirm: return "confirm"
    @unknown default: fatalError("unhandled ActionIntent case in golden encoder")
    }
}

func parseIntent(_ text: String) throws -> ActionIntent {
    func cardList(_ raw: String) throws -> [CardID] {
        raw.isEmpty
            ? []
            : try raw.split(separator: ",").map { part -> CardID in
                guard let n = UInt16(part) else { throw GoldenError.badIntent(text) }
                return CardID(n)
            }
    }
    guard let colon = text.firstIndex(of: ":") else {
        if text == "confirm" { return .confirm }
        throw GoldenError.badIntent(text)
    }
    let kind = String(text[..<colon])
    let rest = String(text[text.index(after: colon)...])
    switch kind {
    case "play":
        guard let n = UInt16(rest) else { throw GoldenError.badIntent(text) }
        return .play(CardID(n))
    case "call": return .call(rest)
    case "pass": return .pass(try cardList(rest))
    case "discard": return .discard(try cardList(rest))
    case "drawFrom": return .drawFrom(rest)
    case "meld": return .meld(try cardList(rest))
    case "choose": return .choose(rest)
    case "claim":
        guard let n = Int(rest) else { throw GoldenError.badIntent(text) }
        return .claim(n)
    case "acceptClaim": return .acceptClaim(rest == "true")
    case "cut":
        guard let d = Int(rest) else { throw GoldenError.badIntent(text) }
        return .cut(depth: d)
    case "count":
        guard let p = Int(rest) else { throw GoldenError.badIntent(text) }
        return .count(points: p)
    case "confirm": return .confirm
    default: throw GoldenError.badIntent(text)
    }
}

enum GoldenError: Error {
    case badIntent(String)
    case loadFailed(String)
    case verifyFailed(String)
}

/// Fixed 20-seed list (the same list the toy replays use).
let seeds: [UInt64] = [
    0, 1, 7, 42, 99, 123, 555, 777, 1024, 2024, 31_337, 65_535,
    100_001, 250_000, 500_001, 750_003, 999_999, 1_234_567, 8_765_432, UInt64.max - 1,
]

func generate(rulesetPath: String, gameSlug: String, into directory: URL) throws {
    let text = try String(contentsOf: URL(fileURLWithPath: rulesetPath), encoding: .utf8)
    let document = try Schema.decodeRuleset(text)
    let resolved = try Resolver.resolve(base: document)
    let simulator = try Simulator(ruleset: resolved)

    var failures: [String] = []
    for (index, seed) in seeds.enumerated() {
        // Uniform random-legal bot; the simulator's own bot stream is seeded
        // per deal from the run seed, so (ruleset, seed) is the full input.
        let run = try simulator.runDeal(seed: seed)
        guard run.done, run.faults.isEmpty else {
            throw GoldenError.verifyFailed("\(gameSlug) seed \(seed): \(run.faults)")
        }
        let state = run.finalState
        let recordedHash = hex(Engine.finalStateHash(state))

        // Self-verify: replay the recorded actions through the engine and
        // confirm the same final-state hash before writing anything.
        let replayRecord = Replay(
            rulesetHash: Data(), seed: seed, seatCount: simulator.seatCount,
            actions: state.history.map {
                LoggedAction(seat: $0.seat, intent: $0.intent, version: $0.version)
            })
        let replayed = try simulator.engine.replay(replayRecord)
        let replayedHash = hex(Engine.finalStateHash(replayed))
        guard replayedHash == recordedHash else {
            throw GoldenError.verifyFailed("\(gameSlug) seed \(seed): replay hash mismatch")
        }

        let golden = Golden(
            format: "parlor.replay/1",
            rulesetHash: resolved.hash,
            seed: seed,
            seatCount: simulator.seatCount,
            actions: state.history.map {
                Golden.Line(seat: $0.seat.raw, intent: encodeIntent($0.intent), version: $0.version)
            },
            finalStateHash: recordedHash)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let name = String(format: "%@-%02d.json", gameSlug, index)
        try encoder.encode(golden).write(to: directory.appendingPathComponent(name))
        print("wrote \(name): \(golden.actions.count) actions → \(recordedHash.prefix(12))…")
        if !failures.isEmpty { break }
    }
    if !failures.isEmpty { throw GoldenError.verifyFailed(failures.joined(separator: "; ")) }
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let directory = arguments.first else {
        print("usage: RulesetKitGoldenGen <output-directory> [<ruleset-stem>…]")
        exit(2)
    }
    let out = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    // Find the live corpus relative to this checkout (Resources/Rulesets).
    var corpus = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
    while corpus.pathComponents.count > 1,
        !FileManager.default.fileExists(atPath: corpus.appendingPathComponent("Resources/Rulesets").path)
    { corpus.deleteLastPathComponent() }
    let rulesets = corpus.appendingPathComponent("Resources/Rulesets")

    let games =
        arguments.dropFirst().isEmpty
        ? ["hearts.standard", "euchre.standard", "contract-bridge.rubber", "cribbage.six-card"]
        : Array(arguments.dropFirst())

    for stem in games {
        let path = rulesets.appendingPathComponent("\(stem).ruleset.json").path
        let slug = stem.replacingOccurrences(of: ".", with: "-")
        print("== \(stem)")
        try generate(rulesetPath: path, gameSlug: slug, into: out)
    }
}

do { try main() } catch {
    print("error: \(error)")
    exit(1)
}
