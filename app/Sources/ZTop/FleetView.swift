// SPDX-License-Identifier: MIT OR Apache-2.0
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI
import ZTopKit

/// The fleet overview: one live card per host.
struct FleetView: View {
    @StateObject private var store = HostStore()
    @State private var showingAdd = false
    @State private var pairing: HostRecord?

    var body: some View {
        FleetContent(store: store, showingAdd: $showingAdd, pairing: $pairing)
    }
}

/// The overview's content, split out so the recorded-run hook can
/// render the live state offscreen with ImageRenderer (the shell has
/// no screen-recording permission, so `screencapture` is not usable).
struct FleetContent: View {
    @ObservedObject var store: HostStore
    @Binding var showingAdd: Bool
    @Binding var pairing: HostRecord?

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    FleetEmptyState()
                } else {
                    cards
                }
            }
            .navigationTitle("zTop")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Host", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddHostSheet { name, host, port, pin, code in
                    _ = try await store.add(name: name, host: host, port: port, pin: pin, code: code)
                }
            }
            .sheet(item: $pairing) { record in
                PairSheet(record: record) { code in
                    try await store.pair(record, code: code)
                }
            }
            .task {
                // The recorded-run hook: launch arguments pair through
                // the same flow the form drives (see HostStore.seed),
                // then the live state is rendered to the snapshot path.
                if let seeds = ProcessInfo.processInfo.environment["ZTOP_PAIR"], !seeds.isEmpty {
                    await store.seed(from: seeds)
                }
                if let path = ProcessInfo.processInfo.environment["ZTOP_SNAPSHOT"], !path.isEmpty {
                    // Let the poller gather a couple of ticks first,
                    // then keep re-rendering so a recorded run can
                    // catch state changes (a host going stale or
                    // unreachable) while it runs.
                    try? await Task.sleep(for: .seconds(7))
                    while !Task.isCancelled {
                        renderSnapshot(to: path)
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
        }
    }

    /// Renders the current overview with the live data to a PNG.
    /// ImageRenderer cannot draw a `List` (it yields a placeholder
    /// glyph), so the snapshot draws the cards in a plain VStack —
    /// the same `HostCard` views the window shows.
    @MainActor
    private func renderSnapshot(to path: String) {
        #if os(macOS)
        let backdrop = Color(nsColor: .windowBackgroundColor)
        #else
        let backdrop = Color(.systemBackground)
        #endif
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("zTop").font(.title2.weight(.semibold))
                Spacer()
                Text("\(store.records.count) hosts")
                    .foregroundStyle(.secondary)
            }
            Divider()
            ForEach(store.records) { record in
                HostCard(record: record, live: store.live[record.id], onPair: {}, onForget: {})
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 820, height: 200 + 56 * CGFloat(store.records.count), alignment: .top)
        .background(backdrop)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(macOS)
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            // Atomic so a reader copying the file mid-run never sees
            // a half-written PNG.
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #else
        if let image = renderer.uiImage, let png = image.pngData() {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
    }

    private var cards: some View {
        List {
            ForEach(store.records) { record in
                HostCard(record: record, live: store.live[record.id]) {
                    pairing = record
                } onForget: {
                    store.remove(record)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.remove(store.records[index])
                }
            }
        }
    }
}

/// The empty fleet explains how to start an agent.
struct FleetEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No hosts yet", systemImage: "desktopcomputer")
        } description: {
            Text("Start an agent on a machine you want to watch:")
            Text("`ztop agent --tls --pair`").font(.system(.body, design: .monospaced))
            Text("then add it here with the pairing code and the SHA256 pin the agent prints.")
        }
    }
}

/// One host: identity, state color, and the two headline numbers.
struct HostCard: View {
    let record: HostRecord
    let live: HostLive?
    let onPair: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(stateColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if record.token.isEmpty {
                Button("Pair", action: onPair).buttonStyle(.bordered)
            }
            meter(title: "CPU", value: cpuPercent)
            meter(title: "MEM", value: memPercent)
            Menu {
                Button("Forget Host", role: .destructive, action: onForget)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        var base = "\(record.host):\(record.port)"
        if let state = live?.state {
            switch state {
            case .connecting: base += " · connecting…"
            case .live:
                if let seconds = uptimeSeconds {
                    base += " · up \(uptimeText(seconds))"
                }
            case .stale: base += " · stale"
            case .unreachable: base += " · unreachable"
            }
        }
        if record.token.isEmpty { base += " · needs pairing" }
        return base
    }

    private var stateColor: Color {
        switch live?.state {
        case .live: .green
        case .stale: .orange
        case .unreachable: .red
        case .connecting, .none: .gray
        }
    }

    private var cpuPercent: Double? {
        guard let cpu = live?.sample?.cpu, !cpu.busyPercent.isEmpty else { return nil }
        return cpu.meanBusyPercent / 100
    }

    private var memPercent: Double? {
        guard let memory = live?.sample?.memory,
              memory.total.value > 0, memory.used.available
        else { return nil }
        return memory.used.value / memory.total.value
    }

    private var uptimeSeconds: Double? {
        guard let uptime = live?.sample?.uptime, uptime.available else { return nil }
        return uptime.value
    }

    private func uptimeText(_ seconds: Double) -> String {
        let days = Int(seconds) / 86_400
        let hours = Int(seconds) % 86_400 / 3_600
        let minutes = Int(seconds) % 3_600 / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// A drawn meter bar: ImageRenderer cannot draw `ProgressView`
    /// (it renders a placeholder glyph), and a capsule bar reads the
    /// same on every platform.
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

/// Pairing an existing unpaired host with a code.
struct PairSheet: View {
    let record: HostRecord
    let onPair: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pair with \(record.name)") {
                    Text("Run `ztop agent --pair` on \(record.host) and enter the code it prints.")
                    TextField("Pairing code", text: $code)
                        .codeField()
                        .autocorrectionDisabled()
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Pair") {
                            working = true
                            Task {
                                do {
                                    try await onPair(code)
                                    dismiss()
                                } catch {
                                    self.error = error.localizedDescription
                                }
                                working = false
                            }
                        }
                        .disabled(code.isEmpty)
                    }
                }
            }
        }
    }
}

#Preview {
    FleetView()
}
