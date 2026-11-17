// SPDX-License-Identifier: MIT OR Apache-2.0
import SwiftUI
import struct ZTopKit.Process
import ZTopKit

/// One machine a hub watches, as the overview card shows it: the
/// hub's name for it, the agent's address, and the two headline
/// numbers read through the hub.
struct HubMachineCard: View {
    let machine: HubMachine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(stateColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            meter(title: "CPU", value: cpuPercent)
            meter(title: "MEM", value: memPercent)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    /// The combined VoiceOver label for the card.
    private var accessibilityLabel: String {
        var parts: [String] = [machine.name]
        switch machine.state {
        case .connecting: parts.append("connecting")
        case .live: parts.append("live")
        case .stale: parts.append("stale")
        case .unreachable: parts.append("unreachable")
        }
        if let error = machine.error, machine.state != .live {
            parts.append(error)
        }
        return parts.joined(separator: ", ")
    }

    /// The combined VoiceOver value for the card (CPU and MEM percentages).
    private var accessibilityValue: String {
        var parts: [String] = []
        if let cpu = cpuPercent {
            parts.append("CPU \(Int((cpu * 100).rounded())) percent")
        }
        if let mem = memPercent {
            parts.append("memory \(Int((mem * 100).rounded())) percent")
        }
        return parts.isEmpty ? "no data" : parts.joined(separator: ", ")
    }

    private var caption: String {
        var base = machine.target
        if let error = machine.error, machine.state != .live {
            base += " · \(error)"
        }
        return base
    }

    private var stateColor: Color {
        switch machine.state {
        case .live: .green
        case .stale: .orange
        case .unreachable: .red
        case .connecting: .gray
        }
    }

    private var cpuPercent: Double? {
        guard let cpu = machine.sample?.cpu, !cpu.busyPercent.isEmpty else { return nil }
        return cpu.meanBusyPercent / 100
    }

    private var memPercent: Double? {
        guard let memory = machine.sample?.memory,
              memory.total.value > 0, memory.used.available
        else { return nil }
        return memory.used.value / memory.total.value
    }

    /// A drawn meter bar, exactly as the direct cards draw theirs
    /// (ImageRenderer cannot draw `ProgressView`).
    @ViewBuilder
    private func meter(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.map { "\(title) \(Int(($0 * 100).rounded()))%" } ?? title)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if let value {
                let clamped = min(max(value, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(clamped > 0.85 ? Color.red : clamped > 0.6 ? Color.orange : Color.green)
                        .frame(width: 64 * clamped)
                }
                .frame(width: 64, height: 5)
            } else {
                Text("n/a").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One hub machine's detail: the same content the direct detail
/// shows, fed through the hub — history from the hub's own store,
/// the live sample through `?host=`. The hub archives samples, not
/// process lists, so the process table is absent here.
struct HubDetailView: View {
    @ObservedObject var store: HostStore
    /// The hub record the machine is watched by.
    let hub: HostRecord
    let machine: HubMachine

    @State private var history: [Sample] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            HostDetailContent(
                record: placeholder,
                live: current.map { machine in
                    HostLive(state: machine.state, sample: machine.sample, lastGood: machine.lastGood)
                },
                history: history,
                processes: [],
                processError: nil,
                showsProcesses: false,
                addressOverride: current?.target ?? machine.target
            )
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(machine.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await refreshLoop() }
    }

    /// The machine as the poller last saw it, so the screen keeps up
    /// with the fleet changing under it.
    private var current: HubMachine? {
        store.hubMachines.first { $0.id == machine.id }
    }

    /// The content's record is a shell: name and address come from
    /// the machine, the rest is never used (the hub record holds the
    /// endpoint).
    private var placeholder: HostRecord {
        HostRecord(name: machine.name, host: hub.host, port: hub.port, pin: hub.pin, token: "")
    }

    /// Fetches the machine's history window from the hub's store on
    /// arrival and every few seconds after; a failed fetch keeps the
    /// last window and reports once.
    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                history = try await AgentClient(endpoint: hub.endpoint)
                    .history(seconds: 3600, host: machine.name)
                loadError = nil
            } catch {
                if history.isEmpty { loadError = error.localizedDescription }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}
