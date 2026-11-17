// SPDX-License-Identifier: MIT OR Apache-2.0
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI
// Foundation also declares a `Process`; the selective import keeps
// `Process` unambiguous in this file.
import struct ZTopKit.Process
import ZTopKit

/// The fleet overview: one live card per host.
struct FleetView: View {
    @StateObject private var store = HostStore()
    @StateObject private var alertCenter = AlertCenter()
    @State private var showingAdd = false
    @State private var pairing: HostRecord?

    var body: some View {
        FleetContent(store: store, center: alertCenter, showingAdd: $showingAdd, pairing: $pairing)
    }
}

/// The overview's content, split out so the recorded-run hook can
/// render the live state offscreen with ImageRenderer (the shell has
/// no screen-recording permission, so `screencapture` is not usable).
struct FleetContent: View {
    @ObservedObject var store: HostStore
    @ObservedObject var center: AlertCenter
    @Binding var showingAdd: Bool
    @Binding var pairing: HostRecord?
#if os(macOS)
    // The hub is macOS-only (the iPad reaches the hub over the
    // network instead of running one); these stay out of the iOS
    // build entirely.
    @StateObject private var hubRunner = HubRunner()
    @StateObject private var hubInstaller = HubInstaller()
    @State private var showingHub = false
#endif
    /// The pushed host detail; the recorded-run hook also sets this
    /// so the window shows the same screen the snapshot captures.
    @State private var detailTarget: HostRecord?
    /// The detail's history window, fetched for the snapshot hook.
    @State private var detailHistory: [Sample] = []
    /// The detail's process rows, fetched for the snapshot hook.
    @State private var detailProcesses: [Process] = []
    /// The pushed alerts screen.
    @State private var showingAlerts = false
    /// The SoC screen's pushed record (the toolbar gauge on the
    /// detail page, or `ZTOP_SOC` in a recorded run).
    @State private var socTarget: HostRecord?
    /// The pushed hub machine's detail.
    @State private var hubDetail: HubMachine?
    /// The recorded-run demo switch: render synthetic process rows
    /// instead of the live ones (screenshots carry fake values only).
    @State private var demoProcesses = false

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
#if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingHub = true
                    } label: {
                        Label("Hub", systemImage: "server.rack")
                    }
                }
#endif
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAlerts = true
                    } label: {
                        Label("Alerts", systemImage: center.active.isEmpty ? "bell" : "bell.badge")
                    }
                }
            }
#if os(macOS)
            .navigationDestination(isPresented: $showingHub) {
                HubView(store: store, runner: hubRunner, installer: hubInstaller)
            }
