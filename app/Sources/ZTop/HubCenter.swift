// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
#if os(macOS)
import ServiceManagement
#endif
import ZTopKit

#if os(macOS)
/// The hub's state directory under the user's Application Support:
/// where the hub CLI reads its default agents.json and writes its
/// history database, tokens and certificate. The app writes the
/// agent list here so the hub needs no arguments beyond the port.
enum HubPaths {
    /// `~/Library/Application Support/ztop` (the app's own directory).
    static func stateDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ztop", isDirectory: true)
    }

    /// Writes the hub's default agents.json from the app's saved
    /// hosts. The file carries the agents' bearer tokens — the hub
    /// reads with the user's authority — so it is written 0600
    /// (decision 0054). Every saved host is listed; an unpaired one
    /// simply polls as unreachable until it is paired.
    static func writeAgentsFile(records: [HostRecord]) throws -> URL {
        let dir = stateDirectory().appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agents.json")
        let specs = records.map { record in
            HubAgentSpec(
                name: record.name,
                target: "\(record.host):\(record.port)",
                pin: record.pin,
                token: record.token
            )
        }
        let data = try HubAgentsFile(agents: specs).jsonData()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }
}

/// Runs the hub the way the login item would: the embedded ztop
/// binary with the shared `HubPlan` arguments. Used by the "run now"
/// button and by the recorded-run hook; the login item itself is
/// launchd's job through `HubInstaller`.
@MainActor
final class HubRunner: ObservableObject {
    /// Nil when the hub is not running; the app owns the child, so
    /// quitting the app stops a hub started this way (the login item
    /// outlives the app instead).
    @Published private(set) var running = false
    @Published var lastError: String?
    /// The pairing code the hub printed at startup, if any. Pairing
    /// with the hub is how a client earns a read token; the hub
    /// screen shows it so the user can hand it to another client.
    @Published private(set) var pairingCode: String?
    /// The hub's TLS fingerprint as the hub printed it, the same pin
    /// an outside client would verify (decision 0041: pin, then pair).
    @Published private(set) var fingerprint: String?

    /// How the hub's own stdout names its pairing code, so the line
    /// can be parsed without matching the whole wording.
    static let pairingPrefix = "Pairing code: "
    static let fingerprintPrefix = "TLS fingerprint: "

    private var process: Foundation.Process?
    private let binaryURL: URL?

    /// The embedded binary sits beside the app's own executable in
    /// `Contents/MacOS/ztop-embedded`, copied in by the build script.
    init() {
        binaryURL = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ztop-embedded")
    }

    /// Starts the hub; a hub already running is left alone.
    func start(port: UInt16) {
        guard !running, let binaryURL else { return }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            lastError = "the hub binary is not in this app bundle"
            return
        }
        let process = Foundation.Process()
        process.executableURL = binaryURL
        process.arguments = HubPlan.arguments(port: port)
        // The hub reads its state under the user's home like every
        // other ztop process; nothing else needs the environment.
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            lastError = "could not start the hub: \(error.localizedDescription)"
            return
        }
        self.process = process
        running = true
        pairingCode = nil
        fingerprint = nil
        readStartupLines(from: stdout.fileHandleForReading)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.running = false
            }
        }
    }

    /// Lifts the pairing code and fingerprint out of the hub's
    /// startup output; both are printed within the first second.
    private func readStartupLines(from handle: FileHandle) {
        Task { [weak self] in
            // A read error (the hub stopping) simply ends the loop.
            for try await line in handle.bytes.lines {
                guard let self else { return }
                if line.hasPrefix(Self.pairingPrefix) {
                    let rest = line.dropFirst(Self.pairingPrefix.count)
                    self.pairingCode = rest.split(separator: " ").first.map(String.init)
                } else if line.hasPrefix(Self.fingerprintPrefix) {
                    self.fingerprint = String(line.dropFirst(Self.fingerprintPrefix.count))
                }
            }
        }
    }

    /// Stops a hub this app started; a hub started by launchd is not
    /// touched (the installer owns that one).
    func stop() {
        guard let process else { return }
        process.terminate()
    }

    /// The hub's token lives in the Keychain like every other token
    /// (decision 0047), under the fixed name `hub`.
    var hasHubToken: Bool {
        !(TokenStore.load(for: "hub", port: HubPlan.defaultPort) ?? "").isEmpty
    }

    /// A client already authenticated against this hub, pinned to
    /// the fingerprint the hub printed. Reads fail with 401 until
    /// `pairWithHub` has run once.
    func client(port: UInt16) -> AgentClient {
        let token = TokenStore.load(for: "hub", port: port) ?? ""
        return AgentClient(endpoint: HostEndpoint(
            host: "127.0.0.1",
            port: port,
            pin: fingerprint ?? "",
            token: token
        ))
    }

    /// Waits for the hub's pairing code and trades it for a token,
    /// which is then stored for every later read. A hub already
    /// paired (token present) is left alone. Returns whether a token
    /// is held afterwards.
    @discardableResult
    func pairWithHub(port: UInt16) async -> Bool {
        if hasHubToken { return true }
        // The code is printed in the first second of the hub's life;
        // give the startup a moment before giving up.
        for _ in 0..<40 {
            if pairingCode != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let code = pairingCode else {
            lastError = "the hub did not print a pairing code"
            return false
        }
        let endpoint = HostEndpoint(host: "127.0.0.1", port: port, pin: fingerprint ?? "")
        do {
            let token = try await AgentClient.pair(endpoint: endpoint, code: code)
            try TokenStore.save(token, for: "hub", port: port)
            return true
        } catch {
            lastError = "pairing with the hub failed: \(error)"
            return false
        }
    }
}

/// Installs and removes the hub's login item: the plist is written
/// into the app's own bundle (possible while the bundle is unsigned;
/// decision 0054 records the signed-bundle caveat for packaging) and
/// handed to SMAppService. Registration itself is never exercised in
/// recorded checks on this machine — the operating rules forbid
/// installing launchd services here — so the tests cover the data
/// the installer writes, and the SMAppService calls are the thin,
/// untested skin over them.
@MainActor
final class HubInstaller: ObservableObject {
    static let plistName = "dev.ztop.hub.plist"

    @Published private(set) var status: SMAppService.Status = .notRegistered

    private let service = SMAppService.agent(plistName: HubInstaller.plistName)

    /// Whether the login item is registered right now.
    var registered: Bool {
        switch status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    func refresh() {
        status = service.status
    }

    /// Writes the current plist into the app bundle and registers it.
    /// `stateDir` is the hub's state directory (agents.json, history
    /// database, logs); the caller has already written the agent list.
    func install(binaryPath: String, stateDir: String, port: UInt16) throws {
        let bundle = Bundle.main
        guard let executableURL = bundle.executableURL else {
            throw HubError.noBundle
        }
        // .../ZTop.app/Contents/MacOS -> .../ZTop.app/Contents.
        let contents = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let agents = contents.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let xml = HubPlan.plistXML(binaryPath: binaryPath, stateDir: stateDir, port: port)
        try Data(xml.utf8).write(
            to: agents.appendingPathComponent(Self.plistName),
            options: .atomic
        )
        try service.register()
        refresh()
    }

    /// Removes the login item and the plist written for it.
    func uninstall() throws {
        try service.unregister()
        if let agents = Bundle.main.resourceURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Library/LaunchAgents")
        {
            try? FileManager.default.removeItem(
                at: agents.appendingPathComponent(Self.plistName)
            )
        }
        refresh()
    }

    enum HubError: Error {
        case noBundle
    }
}
#endif
