// SPDX-License-Identifier: MIT OR Apache-2.0
import SwiftUI
import ZTopKit

/// The alerts screen: every rule with its live state, plus the
/// add-alert sheet. The window shows the `List`; the recorded-run
/// hook renders `AlertsContent` offscreen (ImageRenderer cannot draw
/// a `List`, same as the overview).
struct AlertsView: View {
    @ObservedObject var center: AlertCenter
    @ObservedObject var store: HostStore
    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(center.rules) { rule in
                AlertRow(
                    rule: rule,
                    hostName: hostName(of: rule),
                    firing: center.active.contains { $0.ruleID == rule.id })
            }
            .onDelete { offsets in
                for index in offsets { center.remove(center.rules[index]) }
            }
            if center.rules.isEmpty {
                Text("No alerts yet. Add one to watch the fleet.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Alerts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Alert", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddAlertSheet(store: store) { rule in
                center.add(rule)
            }
        }
    }

    private func hostName(of rule: AlertRule) -> String? {
        guard let hostID = rule.hostID else { return nil }
        return store.records.first { $0.id == hostID }?.name
    }
}

/// One rule row: condition text, the host it watches (when not
/// fleet-wide) and a firing badge while the alert is active.
struct AlertRow: View {
    let rule: AlertRule
    let hostName: String?
    let firing: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.body.weight(.medium))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if firing {
                Label("firing", systemImage: "bell.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        guard let hostName else { return rule.describe }
        var text = rule.describe
        // describe says "any host: …" for fleet rules; a per-host rule
        // replaces that with the actual host name.
        if text.hasPrefix("any host: ") {
            text = String(text.dropFirst("any host: ".count))
        }
        return "\(hostName): \(text)"
    }
}

/// The alerts screen as the recorded-run hook renders it: a plain
/// VStack of the same rows.
struct AlertsContent: View {
    let rules: [AlertRule]
    let active: [ActiveAlert]
    let hostNames: [UUID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Alerts").font(.title2.weight(.semibold))
                Spacer()
                let firingRules = Set(active.map(\.ruleID)).count
                Text("\(firingRules) firing")
                    .foregroundStyle(firingRules == 0 ? Color.secondary : .red)
            }
            Divider()
            if rules.isEmpty {
                Text("No alerts yet. Add one to watch the fleet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                AlertRow(
                    rule: rule,
                    hostName: rule.hostID.flatMap { hostNames[$0] },
                    firing: active.contains { $0.ruleID == rule.id })
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 820, height: 200 + 56 * CGFloat(max(rules.count, 1)), alignment: .top)
    }
}

/// The add-alert form: name, what to watch, the threshold (where the
/// kind has one), how long it must hold, and which host (or all).
struct AddAlertSheet: View {
    @ObservedObject var store: HostStore
    let onAdd: (AlertRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: AlertKind = .cpu
    @State private var thresholdText = "90"
    @State private var durationText = "300"
    @State private var hostID: UUID?

    private var thresholdInvalid: Bool {
        guard kind.usesThreshold else { return false }
        return Double(thresholdText) == nil
    }

    private var durationInvalid: Bool {
        guard let duration = Double(durationText) else { return true }
        return duration < 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Alert").font(.title3.weight(.semibold))
            TextField("Name", text: $name)
            Picker("Watch", selection: $kind) {
                ForEach(AlertKind.allCases, id: \.self) { candidate in
                    Text(label(of: candidate)).tag(candidate)
                }
            }
            .pickerStyle(.menu)
            if kind.usesThreshold {
                TextField(thresholdPrompt, text: $thresholdText)
            }
            TextField("Hold for (seconds)", text: $durationText)
            Picker("Host", selection: $hostID) {
                Text("All hosts").tag(UUID?.none)
                ForEach(store.records) { record in
                    Text(record.name).tag(UUID?.some(record.id))
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    AlertCenter.requestNotificationAuthorization()
                    onAdd(
                        AlertRule(
                            name: name.isEmpty ? defaultName : name,
                            hostID: hostID, kind: kind,
                            threshold: Double(thresholdText) ?? 0,
                            duration: Double(durationText) ?? 0))
                    dismiss()
                }
                .disabled(name.isEmpty && defaultName.isEmpty || thresholdInvalid || durationInvalid)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var defaultName: String {
        guard let duration = Double(durationText) else { return "" }
        return AlertRule(
            name: "", hostID: hostID, kind: kind,
            threshold: Double(thresholdText) ?? 0, duration: duration
        ).describe
    }

    private func label(of kind: AlertKind) -> String {
        switch kind {
        case .cpu: return "CPU percent"
        case .memory: return "Memory percent"
        case .load: return "Load (1 min)"
        case .disk: return "Disk percent"
        case .unreachable: return "Unreachable"
        }
    }

    private var thresholdPrompt: String {
        kind == .load ? "Threshold (load)" : "Threshold (percent)"
    }
}
