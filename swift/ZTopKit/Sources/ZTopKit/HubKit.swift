// SPDX-License-Identifier: MIT OR Apache-2.0
//! The data the app needs to run the hub on this Mac: the agent list
//! the hub polls from, and the launchd plist that runs it at login.
//! The ServiceManagement calls and the process spawning live in the
//! app; everything here is pure data so the tests can hold the exact
//! shapes the hub and launchd accept.

import Foundation

/// One agent the hub polls, exactly as the hub's agents.json names it:
/// `target` is `host:port`, a `pin` (`SHA256:<64 hex>`) makes the poll
/// TLS and a `token` authenticates the hub's reads of that agent.
/// Empty `pin` or `token` are OMITTED from the file, not written as
/// empty strings: the hub validates a present pin against
/// `SHA256:<64 hex>`, and an empty token would silently mean none.
public struct HubAgentSpec: Hashable, Sendable {
    public var name: String
    public var target: String
    public var pin: String
    public var token: String

    public init(name: String, target: String, pin: String = "", token: String = "") {
        self.name = name
        self.target = target
        self.pin = pin
        self.token = token
    }
}

extension HubAgentSpec: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, target, pin, token
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        target = try container.decode(String.self, forKey: .target)
        pin = try container.decodeIfPresent(String.self, forKey: .pin) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(target, forKey: .target)
        if !pin.isEmpty {
            try container.encode(pin, forKey: .pin)
        }
        if !token.isEmpty {
            try container.encode(token, forKey: .token)
        }
    }
}

/// The hub's whole agent list, as its JSON file stores it:
/// `{"agents": [...]}`.
public struct HubAgentsFile: Codable, Hashable, Sendable {
    public var agents: [HubAgentSpec]

    public init(agents: [HubAgentSpec]) {
        self.agents = agents
    }

    /// The bytes for the hub's agents.json. Keys are sorted so the
    /// file is stable across writes and the tests can compare it.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Decodes a hub agents.json back (round-trip checks).
    public static func decode(_ data: Data) throws -> HubAgentsFile {
        try JSONDecoder().decode(HubAgentsFile.self, from: data)
    }
}

/// Everything needed to start the hub the same way from two places:
/// the app's "run now" button spawns it directly, and the login-item
/// plist embeds the same argument list, so both paths run one hub
/// with one configuration.
public enum HubPlan {
    /// The loopback port the hub serves by default, mirroring the
    /// hub CLI's `--port` default (7101, the agent's 7100 + 1).
    public static let defaultPort: UInt16 = 7101

    /// The argument list after the binary path: the hub serving TLS
    /// with pairing on, bound to loopback. A wider bind would put the
    /// hub on the network; 0.1.0 keeps it loopback-only (the recorded
    /// iPad check runs on the same Mac), and the hub CLI still
    /// accepts a wider bind by hand.
    public static func arguments(port: UInt16) -> [String] {
        [
            "hub",
            "--port", String(port),
            "--bind", "127.0.0.1",
            "--tls",
            "--pair",
        ]
    }

    /// The launchd plist XML that runs the hub at login: the same
    /// argument list as `arguments(port:)`, `KeepAlive` so a crash
    /// restarts the hub, and logs under the hub's state directory.
    /// The app writes this into its own bundle's
    /// `Contents/Library/LaunchAgents/dev.ztop.hub.plist` before
    /// registering it with SMAppService; the bundle is unsigned
    /// today, which is what makes that write possible (decision 0054
    /// records the signed-bundle caveat for packaging).
    public static func plistXML(binaryPath: String, stateDir: String, port: UInt16) -> String {
        let arguments = [binaryPath] + arguments(port: port)
        let program = arguments
            .map { "<string>\(xmlEscaped($0))</string>" }
            .joined(separator: "\n    ")
        let log = "\(stateDir)/hub.log"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>dev.ztop.hub</string>
            <key>ProgramArguments</key>
            <array>
                \(program)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(xmlEscaped(log))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscaped(log))</string>
        </dict>
        </plist>
        """
    }

    /// Escapes the five XML characters for text content, so a path
    /// with `&`, `<` or a quote cannot break the plist.
    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// One watched agent as the hub's `/v1/hosts` reports it: the
/// configured name and target plus how the latest poll went. `state`
/// is the hub's own wording ("live", "stale", "unreachable").
public struct HubHostStatus: Codable, Hashable, Sendable {
    public var name: String
    public var target: String
    public var state: String
    /// When the last good poll finished, in milliseconds since the
    /// Unix epoch; nil while no poll has succeeded yet.
    public var lastMs: UInt64?
    /// The failing poll's wording, if the latest one failed.
    public var error: String?

    public init(
        name: String,
        target: String,
        state: String,
        lastMs: UInt64? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.target = target
        self.state = state
        self.lastMs = lastMs
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case name, target, state
        case lastMs = "last_ms"
        case error
    }
}

/// The `/v1/hosts` envelope: `{"protocol": 1, "hosts": [...]}`.
public struct HubHosts: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var hosts: [HubHostStatus]

    public init(protocolVersion: Int, hosts: [HubHostStatus]) {
        self.protocolVersion = protocolVersion
        self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case hosts
    }
}
