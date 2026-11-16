// SPDX-License-Identifier: MIT OR Apache-2.0
import Combine
import Foundation
import UserNotifications
import ZTopKit

/// One alert currently firing, as the alerts screen shows it.
struct ActiveAlert: Identifiable, Equatable {
    let ruleID: UUID
    let hostID: UUID
    let ruleName: String
    let hostName: String

    var id: String { "\(ruleID.uuidString)/\(hostID.uuidString)" }
}

/// The fleet's alert rules and their live state: persists the rules
/// (`alerts.json` next to the hosts file), runs the ZTopKit engine on
/// every poll tick through the host store's published state, and posts
/// local notifications for fired alerts when the user allowed them.
/// The engine's timers are in-memory: after a relaunch the rules start
/// over (decision 0050).
@MainActor
final class AlertCenter: ObservableObject {
    @Published private(set) var rules: [AlertRule] = []
    @Published private(set) var active: [ActiveAlert] = []

    private var engine = AlertEngine()
    private let fileURL: URL
    private var cancellable: AnyCancellable?

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ztop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("alerts.json")
        load()
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AlertRule].self, from: data)
        else { return }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: rules

    func add(_ rule: AlertRule) {
        rules.append(rule)
        save()
    }

    func remove(_ rule: AlertRule) {
        rules.removeAll { $0.id == rule.id }
        active.removeAll { $0.ruleID == rule.id }
        save()
    }

    /// The recorded-run seed: `ZTOP_ALERTS` carries rules as
    /// `name|host name or *|kind|threshold|duration;…`, with host names
    /// resolved against the freshly seeded records.
    func seed(from spec: String, hosts: [HostRecord]) {
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "|")
            guard parts.count == 5 else { continue }
            let name = String(parts[0])
            let hostName = String(parts[1])
            guard let kind = AlertKind(rawValue: String(parts[2])) else { continue }
            let threshold = Double(parts[3]) ?? 0
            guard let duration = Double(parts[4]) else { continue }
            let hostID: UUID?
            if hostName == "*" {
                hostID = nil
            } else if let record = hosts.first(where: { $0.name == hostName }) {
                hostID = record.id
            } else {
                continue
            }
            guard !rules.contains(where: { $0.name == name && $0.kind == kind && $0.hostID == hostID })
            else { continue }
            add(AlertRule(name: name, hostID: hostID, kind: kind, threshold: threshold, duration: duration))
        }
    }

    // MARK: evaluation

    /// Watches the host store: every published poll tick is fed to the
    /// engine, once per host. A `stale` host contributes no metrics
    /// (its sample is old), and only a fully `unreachable` host
    /// satisfies unreachable rules.
    func attach(to store: HostStore) {
        cancellable = store.$live.sink { [weak self, weak store] live in
            guard let self, let store else { return }
            for (hostID, entry) in live {
                let sample = entry.state == .live ? entry.sample : nil
                self.handle(
                    hostID: hostID, sample: sample,
                    unreachable: entry.state == .unreachable,
                    records: store.records)
            }
        }
    }

    private func handle(hostID: UUID, sample: Sample?, unreachable: Bool, records: [HostRecord]) {
        guard !rules.isEmpty else { return }
        let events = engine.evaluate(
            rules: rules, hostID: hostID, sample: sample,
            unreachable: unreachable, now: Date())
        guard !events.isEmpty else { return }
        let hostName = records.first { $0.id == hostID }?.name ?? hostID.uuidString
        var activeNow = active
        for event in events {
            switch event {
            case .fired:
                let alert = ActiveAlert(
                    ruleID: event.ruleID, hostID: hostID,
                    ruleName: event.ruleName, hostName: hostName)
                if !activeNow.contains(alert) {
                    activeNow.append(alert)
                    post(alert)
                }
            case .cleared:
                activeNow.removeAll { $0.ruleID == event.ruleID && $0.hostID == hostID }
            }
        }
        if activeNow != active { active = activeNow }
    }

    /// Local notifications, only for a user that already allowed them;
    /// authorization is requested from the add-alert sheet, never
    /// silently at launch.
    private func post(_ alert: ActiveAlert) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = alert.ruleName
            content.body = "fired on \(alert.hostName)"
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            center.add(request)
        }
    }

    /// Called from the add-alert sheet's confirm action: the one place
    /// that may ask the user for notification permission.
    static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}
