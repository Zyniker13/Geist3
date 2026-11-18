// Golden-replay generator: plays 20 toy-game deals and writes JSON replay
// files into the repository. Run via Tools/make-golden-replays.sh.

import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
@_spi(HostOnly) import ToyGame

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

// Deterministic seed list: 20 fixed seeds.
let seeds: [UInt64] = [
    0, 1, 7, 42, 99, 123, 555, 777, 1024, 2024, 31_337, 65_535,
    100_001, 250_000, 500_001, 750_003, 999_999, 1_234_567, 8_765_432, UInt64.max - 1,
]

let engine = ToyGame.engine()
var out: [String: Data] = [:]

for (index, seed) in seeds.enumerated() {
    let played = try ToyGame.play(engine: engine, seed: seed)
    precondition(played.phase.phaseID == "done", "seed \(seed) did not finish")
    let lines = played.history.map { action -> Golden.Line in
        let intent: String
        switch action.intent {
        case .play(let id): intent = "play:\(id.raw)"
        case .confirm: intent = "confirm"
        default: fatalError("unexpected intent in toy game: \(action.intent)")
        }
        return Golden.Line(seat: action.seat.raw, intent: intent, version: action.version)
    }
    let golden = Golden(
        format: "parlor.replay/1",
        rulesetHash: hex(engine.rulesetHash),
        seed: seed,
        seatCount: 2,
        actions: lines,
        finalStateHash: hex(Engine.finalStateHash(played))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let name = String(format: "toy-high-card-%02d.json", index)
    out[name] = try encoder.encode(golden)
}

let args = CommandLine.arguments
let target = args.count > 1 ? args[1] : "."
for (name, data) in out.sorted(by: { $0.key < $1.key }) {
    let url = URL(fileURLWithPath: target).appendingPathComponent(name)
    try data.write(to: url)
    print("wrote \(url.path)")
}
print("count:", out.count)
