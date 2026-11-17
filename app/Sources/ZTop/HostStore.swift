// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import ZTopKit

/// One saved host: where its agent lives and the paired token, if any.
/// Records persist as JSON in Application Support; the tokens live in
/// the Keychain, not in the file (decision 0047). A record with
/// `isHub` names a hub instead of an agent: pairing and reads go to
/// the hub, and the fleet it watches shows under its card.
struct HostRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    /// The `SHA256:<hex>` pin; empty means plain HTTP on loopback.
    var pin: String
    /// The paired bearer token; empty until the host is paired.
    var token: String
    /// True when this record names a hub (whose `/v1` surface carries
    /// a whole fleet) rather than one agent.
    var isHub: Bool = false

    var endpoint: HostEndpoint {
        HostEndpoint(host: host, port: port, pin: pin, token: token)
    }
}

/// One machine a hub watches, as the overview shows it: the hub's own
/// name for the agent, the state the hub reports, and the latest
/// sample read through the hub (`?host=`, decision 0048).
struct HubMachine: Identifiable, Hashable {
    var id: String { hubID.uuidString + "/" + name }
    let hubID: UUID
    let name: String
    /// The agent's `host:port` as the hub's config names it.
    var target: String
    var state: HostLive.State = .connecting
    var sample: Sample?
    var lastGood: Date?
    /// The hub's own wording for the last failed poll, if any.
    var error: String?
}

/// The live state of one host as the overview shows it.
struct HostLive {
    enum State: Equatable {
        case connecting
        case live
        case stale
        case unreachable
    }

    var state: State = .connecting
    var sample: Sample?
    /// The wall-clock time the last good sample was read.
    var lastGood: Date?
    var error: AgentError?
}

