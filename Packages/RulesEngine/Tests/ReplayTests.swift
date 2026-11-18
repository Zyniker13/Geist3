import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine
import Testing
@_spi(HostOnly) import ToyGame

/// The golden replay file format (human-readable, version-stable):
/// intents as "play:<raw CardID>"; hashes as lowercase hex.
struct GoldenReplay: Codable {
    let format: String
    let rulesetHash: String
    let seed: UInt64
    let seatCount: Int
    let actions: [ActionLine]
    let finalStateHash: String

    struct ActionLine: Codable {
        let seat: Int
        let intent: String
        let version: UInt64
    }
}

@Suite("RulesEngine — Replays (§10.4)")
struct ReplayTests {

    static func fixturesDirectory() -> URL {
        // Anchor on the test source file so the fixtures resolve regardless of
        // the process working directory (macOS swift test cwd, iOS simulator
        // app sandbox, or an xcodebuild invocation elsewhere).
        // <package>/Tests/ReplayTests.swift → <package>/Tests/Fixtures/Replays
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        return
            packageRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Replays", isDirectory: true)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func parseIntent(_ text: String) throws -> ActionIntent {
        if text.hasPrefix("play:") {
            let raw = UInt16(text.dropFirst(5))
            guard let raw else { throw ReplayFormatError.badIntent(text) }
            return .play(CardID(raw))
        }
        if text == "confirm" { return .confirm }
        throw ReplayFormatError.badIntent(text)
    }

    enum ReplayFormatError: Error { case badIntent(String) }

    static func decode(_ data: Data) throws -> (GoldenReplay, Replay) {
        let golden = try JSONDecoder().decode(GoldenReplay.self, from: data)
        var actions: [LoggedAction] = []
        for line in golden.actions {
            let intent = try parseIntent(line.intent)
            actions.append(LoggedAction(seat: Seat(line.seat), intent: intent, version: line.version))
        }
        let replay = Replay(rulesetHash: Data(), seed: golden.seed, seatCount: golden.seatCount, actions: actions)
        return (golden, replay)
    }

    @Test func twentyGoldenReplaysMatch() throws {
        let engine = ToyGame.engine()
        let directory = ReplayTests.fixturesDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count == 20, "expected 20 golden replays, found \(files.count)")
        for file in files {
            let (golden, replay) = try ReplayTests.decode(try Data(contentsOf: file))
            #expect(golden.format == "parlor.replay/1", "\(file.lastPathComponent): bad format")
            #expect(
                golden.rulesetHash == ReplayTests.hex(engine.rulesetHash),
                "\(file.lastPathComponent): ruleset hash mismatch — the toy game configuration changed")
            let finalState = try engine.replay(replay)
            let hash = ReplayTests.hex(Engine.finalStateHash(finalState))
            #expect(hash == golden.finalStateHash)
        }
    }

    /// Determinism through replay: replaying reproduces the played state.
    @Test func replayMatchesPlayedGame() throws {
        let engine = ToyGame.engine()
        let played = try ToyGame.play(engine: engine, seed: 777)
        let replay = Replay(rulesetHash: engine.rulesetHash, seed: 777, seatCount: 2, actions: played.history)
        let replayed = try engine.replay(replay)
        #expect(replayed == played)
        #expect(Engine.finalStateHash(replayed) == Engine.finalStateHash(played))
    }

    /// A truncated replay diverges (the hash catches a shortened log).
    @Test func truncatedReplayChangesHash() throws {
        let engine = ToyGame.engine()
        let played = try ToyGame.play(engine: engine, seed: 555)
        var actions = played.history
        actions.removeLast()
        let tampered = Replay(rulesetHash: engine.rulesetHash, seed: 555, seatCount: 2, actions: actions)
        let replayed = try engine.replay(tampered)
        #expect(Engine.finalStateHash(replayed) != Engine.finalStateHash(played))
    }
}
