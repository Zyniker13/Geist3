// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import ZTopKit

/// The client against a real hub: two real agents behind it, the
/// hub's agents file written from their paired tokens (the same file
/// the app writes), then the fleet read back through the hub the way
/// a client that only knows the hub — the iPad — sees it. Skipped
/// with a note where the binary has not been built (check.sh's Rust
/// stages build it before the Swift ones).
struct LiveHubTests {
    /// Starts a hub watching the named agents and returns its
    /// endpoint, pairing code, process and isolated home once both
    /// startup lines have been read. The agents file is written to
    /// the state-dir default under the hub's HOME before it starts,
    /// so the hub needs no arguments beyond the port.
    static func startHub(agents: [HubAgentSpec]) throws -> (endpoint: HostEndpoint, code: String, process: Foundation.Process, home: URL) {
        let binary = try #require(LiveAgentTests.agentBinary(), "no ztop binary; run the Rust build first")
        let port = UInt16.random(in: 20000...45000)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztop-hub-\(UUID().uuidString)", isDirectory: true)
        let hubDir = home.appendingPathComponent("Library/Application Support/ztop/hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hubDir, withIntermediateDirectories: true)
        let file = HubAgentsFile(agents: agents)
        let data = try JSONEncoder().encode(file)
        try data.write(to: hubDir.appendingPathComponent("agents.json"), options: .atomic)
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["hub", "--port", String(port), "--bind", "127.0.0.1", "--tls", "--pair"]
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
            Issue.record("the hub never printed a code and fingerprint")
            throw AgentError.badAnswer("no startup lines")
        }
        return (HostEndpoint(host: "127.0.0.1", port: port, pin: pin), code, process, home)
    }

    @Test func theClientReadsTheFleetThroughOneHub() async throws {
        // Two real agents, paired: the hub needs their tokens.
        let a = try LiveAgentTests.startAgent()
        let b = try LiveAgentTests.startAgent()
        defer { a.process.terminate(); b.process.terminate() }
        let tokenA = try await AgentClient.pair(endpoint: a.endpoint, code: a.code)
        let tokenB = try await AgentClient.pair(endpoint: b.endpoint, code: b.code)

        let hub = try Self.startHub(agents: [
            HubAgentSpec(name: "host-a", target: "127.0.0.1:\(a.endpoint.port)", pin: a.endpoint.pin, token: tokenA),
            HubAgentSpec(name: "host-b", target: "127.0.0.1:\(b.endpoint.port)", pin: b.endpoint.pin, token: tokenB),
        ])
        defer { hub.process.terminate() }

        // Pair with the hub like any client would (the printed code).
        let hubToken = try await AgentClient.pair(endpoint: hub.endpoint, code: hub.code)
        let client = AgentClient(endpoint: HostEndpoint(
            host: "127.0.0.1",
            port: hub.endpoint.port,
            pin: hub.endpoint.pin,
            token: hubToken
        ))

        // The hub polls on its own cadence (2 s): both machines turn
        // live within a few polls.
        let sawBoth = await LiveAgentTests.waitUpTo(30) {
            guard let hosts = try? await client.hosts() else { return false }
            return hosts.hosts.count == 2 && hosts.hosts.allSatisfy { $0.state == "live" }
        }
        #expect(sawBoth, "the hub never saw both agents live")

        // A snapshot through the hub, one machine at a time: the hub
        // answers with the agent's sample shape.
        let sample = try await client.snapshot(host: "host-a")
        #expect(sample.memory.total.value > 0, "a decoded sample should know its memory")

        // History through the hub comes from its own store.
        let history = try await client.history(seconds: 120, host: "host-b")
        #expect(!history.isEmpty, "the hub should have filed at least one sample")

        // An unknown name is the hub's 404 wording, not a crash.
        do {
            _ = try await client.snapshot(host: "no-such-host")
            Issue.record("an unknown host should not answer with a sample")
        } catch let error as AgentError {
            guard case let .badAnswer(text) = error else {
                Issue.record("unexpected error for an unknown host: \(error)")
                return
            }
            #expect(text.contains("404"), "the hub's 404 should come through: \(text)")
        }
    }

    @Test func theMachineSelectorIsEncodedIntoTheQuery() {
        #expect(AgentClient.path("/v1/snapshot", host: nil) == "/v1/snapshot")
        #expect(AgentClient.path("/v1/snapshot", host: "host-a") == "/v1/snapshot?host=host-a")
        #expect(AgentClient.path("/v1/history?seconds=60", host: "host b") == "/v1/history?seconds=60&host=host%20b")
    }
}