/// The fleet: saved hosts, their live state, and the pairing flow.
@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var records: [HostRecord] = []
    @Published private(set) var live: [UUID: HostLive] = [:]
    /// The machines the saved hubs watch, keyed by hub record.
    @Published private(set) var hubMachines: [HubMachine] = []

    private var pollTask: Task<Void, Never>?
    private let fileURL: URL

    /// A sample older than this stops counting as live.
    static let staleAfter: TimeInterval = 10
    /// How often every host is polled.
    static let interval: TimeInterval = 2

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ztop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("hosts.json")
        load()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([HostRecord].self, from: data)
        else { return }
        for index in decoded.indices {
            if !decoded[index].token.isEmpty {
                // Migration from the plain-JSON era: move the token
                // into the Keychain and blank it in the file.
                try? TokenStore.save(decoded[index].token, for: decoded[index].host, port: decoded[index].port)
                decoded[index].token = ""
            }
            decoded[index].token = TokenStore.load(for: decoded[index].host, port: decoded[index].port) ?? ""
        }
        records = decoded
        save()
    }

    /// The file never carries tokens: they live in the Keychain
    /// (decision 0047), one generic password per host.
    private func save() {
        let sanitized = records.map { record -> HostRecord in
            var copy = record
            copy.token = ""
            return copy
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        try? data.write(to: fileURL, options: .atomic)
        for record in records where !record.token.isEmpty {
            try? TokenStore.save(record.token, for: record.host, port: record.port)
        }
    }

    // MARK: adding, pairing, forgetting

    /// Testability hook for the recorded runs: launch arguments pair
    /// through the exact same `add` flow the form drives
    /// (`ZTOP_PAIR=name=host:port=pin=code;…`). Existing host:port
    /// records are left alone, so relaunching stays idempotent.
    func seed(from spec: String) async {
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 3)
            guard parts.count == 4 else { continue }
            let name = String(parts[0])
            let address = parts[1].split(separator: ":")
            guard address.count == 2, let port = UInt16(address[1]) else { continue }
            let host = String(address[0])
            let pin = String(parts[2])
            let code = String(parts[3])
            guard !records.contains(where: { $0.host == host && $0.port == port }) else { continue }
            _ = try? await add(name: name, host: host, port: port, pin: pin, code: code)
        }
    }

    /// Adds a host. When `code` is given the host is paired right away;
    /// otherwise the record starts unpaired and the card offers pairing.
    /// A hub record (`isHub`) pairs through the hub's own `/v1/pair`,
    /// whose reply has the agent's shape.
    func add(name: String, host: String, port: UInt16, pin: String, code: String, isHub: Bool = false) async throws -> HostRecord {
        var record = HostRecord(name: name, host: host, port: port, pin: pin, token: "", isHub: isHub)
        if !code.isEmpty {
            let endpoint = HostEndpoint(host: host, port: port, pin: pin, token: "")
            record.token = try await AgentClient.pair(endpoint: endpoint, code: code)
        }
        records.append(record)
        save()
        return record
    }

    /// Seeds a hub record the same way `seed` seeds agents
    /// (`ZTOP_HUB_PAIR=name=host:port=pin=code`): one entry, paired
    /// through the hub's own pairing flow. Existing records for the
    /// same host:port are left alone, so relaunching stays idempotent.
    func seedHub(from spec: String) async {
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 3)
            guard parts.count == 4 else { continue }
            let name = String(parts[0])
            let address = parts[1].split(separator: ":")
            guard address.count == 2, let port = UInt16(address[1]) else { continue }
            let host = String(address[0])
            let pin = String(parts[2])
            let code = String(parts[3])
            guard !records.contains(where: { $0.host == host && $0.port == port }) else { continue }
            _ = try? await add(name: name, host: host, port: port, pin: pin, code: code, isHub: true)
        }
    }

    /// Pairs an existing (unpaired) host with a code.
    func pair(_ record: HostRecord, code: String) async throws {
        var updated = record
        updated.token = try await AgentClient.pair(endpoint: record.endpoint, code: code)
        replace(updated)
    }

    func remove(_ record: HostRecord) {
        records.removeAll { $0.id == record.id }
        live[record.id] = nil
        if record.isHub {
            hubMachines.removeAll { $0.hubID == record.id }
        }
        TokenStore.delete(for: record.host, port: record.port)
        save()
    }

    private func replace(_ updated: HostRecord) {
        if let index = records.firstIndex(where: { $0.id == updated.id }) {
            records[index] = updated
        }
        save()
    }

    // MARK: polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// Polls every host concurrently: a slow or unreachable host never
    /// delays the others. A hub record fans out into its machines
    /// instead of sampling itself.
    private func pollOnce() async {
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { [weak self] in
                    if record.isHub {
                        await self?.pollHub(record)
                    } else {
                        let sample = try? await AgentClient(endpoint: record.endpoint).snapshot()
                        await self?.apply(sample: sample, to: record)
                    }
                }
            }
        }
    }

    /// Reads one hub's fleet: the hub's own `/v1/hosts` is the
    /// authority for each machine's state (its wording: live, stale,
    /// unreachable), then each machine's latest sample comes through
    /// `?host=`. Machines the hub no longer lists disappear.
    private func pollHub(_ record: HostRecord) async {
        let client = AgentClient(endpoint: record.endpoint)
        guard let hosts = try? await client.hosts() else {
            // The hub itself is unreachable: every machine it kept
            // goes unreachable with the hub's own freshness gone.
            hubMachines = hubMachines.map { machine in
                guard machine.hubID == record.id else { return machine }
                var down = machine
                down.state = .unreachable
                down.error = "the hub is unreachable"
                return down
            }
            return
        }
        var fresh: [HubMachine] = []
        for status in hosts.hosts {
            var machine = hubMachines.first { $0.hubID == record.id && $0.name == status.name }
                ?? HubMachine(hubID: record.id, name: status.name, target: status.target)
            machine.target = status.target
            machine.error = status.error
            machine.state = Self.machineState(status.state)
            if let sample = try? await client.snapshot(host: status.name) {
                machine.sample = sample
                machine.lastGood = Date()
            }
            fresh.append(machine)
        }
        hubMachines.removeAll { $0.hubID == record.id }
        hubMachines.append(contentsOf: fresh)
    }

    /// The hub's state word, mapped to the overview's own states.
    static func machineState(_ word: String) -> HostLive.State {
        switch word {
        case "live": .live
        case "stale": .stale
        default: .unreachable
        }
    }

    private func apply(sample: Sample?, to record: HostRecord) {
        var entry = live[record.id] ?? HostLive()
        if let sample {
            entry.state = .live
            entry.sample = sample
            entry.lastGood = Date()
            entry.error = nil
        } else if let lastGood = entry.lastGood, Date().timeIntervalSince(lastGood) < Self.staleAfter {
            // A transient failure inside the freshness window: keep
            // showing the last good sample, flagged stale.
            entry.state = .stale
        } else {
            entry.state = .unreachable
        }
        live[record.id] = entry
    }
}
