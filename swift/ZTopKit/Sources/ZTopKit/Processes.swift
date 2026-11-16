// SPDX-License-Identifier: MIT OR Apache-2.0
//! The process table the app shows: pure filter and sort rules over the
//! sample's process rows, the control action the protocol carries, and
//! the answers a control call can produce.

import Foundation

/// What the process table can be sorted by. The default view is CPU
/// descending, ties broken by pid ascending, so the order is stable
/// across refreshes.
public enum ProcessSortKey: String, CaseIterable, Sendable {
    case cpu
    case memory
    case pid
    case name
    case user
}

/// Sort direction for [`ProcessTable`].
public enum SortDirection: Sendable, Equatable {
    case ascending
    case descending
}

/// Pure filter and sort rules for one host's process list.
///
/// The search matches a case-insensitive substring of the name or the
/// user, and also a pid whose decimal digits start with the query, so
/// typing `42` finds pid 4242 without hiding name matches. Sorting is
/// stable: equal keys fall back to pid ascending.
public enum ProcessTable {
    /// The rows whose name, user or pid matches `query`; an empty or
    /// whitespace-only query keeps everything.
    public static func filter(_ processes: [Process], query: String) -> [Process] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return processes }
        return processes.filter { row in
            row.name.lowercased().contains(needle)
                || row.user.lowercased().contains(needle)
                || String(row.pid).hasPrefix(needle)
        }
    }

    /// The rows sorted by `key` in `direction`, pid ascending as the
    /// tiebreaker.
    public static func sort(
        _ processes: [Process], by key: ProcessSortKey, direction: SortDirection
    ) -> [Process] {
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Int {
            a < b ? -1 : (a > b ? 1 : 0)
        }
        func primary(_ a: Process, _ b: Process) -> Int {
            switch key {
            case .cpu: return cmp(a.cpuPercent, b.cpuPercent)
            case .memory: return cmp(a.memPercent, b.memPercent)
            case .pid: return cmp(a.pid, b.pid)
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name).rawValue
            case .user: return a.user.localizedCaseInsensitiveCompare(b.user).rawValue
            }
        }
        return processes.sorted { a, b in
            let order = primary(a, b)
            if order == 0 { return a.pid < b.pid }
            return direction == .descending ? order > 0 : order < 0
        }
    }

    /// The default view: CPU descending, ties by pid ascending.
    public static func byCpu(_ processes: [Process]) -> [Process] {
        sort(processes, by: .cpu, direction: .descending)
    }
}

/// One action a control plan carries, mirroring the Rust `Control`
/// enum's wire form (externally tagged: `{"Signal": 15}`).
public enum ControlAction: Equatable, Sendable {
    case signal(Int)
    case renice(Int)

    var wireName: String {
        switch self {
        case .signal: return "Signal"
        case .renice: return "Renice"
        }
    }

    var wireValue: Int {
        switch self {
        case .signal(let number): return number
        case .renice(let delta): return delta
        }
    }
}

extension ControlAction: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(wireValue, forKey: WireKey(name: wireName))
    }

    /// The externally-tagged key is the variant's Rust name.
    struct WireKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(name: String) { self.stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// One pid's answer from a control plan.
public struct ControlResult: Codable, Hashable, Sendable {
    public var pid: UInt32
    public var ok: Bool
    public var error: String?
}

/// The versioned control reply: `{"protocol": 1, "results": [...]}`.
public struct ControlReply: Codable, Sendable {
    public var protocolVersion: Int
    public var results: [ControlResult]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case results
    }
}

/// The agent's signal catalog: `GET /v1/control` answers with the
/// signals THIS agent's platform numbers, so a client never guesses a
/// number across platforms (macOS and Linux number STOP/CONT/TSTP
/// differently).
public struct SignalEntry: Codable, Hashable, Sendable {
    public var name: String
    public var number: Int

    public init(name: String, number: Int) {
        self.name = name
        self.number = number
    }
}

/// The versioned signal-catalog reply: `{"protocol": 1, "signals": [...]}`.
public struct SignalCatalogReply: Codable, Sendable {
    public var protocolVersion: Int
    public var signals: [SignalEntry]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case signals
    }
}

/// The versioned process-list envelope:
/// `{"protocol": 1, "count": N, "processes": [...]}`.
public struct ProcessesEnvelope: Codable, Sendable {
    public var protocolVersion: Int
    public var count: Int
    public var processes: [Process]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case count
        case processes
    }
}
