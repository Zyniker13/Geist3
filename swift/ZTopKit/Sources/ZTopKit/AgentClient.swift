// SPDX-License-Identifier: MIT OR Apache-2.0
//! The protocol client the app drives: snapshot and history reads over
//! TLS with a certificate pin, pairing, and the errors it can meet.

import CryptoKit
import Foundation

/// How to reach one agent: host, port, the pin to hold it to, and the
/// bearer token once paired.
public struct HostEndpoint: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    /// `SHA256:<hex>` of the agent's leaf certificate, as the agent
    /// prints at startup. Empty means plain HTTP on loopback.
    public var pin: String
    /// The token from pairing; empty until paired.
    public var token: String

    public init(host: String, port: UInt16, pin: String = "", token: String = "") {
        self.host = host
        self.port = port
        self.pin = pin
        self.token = token
    }

    public var urlBase: String {
        let scheme = pin.isEmpty ? "http" : "https"
        return "\(scheme)://\(host):\(port)"
    }
}

/// Everything the client can fail with, worded for the status line.
public enum AgentError: Error, Equatable {
    /// The leaf certificate's fingerprint did not match the pin.
    case wrongPin
    /// The agent answered 401: the token is missing, stale or revoked.
    case needsPairing
    /// The pairing code did not match, was used up or expired (403).
    case badCode
    /// The agent refused an action (403 on a control plan): control is
    /// off, or the token may only read. Carries the agent's wording.
    case refused(String)
    /// The agent's protocol version is not one this client speaks.
    case protocolMismatch(expected: Int, got: Int)
    /// The body could not be decoded, or the answer was not what was asked.
    case badAnswer(String)
}

/// The protocol version this kit speaks; grows with the Rust crates.
enum Protocol {
    static let version = 1
}

/// The versioned snapshot envelope: `{"protocol": 1, "sample": {...}}`.
public struct SnapshotEnvelope: Codable, Sendable {
    public var protocolVersion: Int
    public var sample: Sample

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case sample
    }
}

/// The versioned history envelope: `{"protocol": 1, "seconds": N, "samples": [...]}`.
public struct HistoryEnvelope: Codable, Sendable {
    public var protocolVersion: Int
    public var seconds: UInt64
    public var samples: [Sample]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case seconds
        case samples
    }
}

/// The pairing reply: `{"protocol": 1, "token": "..."}`.
public struct PairReply: Codable, Sendable {
    public var protocolVersion: Int
    public var token: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case token
    }
}

/// Decodes agent bodies; shared by the tests and the client.
public enum AgentCoding {
    /// The decoder every agent body goes through: snake_case keys map to
    /// camelCase properties, and unknown fields are ignored so an agent
    /// can add fields before this kit learns them.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Pins the leaf certificate by SHA-256 fingerprint: the pin is the
/// trust anchor, exactly as the Rust client pins it (decision 0041).
final class PinTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// Hex SHA-256 of the leaf DER; empty disables TLS pinning (plain HTTP).
    let hexPin: String

