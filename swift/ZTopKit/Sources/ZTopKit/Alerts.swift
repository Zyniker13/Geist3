// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation

/// What an alert rule watches. `threshold` is a percent for cpu,
/// memory and disk and an absolute value for load; `unreachable`
/// rules have no threshold at all.
public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case cpu
    case memory
    case load
    case disk
    case unreachable

    /// Whether the kind uses `AlertRule.threshold`.
    public var usesThreshold: Bool { self != .unreachable }
}

/// One saved alert rule. `hostID == nil` means the rule watches every
/// host in the fleet; otherwise only that host.
public struct AlertRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostID: UUID?
    public var kind: AlertKind
    public var threshold: Double
    /// How long the condition must hold before the alert fires.
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(), name: String, hostID: UUID? = nil,
        kind: AlertKind, threshold: Double, duration: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.kind = kind
        self.threshold = threshold
        self.duration = duration
    }

    /// Human text for the rule's condition, e.g.
    /// "CPU above 90% for 5m" or "any host: unreachable for 1m".
    public var describe: String {
        let target = hostID == nil ? "any host: " : ""
        let durationText = Self.describeDuration(duration)
        switch kind {
        case .cpu:
            return "\(target)CPU above \(Int(threshold))% for \(durationText)"
        case .memory:
            return "\(target)memory above \(Int(threshold))% for \(durationText)"
        case .load:
            return "\(target)load above \(String(format: "%.1f", threshold)) for \(durationText)"
        case .disk:
            return "\(target)disk above \(Int(threshold))% for \(durationText)"
        case .unreachable:
            return "\(target)unreachable for \(durationText)"
        }
    }

    static func describeDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds / 60))m"
        }
        return "\(Int(seconds))s"
    }
}

/// Something the engine decided: a rule fired for a host, or an alert
/// cleared again.
public enum AlertEvent: Equatable, Sendable {
    case fired(ruleID: UUID, hostID: UUID, ruleName: String)
    case cleared(ruleID: UUID, hostID: UUID, ruleName: String)

    public var ruleID: UUID {
        switch self {
        case .fired(let ruleID, _, _): return ruleID
        case .cleared(let ruleID, _, _): return ruleID
        }
    }

    public var hostID: UUID {
        switch self {
        case .fired(_, let hostID, _): return hostID
        case .cleared(_, let hostID, _): return hostID
        }
    }

    public var ruleName: String {
        switch self {
        case .fired(_, _, let ruleName): return ruleName
        case .cleared(_, _, let ruleName): return ruleName
        }
    }

    public var isFired: Bool {
        switch self {
        case .fired: return true
        case .cleared: return false
        }
    }
}

/// Evaluates alert rules against the live fleet state. Pure and
/// `Sendable`: the caller feeds one host's current sample (or its
/// unreachability) each tick and collects the events; the engine keeps
/// the per-(rule, host) violation timers. The engine's state is
/// in-memory only — after a relaunch timers start over (decision 0050).
public struct AlertEngine: Sendable {
    struct Track: Sendable {
        /// When the condition started holding; nil between violations.
        var since: Date?
        /// True once the rule has fired and not yet cleared.
        var active = false
    }

    /// Keyed by "ruleID/hostID".
    var tracks: [String: Track] = [:]

    public init() {}

    /// Evaluates the rules that watch `hostID` (its own plus every
    /// fleet-wide one) against the host's current state. A nil sample
    /// means the metrics are unavailable; every metric rule then reads
    /// as not violating, and an `unreachable` rule reads as violating
    /// only when `unreachable` is true. Returns the events this tick
    /// produced, in rule order.
    public mutating func evaluate(
        rules: [AlertRule], hostID: UUID, sample: Sample?, unreachable: Bool, now: Date
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for rule in rules where rule.hostID == nil || rule.hostID == hostID {
            let key = "\(rule.id.uuidString)/\(hostID.uuidString)"
            var track = tracks[key] ?? Track()
            let violating = Self.isViolating(rule: rule, sample: sample, unreachable: unreachable)
            if violating {
                if track.since == nil { track.since = now }
                if !track.active, let since = track.since,
                   now.timeIntervalSince(since) >= rule.duration {
                    track.active = true
                    events.append(.fired(ruleID: rule.id, hostID: hostID, ruleName: rule.name))
                }
            } else if track.since != nil {
                if track.active {
                    events.append(.cleared(ruleID: rule.id, hostID: hostID, ruleName: rule.name))
                }
                track = Track()
            }
            tracks[key] = track
        }
        // Rules that stopped watching this host (deleted, or narrowed
        // to someone else) leave no stale tracks behind.
        let watching = Set(rules.filter { $0.hostID == nil || $0.hostID == hostID }.map(\.id.uuidString))
        for key in tracks.keys where key.hasSuffix("/\(hostID.uuidString)") {
            let ruleID = String(key.split(separator: "/")[0])
            if !watching.contains(ruleID) { tracks[key] = nil }
        }
        return events
    }

    static func isViolating(rule: AlertRule, sample: Sample?, unreachable: Bool) -> Bool {
        switch rule.kind {
        case .unreachable:
            return unreachable
        case .cpu:
            guard let sample else { return false }
            return sample.cpu.meanBusyPercent > rule.threshold
        case .memory:
            guard let sample, sample.memory.total.value > 0 else { return false }
            return sample.memory.used.value / sample.memory.total.value * 100 > rule.threshold
        case .load:
            guard let sample, !sample.loadAvg.isEmpty else { return false }
            return sample.loadAvg[0] > rule.threshold
        case .disk:
            guard let sample, let worst = sample.disks.map(\.usagePct).max() else { return false }
            return worst > rule.threshold
        }
    }
}
