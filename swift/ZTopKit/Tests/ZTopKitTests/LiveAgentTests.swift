// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import ZTopKit

/// The client against a real agent process, spawned by the tests:
/// pair with the code the agent prints, read a pinned snapshot, and
/// meet a wrong pin as a handshake failure. Skipped with a note where
/// the binary has not been built (it is built by check.sh's Rust
/// stages before the Swift ones).
struct LiveAgentTests {
    /// The agent binary to spawn: `$ZTOP_BIN` or the workspace's
    /// `target/debug/ztop` relative to this package.
    static func agentBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["ZTOP_BIN"], !env.isEmpty {
            return env
        }
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZTopKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ZTopKit
            .deletingLastPathComponent()   // swift
            .deletingLastPathComponent()   // the workspace root
            .appendingPathComponent("target/debug/ztop")
        let path = candidate.path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Spawns `ztop agent --tls --pair` on a random high port and
    /// returns the endpoint, the pairing code, the process and the
    /// agent's isolated home directory once both startup lines have
    /// been read. The agent runs with its own HOME so concurrent
    /// tests never share the token store, and nothing lands in the
    /// user's real state dir. The caller owns the process and stops
    /// it. A port collision surfaces as missing startup lines and an
    /// honest test failure; the next run rolls again.
    static func startAgent() throws -> (endpoint: HostEndpoint, code: String, process: Foundation.Process, home: URL) {
        let binary = try #require(agentBinary(), "no ztop binary; run the Rust build first")
        let port = UInt16.random(in: 20000...45000)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztop-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "agent", "--tls", "--pair", "--no-advertise", "--port", String(port),
        ]
        process.environment = ["HOME": home.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()

        var code: String?
        var pin: String?
        let deadline = Date().addingTimeInterval(30)
        let handle = out.fileHandleForReading
        var buffer = Data()
        while Date() < deadline, (code == nil || pin == nil) {
            let chunk = handle.availableData
            if chunk.isEmpty { usleep(50_000); continue }
            buffer.append(chunk)
            let text = String(decoding: buffer, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if line.hasPrefix("Pairing code: ") {
                    code = line.dropFirst("Pairing code: ".count)
                        .split(separator: " ").first.map(String.init)
                }
                if line.hasPrefix("TLS fingerprint: ") {
                    pin = String(line.dropFirst("TLS fingerprint: ".count))
                }
            }
        }
        guard let code, let pin else {
            process.terminate()
            Issue.record("the agent never printed a code and fingerprint")
            throw AgentError.badAnswer("no startup lines")
        }
        return (HostEndpoint(host: "127.0.0.1", port: port, pin: pin), code, process, home)
    }

    /// Restarts the same agent on the same port WITHOUT a new pairing
    /// code: tokens persist in the agent's own state dir (its HOME),
    /// so a client that paired before the restart keeps reading after
    /// it.
    static func restartAgent(endpoint: HostEndpoint, home: URL, binary: String) throws -> Foundation.Process {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "agent", "--tls", "--no-advertise", "--port", String(endpoint.port),
        ]
        process.environment = ["HOME": home.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Polls `body` until it returns true or the deadline passes.
    @discardableResult
    static func waitUpTo(_ seconds: Double, _ body: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await body() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return await body()
    }

    @Test func theClientSurvivesAnAgentRestartWithoutRepairing() async throws {
        let (endpoint, code, agent, home) = try Self.startAgent()
        defer {
            agent.terminate()
            try? FileManager.default.removeItem(at: home)
        }
        let binary = try #require(Self.agentBinary(), "no ztop binary; run the Rust build first")

        // Pair, then read once through the pinned channel.
        let token = try await AgentClient.pair(endpoint: endpoint, code: code)
        var paired = endpoint
        paired.token = token
        let client = AgentClient(endpoint: paired)
        let firstRead = await Self.waitUpTo(15) {
            (try? await client.snapshot()) != nil
        }
        #expect(firstRead, "no sample within 15 s of the first start")

        // The agent dies: reads fail (the host is unreachable).
        agent.terminate()
        agent.waitUntilExit()
        try await Task.sleep(for: .milliseconds(500))
        let downRead = await Self.waitUpTo(5) {
            (try? await client.snapshot()) != nil
        }
        #expect(!downRead, "a stopped agent still answered")

        // The agent comes back on the same port; the saved token still
        // works, so no re-pairing happens.
        let revived = try Self.restartAgent(endpoint: endpoint, home: home, binary: binary)
        defer {
            revived.terminate()
            try? FileManager.default.removeItem(at: home)
        }
        let backRead = await Self.waitUpTo(15) {
            (try? await client.snapshot()) != nil
        }
        #expect(backRead, "the paired token stopped working after the restart")
    }

    @Test func theClientPairsAndReadsAPinnedSnapshot() async throws {
        let (endpoint, code, agent, home) = try Self.startAgent()
        defer {
            agent.terminate()
            try? FileManager.default.removeItem(at: home)
        }

        // Pair over pinned TLS.
        let token = try await AgentClient.pair(endpoint: endpoint, code: code)
        #expect(token.count >= 32)

        // Read with the paired token. The first tick lands a second in,
        // so wait out the agent's warm-up like any honest client does.
        var paired = endpoint
        paired.token = token
        let client = AgentClient(endpoint: paired)
        let sample: Sample = try await {
            var lastError: Error = AgentError.badAnswer("never asked")
            for _ in 0..<40 {
                do {
                    return try await client.snapshot()
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw lastError
        }()
        #expect(!sample.hostname.isEmpty)
        #expect(sample.timestampMs > 0)
        #expect(sample.cpu.busyPercent.count >= 1)

        // History reads too.
        let window = try await client.history(seconds: 60)
        #expect(!window.isEmpty)
    }

    @Test func aWrongPinFailsTheHandshake() async throws {
        let (endpoint, code, agent, home) = try Self.startAgent()
        defer {
            agent.terminate()
            try? FileManager.default.removeItem(at: home)
        }

        // Flip one hex character of the pin.
        var corrupted = endpoint
        var hex = Array(endpoint.pin.dropFirst("SHA256:".count))
        hex[0] = hex[0] == "0" ? "1" : "0"
        corrupted.pin = "SHA256:" + String(hex)

        do {
            _ = try await AgentClient.pair(endpoint: corrupted, code: code)
            Issue.record("the handshake succeeded with a wrong pin")
        } catch {
            // Any failure is right: the pin is the trust anchor.
        }
    }

    @Test func anUnpairedReadIsReportedAsNeedingPairing() async throws {
        let (endpoint, _, agent, home) = try Self.startAgent()
        defer {
            agent.terminate()
            try? FileManager.default.removeItem(at: home)
        }

        let client = AgentClient(endpoint: endpoint)
        do {
            _ = try await client.snapshot()
            Issue.record("an unpaired read succeeded against an enforcing agent")
        } catch let error as AgentError {
            #expect(error == .needsPairing)
        }
    }

    @Test func aBadCodeIsReportedAsBadCode() async throws {
        let (endpoint, _, agent, home) = try Self.startAgent()
        defer {
            agent.terminate()
            try? FileManager.default.removeItem(at: home)
        }

        do {
            _ = try await AgentClient.pair(endpoint: endpoint, code: "000000")
            Issue.record("pairing succeeded with a wrong code")
        } catch let error as AgentError {
            #expect(error == .badCode)
        }
    }
}