#endif
            .navigationDestination(isPresented: $showingAlerts) {
                AlertsView(center: center, store: store)
            }
            .navigationDestination(item: $detailTarget) { record in
                HostDetailView(store: store, record: record, onOpenSoc: { socTarget = record })
            }
            .navigationDestination(item: $socTarget) { record in
                SocView(store: store, record: record)
            }
            .navigationDestination(item: $hubDetail) { machine in
                if let hub = store.records.first(where: { $0.id == machine.hubID }) {
                    HubDetailView(store: store, hub: hub, machine: machine)
                } else {
                    Text("The hub was removed.")
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddHostSheet { name, host, port, pin, code, isHub in
                    _ = try await store.add(name: name, host: host, port: port, pin: pin, code: code, isHub: isHub)
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
                // The hub seed pairs a hub record the same way, so a
                // recorded run reaches the fleet through one hub.
                if let hubSeeds = ProcessInfo.processInfo.environment["ZTOP_HUB_PAIR"], !hubSeeds.isEmpty {
                    await store.seedHub(from: hubSeeds)
                }
                // The alert engine rides the store's published state
                // from here on; recorded runs may seed rules by host
                // name (`ZTOP_ALERTS=name|host or *|kind|threshold|duration;…`).
                center.attach(to: store)
                if let alertSeeds = ProcessInfo.processInfo.environment["ZTOP_ALERTS"], !alertSeeds.isEmpty {
                    center.seed(from: alertSeeds, hosts: store.records)
                }
                if let path = ProcessInfo.processInfo.environment["ZTOP_ALERTS_SNAPSHOT"], !path.isEmpty {
                    // Render the alerts screen instead of the fleet
                    // overview, so a recorded run captures rule states.
                    while !Task.isCancelled {
                        renderAlertsSnapshot(to: path)
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
                if let path = ProcessInfo.processInfo.environment["ZTOP_SNAPSHOT"], !path.isEmpty {
                    // Let the poller gather a couple of ticks first,
                    // then keep re-rendering so a recorded run can
                    // catch state changes (a host going stale or
                    // unreachable) while it runs.
                    try? await Task.sleep(for: .seconds(7))
                    // ZTOP_DETAIL names a host: push its detail on
                    // screen and render it, so a recorded run can
                    // capture the detail screen the same way.
                    let detailName = ProcessInfo.processInfo.environment["ZTOP_DETAIL"]
                    // ZTOP_SOC names a host: push its SoC screen and
                    // render that instead of the detail page.
                    let socName = ProcessInfo.processInfo.environment["ZTOP_SOC"]
                    var hubHandled = false
#if os(macOS)
                    // ZTOP_HUB=1: the hub recorded-run hook (writing
                    // the agent list, starting the embedded hub, and
                    // rendering the hub screen) lives with the hub
                    // views, which are macOS-only.
                    if ProcessInfo.processInfo.environment["ZTOP_HUB"] == "1" {
                        hubHandled = true
                        await HubRecorded.run(store: store, to: path)
                    }
#endif
                    if !hubHandled, let name = detailName, !name.isEmpty {
                        let record = store.records.first { $0.name == name }
                        if let record {
                            detailTarget = record
                            // ZTOP_PROCESSES_DEMO swaps the live
                            // process rows for synthetic ones, so a
                            // committed screenshot never carries this
                            // machine's real process list.
                            demoProcesses = ProcessInfo.processInfo
                                .environment["ZTOP_PROCESSES_DEMO"] == "1"
                            await renderDetailLoop(record: record, to: path)
                        }
                    } else if let socName, !socName.isEmpty,
                              let record = store.records.first(where: { $0.name == socName }) {
                        socTarget = record
                        await renderSocLoop(record: record, to: path)
                    } else {
                        while !Task.isCancelled {
                            renderSnapshot(to: path)
                            try? await Task.sleep(for: .seconds(5))
                        }
                    }
                }
            }
        }
    }

    /// Fetches the named host's history and process list and keeps
    /// rendering its detail to the snapshot path, so a recorded run
    /// captures the charts over a live window and the live table.
    @MainActor
    private func renderDetailLoop(record: HostRecord, to path: String) async {
        while !Task.isCancelled {
            if let samples = try? await AgentClient(endpoint: record.endpoint).history(seconds: 3600) {
                detailHistory = samples
            }
            if let rows = try? await AgentClient(endpoint: record.endpoint).processes() {
                detailProcesses = demoProcesses ? Self.demoRows : rows
            }
            renderDetailSnapshot(record: record, to: path)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Keeps rendering the named host's SoC screen to the snapshot
    /// path; the data rides the poller's live samples, so the loop
    /// only re-renders.
    @MainActor
    private func renderSocLoop(record: HostRecord, to path: String) async {
        while !Task.isCancelled {
            renderSocSnapshot(record: record, to: path)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Renders one host's SoC content to a PNG (ImageRenderer cannot
    /// draw the pushed `ScrollView`, same as the detail page).
    @MainActor
    private func renderSocSnapshot(record: HostRecord, to path: String) {
        #if os(macOS)
        let backdrop = Color(nsColor: .windowBackgroundColor)
        #else
        let backdrop = Color(.systemBackground)
        #endif
        let content = SocContent(
            record: record,
            live: store.live[record.id]
        )
        .padding(24)
        .frame(width: 820, height: 400, alignment: .top)
        .background(backdrop)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(macOS)
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        #else
        if let image = renderer.uiImage, let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        #endif
    }

    /// The recorded-run demo rows: fake names, fake users, fake pids.
    /// A committed screenshot shows these instead of this machine's
    /// real process list (fake values only, like `host-a` and
    /// `alice` everywhere else in the fixtures).
    @MainActor
    static let demoRows: [Process] = [
        demo("builder", pid: 4112, user: "alice", cpu: 38.4, mem: 6.2),
        demo("renderer", pid: 911, user: "alice", cpu: 24.1, mem: 11.7),
        demo("worker", pid: 2087, user: "bob", cpu: 12.9, mem: 2.4),
        demo("monitor", pid: 604, user: "carol", cpu: 7.3, mem: 1.1),
        demo("logger", pid: 3330, user: "bob", cpu: 4.6, mem: 0.8),
        demo("helper", pid: 815, user: "alice", cpu: 2.2, mem: 1.9),
        demo("indexer", pid: 1477, user: "bob", cpu: 1.8, mem: 3.5),
        demo("daemon", pid: 102, user: "carol", cpu: 0.4, mem: 0.6),
        demo("relay", pid: 2381, user: "alice", cpu: 0.2, mem: 0.3),
        demo("sweeper", pid: 5190, user: "bob", cpu: 0.1, mem: 0.2),
    ]

    /// One demo row with neutral fields everywhere the table doesn't
    /// show (a full memberwise init; the hidden fields stay fake).
    @MainActor
    private static func demo(
        _ name: String, pid: UInt32, user: String, cpu: Double, mem: Double
    ) -> Process {
        ZTopKit.Process(
            pid: pid,
            parent: nil,
            user: user,
            state: "run",
            name: name,
            cpuPercent: cpu,
            memPercent: mem,
            virtualBytes: 1 << 28,
            residentBytes: 1 << 26,
            threads: 2,
            priority: nil,
            nice: nil,
            sharedBytes: nil,
            totalTimeNs: nil,
            startTimeSecs: nil,
            processor: nil,
            command: nil,
            isThread: false,
            kernelThread: false,
            io: ProcessIo(readBytes: nil, writeBytes: nil, readRate: nil, writeRate: nil),
            container: nil
        )
    }

    /// The extra snapshot height the process table needs: its chrome
    /// (title, search, header, footer) plus one line per shown row.
    @MainActor
    private func detailHeight(_ rows: [Process]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        return 150 + CGFloat(min(rows.count, 30)) * 34
    }

    /// Renders one host's detail content to a PNG (ImageRenderer
    /// cannot draw the `ScrollView` the window shows, same as the
    /// overview's `List` limit).
    @MainActor
    private func renderDetailSnapshot(record: HostRecord, to path: String) {
        #if os(macOS)
        let backdrop = Color(nsColor: .windowBackgroundColor)
        #else
        let backdrop = Color(.systemBackground)
        #endif
        let content = HostDetailContent(
            record: record,
            live: store.live[record.id],
            history: detailHistory,
            processes: detailProcesses,
            processError: nil,
            staticProcessSearch: true
        )
        .padding(24)
        // The table adds one row line per process (capped at 30) plus
        // its own chrome, so the frame grows with it instead of
        // clipping the sections that follow.
        .frame(
            width: 820,
            height: 1500 + detailHeight(detailProcesses),
            alignment: .top
        )
        .background(backdrop)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(macOS)
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #else
        if let image = renderer.uiImage, let png = image.pngData() {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
    }

    /// Renders the alerts screen to a PNG (same ImageRenderer limits
    /// as the overview: a plain VStack, not the window's `List`).
    @MainActor
    private func renderAlertsSnapshot(to path: String) {
        #if os(macOS)
        let backdrop = Color(nsColor: .windowBackgroundColor)
        #else
        let backdrop = Color(.systemBackground)
        #endif
        var hostNames: [UUID: String] = [:]
        for record in store.records { hostNames[record.id] = record.name }
        let content = AlertsContent(rules: center.rules, active: center.active, hostNames: hostNames)
            .background(backdrop)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(macOS)
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #else
        if let image = renderer.uiImage, let png = image.pngData() {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
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
            ForEach(store.records.filter { !$0.isHub }) { record in
                HostCard(record: record, live: store.live[record.id], onPair: {}, onForget: {})
            }
            if !store.hubMachines.isEmpty {
                Text("Through the hub")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(store.hubMachines) { machine in
                    HubMachineCard(machine: machine)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(
            width: 820,
            height: 200 + 56 * CGFloat(store.records.filter { !$0.isHub }.count)
                + (store.hubMachines.isEmpty ? 0 : 46 + 56 * CGFloat(store.hubMachines.count)),
            alignment: .top
        )
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
            ForEach(store.records.filter { !$0.isHub }) { record in
                HostCard(record: record, live: store.live[record.id]) {
                    pairing = record
                } onForget: {
                    store.remove(record)
                }
                .contentShape(Rectangle())
                .onTapGesture { detailTarget = record }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.remove(store.records.filter { !$0.isHub }[index])
                }
            }
            // The saved hubs and the machines they watch. A hub is
            // reached the same way everywhere: pair with it once, and
            // its fleet shows here, states and samples read through
            // it (`?host=`).
            ForEach(store.records.filter { $0.isHub }) { hub in
                Section("Through \(hub.name)") {
                    let machines = store.hubMachines.filter { $0.hubID == hub.id }
                    if machines.isEmpty {
                        Text(store.live[hub.id] == nil ? "Reading the hub…" : "The hub watches no agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(machines) { machine in
                        HubMachineCard(machine: machine)
                            .contentShape(Rectangle())
                            .onTapGesture { hubDetail = machine }
                    }
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
