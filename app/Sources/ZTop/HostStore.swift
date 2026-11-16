// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import ZTopKit

/// One saved host: where its agent lives and the paired token, if any.
/// Records persist as JSON in Application Support; the Keychain move
/// for tokens arrives with its own M5 batch.
struct HostRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    /// The `SHA256:<hex>` pin; empty means plain HTTP on loopback.
    var pin: String
    /// The paired bearer token; empty until the host is paired.
    var token: String

    var endpoint: HostEndpoint {
        HostEndpoint(host: host, port: port, pin: pin, token: token)
    }
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
              let decoded = try? JSONDecoder().decode([HostRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
    func add(name: String, host: String, port: UInt16, pin: String, code: String) async throws -> HostRecord {
        var record = HostRecord(name: name, host: host, port: port, pin: pin, token: "")
        if !code.isEmpty {
            let endpoint = HostEndpoint(host: host, port: port, pin: pin, token: "")
            record.token = try await AgentClient.pair(endpoint: endpoint, code: code)
        }
        records.append(record)
        save()
        return record
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
    /// delays the others.
    private func pollOnce() async {
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { [weak self] in
                    let sample = try? await AgentClient(endpoint: record.endpoint).snapshot()
                    await self?.apply(sample: sample, to: record)
                }
            }
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