    init(hexPin: String) {
        self.hexPin = hexPin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard leafMatchesPin(trust: trust, hexPin: hexPin) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // The pin matched: it is the trust anchor. Presenting the trust
        // as its own credential accepts the self-signed certificate.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// SHA-256 of the leaf certificate, lowercase hex without separators.
func leafFingerprint(trust: SecTrust) -> String? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leaf = chain.first
    else { return nil }
    let der = SecCertificateCopyData(leaf) as Data
    let digest = SHA256.hash(data: der)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// True when the trust's leaf hashes to exactly the pin's hex part.
func leafMatchesPin(trust: SecTrust, hexPin: String) -> Bool {
    let hex = hexPin.lowercased()
    let expected = hex.hasPrefix("sha256:") ? String(hex.dropFirst("sha256:".count)) : hex
    guard expected.count == 64, let fingerprint = leafFingerprint(trust: trust) else { return false }
    return fingerprint == expected
}

/// Parses a pin string the agent prints: `SHA256:<64 hex>`, case-insensitive.
public func parsePin(_ pin: String) -> String? {
    let lower = pin.lowercased()
    guard lower.hasPrefix("sha256:") else { return nil }
    let hex = String(lower.dropFirst("sha256:".count))
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    return "SHA256:\(hex)"
}

/// The async protocol client for one agent.
public final class AgentClient: @unchecked Sendable {
    public let endpoint: HostEndpoint
    private let session: URLSession

    /// A client for one endpoint. TLS endpoints are pinned through the
    /// session's delegate; loopback HTTP needs no pin.
    public init(endpoint: HostEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        let delegate = PinTrustDelegate(hexPin: endpoint.pin)
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// `GET /v1/snapshot`: the agent's latest sample. Through a hub,
    /// `host` names one of the hub's agents (`?host=`, decision 0048);
    /// a direct agent call leaves it nil.
    public func snapshot(host: String? = nil) async throws -> Sample {
        let envelope: SnapshotEnvelope = try await get(Self.path("/v1/snapshot", host: host))
        return envelope.sample
    }

    /// `GET /v1/hosts`: what the hub watches and how fresh each one
    /// is. Served by the hub, not by an agent.
    public func hosts() async throws -> HubHosts {
        try await get("/v1/hosts")
    }

    /// `GET /v1/history?seconds=N`: up to the last N seconds of
    /// samples. Through a hub, `?host=` selects the machine and the
    /// samples come from the hub's own store.
    public func history(seconds: UInt64, host: String? = nil) async throws -> [Sample] {
        let envelope: HistoryEnvelope = try await get(Self.path("/v1/history?seconds=\(seconds)", host: host))
        return envelope.samples
    }

    /// `GET /v1/processes`: the latest sample's process list.
    public func processes() async throws -> [Process] {
        let envelope: ProcessesEnvelope = try await get("/v1/processes")
        return envelope.processes
    }

    /// `GET /v1/control`: this agent's signal catalog — the names and
    /// numbers ITS platform uses, so a signal is sent by the target's
    /// numbering, never the client's.
    public func signalCatalog() async throws -> [SignalEntry] {
        let reply: SignalCatalogReply = try await get("/v1/control")
        return reply.signals
    }

    /// `POST /v1/control`: run one action on the pids. A refusal (the
    /// agent disallows control, or the token may only read) comes back
    /// as [`AgentError.refused`] with the agent's wording.
    public func control(pids: [UInt32], action: ControlAction) async throws -> [ControlResult] {
        var request = URLRequest(url: URL(string: "\(endpoint.urlBase)/v1/control")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.token.isEmpty {
            request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(ControlWire(pids: pids, action: action))
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 403 {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AgentError.refused(body)
        }
        try Self.checkStatus(response, data: data)
        return try Self.decode(ControlReply.self, from: data).results
    }

    /// The control body the protocol carries: pids plus the externally
    /// tagged action.
    private struct ControlWire: Encodable {
        var pids: [UInt32]
        var action: ControlAction
    }

    /// `POST /v1/pair`: trade the agent's pairing code for a token.
    /// Works over TLS; a plaintext pairing on loopback also works, but
    /// the app only pairs over TLS (decision 0041: pin first, then pair).
    public static func pair(endpoint: HostEndpoint, code: String) async throws -> String {
        let client = AgentClient(endpoint: endpoint)
        var request = URLRequest(url: URL(string: "\(endpoint.urlBase)/v1/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        let (data, response) = try await client.session.data(for: request)
        try Self.checkStatus(response, data: data)
        let reply = try Self.decode(PairReply.self, from: data)
        return reply.token
    }

    // MARK: internals

    /// Appends the hub's machine selector: `&host=name` after an
    /// existing query, `?host=name` otherwise, percent-encoded.
    static func path(_ base: String, host: String?) -> String {
        guard let host, !host.isEmpty else { return base }
        let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)host=\(encoded)"
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(endpoint.urlBase)\(path)")!)
        if !endpoint.token.isEmpty {
            request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data)
        return try Self.decode(T.self, from: data)
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.badAnswer("no HTTP answer")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw AgentError.needsPairing
        case 403:
            throw AgentError.badCode
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AgentError.badAnswer("HTTP \(http.statusCode): \(body)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try AgentCoding.decoder.decode(type, from: data)
        } catch {
            throw AgentError.badAnswer("unreadable body: \(error)")
        }
    }
}

extension SnapshotEnvelope {
    /// Rejects a snapshot whose protocol is not one this kit speaks.
    public func checked() throws -> Sample {
        guard protocolVersion == Protocol.version else {
            throw AgentError.protocolMismatch(expected: Protocol.version, got: protocolVersion)
        }
        return sample
    }
}
