// SPDX-License-Identifier: MIT OR Apache-2.0
// The hub screen is a Mac feature: the hub runs on a Mac (the iPad
// reaches it over the network, which is batch 14b), so the runner,
// installer and this view are macOS-only.
#if os(macOS)
import SwiftUI
import ZTopKit

/// The hub screen: what the hub watches, whether it runs, and the
/// login item that keeps it running after the app quits.
struct HubView: View {
    @ObservedObject var store: HostStore
    @ObservedObject var runner: HubRunner
    @ObservedObject var installer: HubInstaller
    @State private var port: UInt16 = HubPlan.defaultPort
    /// What the hub's own `/v1/hosts` reports, refreshed while open.
    @State private var watched: [HubHostStatus] = []

    var body: some View {
        ScrollView {
            HubContent(
                store: store,
                runner: runner,
                installer: installer,
                port: port,
                watched: watched,
                staticToggle: false,
                setPort: { port = $0 },
                start: { start() },
                stop: { runner.stop() },
                toggleLogin: { toggleLogin() }
            )
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Hub")
        .task { await watchLoop() }
        .onAppear {
            installer.refresh()
            rewriteAgentsFile()
        }
    }

    /// Starts the hub after refreshing the agent list, so a hub run
    /// always polls the fleet the app currently knows.
    private func start() {
        rewriteAgentsFile()
        runner.start(port: port)
    }

    /// Turns the login item on or off. Installing rewrites the agent
    /// list and the plist first, so registration always reflects the
    /// current fleet and port.
    private func toggleLogin() {
        do {
            if installer.registered {
                try installer.uninstall()
            } else {
                try rewriteAgentsFile()
                let binary = Bundle.main.executableURL?
                    .deletingLastPathComponent()
                    .appendingPathComponent("ztop-embedded").path ?? ""
                try installer.install(
                    binaryPath: binary,
                    stateDir: HubPaths.stateDirectory().path,
                    port: port
                )
            }
        } catch {
            runner.lastError = "\(error)"
        }
    }

    /// Writes the hub's agents.json from the app's saved hosts; the
    /// hub picks the file up on its next restart.
    @discardableResult
    private func rewriteAgentsFile() -> URL? {
        try? HubPaths.writeAgentsFile(records: store.records)
    }

    /// Refreshes the hub's own view of the fleet every few seconds
    /// while the screen is open. The first read needs pairing: the
    /// recorded-run hook pairs right after starting the hub, and the
    /// manual flow pairs on first open while the hub runs.
    private func watchLoop() async {
        while !Task.isCancelled {
            if runner.running {
                if !runner.hasHubToken {
                    await runner.pairWithHub(port: port)
                }
                if let hosts = try? await runner.client(port: port).hosts() {
                    watched = hosts.hosts
                }
            } else {
                watched = []
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// The hub screen's content, split out so the recorded-run hook can
/// render it offscreen with ImageRenderer (ImageRenderer cannot draw
/// `Form` — the screen is a plain `VStack` for the same reason the
/// process table is, decision 0046).
struct HubContent: View {
    @ObservedObject var store: HostStore
    @ObservedObject var runner: HubRunner
    @ObservedObject var installer: HubInstaller
    let port: UInt16
    let watched: [HubHostStatus]
    /// The recorded-run path draws the login toggle as a static
    /// capsule: ImageRenderer cannot draw a real switch (it renders
    /// the "not permitted" banner instead, as with TextField in
    /// decision 0052's search field).
    let staticToggle: Bool
    let setPort: (UInt16) -> Void
    let start: () -> Void
    let stop: () -> Void
    let toggleLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusSection
            loginSection
            agentsSection
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Status")
            row("Endpoint", "127.0.0.1:\(port) · TLS · pairing on")
            if let fingerprint = runner.fingerprint, !fingerprint.isEmpty {
                row("TLS pin", fingerprint)
            }
            HStack(spacing: 6) {
                Image(systemName: runner.running ? "checkmark.circle.fill" : "stop.circle")
                    .foregroundStyle(runner.running ? Color.green : Color.secondary)
                Text(runner.running ? "Running" : "Not running")
                    .font(.callout)
                Spacer()
                Button("Run now") { start() }
                    .disabled(runner.running)
                Button("Stop", role: .destructive) { stop() }
                    .disabled(!runner.running)
            }
            if let error = runner.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Login item")
            HStack {
                Text("Run the hub at login")
                    .font(.callout)
                Spacer()
                if staticToggle {
                    staticToggleReplica(installer.registered)
                } else {
                    Toggle("", isOn: Binding(
                        get: { installer.registered },
                        set: { _ in toggleLogin() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            Text(loginNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A drawn stand-in for the switch, for the offscreen render
    /// only: the same 38×22 capsule the macOS switch uses.
    private func staticToggleReplica(_ on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color.green.opacity(0.85) : Color.secondary.opacity(0.3))
                .frame(width: 38, height: 22)
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(radius: 1)
                .padding(2)
        }
    }

    private var loginNote: String {
        switch installer.status {
        case .enabled:
            "Launchd keeps the hub running across restarts; it shows in System Settings › Login Items."
        case .requiresApproval:
            "Waiting for approval in System Settings › Login Items."
        default:
            "The hub then runs without this app open, still bound to loopback."
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Watched agents")
            if store.records.isEmpty {
                Text("No hosts saved yet: the hub polls the app's saved hosts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(watched.isEmpty ? placeholderRows : watched, id: \.name) { status in
                    watchedRow(status)
                }
                if watched.isEmpty {
                    Text(runner.running
                        ? "The hub has not reported the fleet yet."
                        : "Start the hub to see its own view of the fleet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The list is written from the app's saved hosts every time the hub starts or this screen opens.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// While the hub is down, the rows come from the app's saved
    /// hosts so the screen still shows what WOULD be watched.
    private var placeholderRows: [HubHostStatus] {
        store.records.map { record in
            HubHostStatus(
                name: record.name,
                target: "\(record.host):\(record.port)",
                state: record.token.isEmpty ? "unpaired" : "saved"
            )
        }
    }

    @ViewBuilder
    private func watchedRow(_ status: HubHostStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                    .font(.callout)
                Text(status.target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let error = status.error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Text(stateWord(status.state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateTint(status.state))
        }
        .padding(.vertical, 3)
    }

    private func stateWord(_ state: String) -> String {
        switch state {
        case "live": "Live"
        case "stale": "Stale"
        case "unreachable": "Unreachable"
        case "saved": "Saved"
        case "unpaired": "Unpaired"
        default: state
        }
    }

    private func stateTint(_ state: String) -> Color {
        switch state {
        case "live": .green
        case "stale": .orange
        default: .secondary
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The hub recorded-run hook (`ZTOP_HUB=1`): write the hub's agent
/// list from the saved hosts, start the embedded hub, pair the app
/// with it as its own first client, and keep rendering the hub
/// screen to the snapshot path so a recorded run captures the
/// watched agents going live.
@MainActor
enum HubRecorded {
    static func run(store: HostStore, to path: String) async {
        _ = try? HubPaths.writeAgentsFile(records: store.records)
        let runner = HubRunner()
        runner.start(port: HubPlan.defaultPort)
        // The app is its own first hub client: it pins the hub's
        // printed fingerprint and pairs with the printed code,
        // exactly as it instructs a human to do for another client.
        await runner.pairWithHub(port: HubPlan.defaultPort)
        let installer = HubInstaller()
        var watched: [HubHostStatus] = []
        try? await Task.sleep(for: .seconds(5))
        while !Task.isCancelled {
            if runner.running,
               let hosts = try? await runner.client(port: HubPlan.defaultPort).hosts()
            {
                watched = hosts.hosts
            }
            render(store: store, runner: runner, installer: installer, watched: watched, to: path)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Renders the hub screen's content to a PNG (ImageRenderer
    /// cannot draw the pushed `Form`, same as the other screens).
    static func render(
        store: HostStore,
        runner: HubRunner,
        installer: HubInstaller,
        watched: [HubHostStatus],
        to path: String
    ) {
        let content = HubContent(
            store: store,
            runner: runner,
            installer: installer,
            port: HubPlan.defaultPort,
            watched: watched,
            staticToggle: true,
            setPort: { _ in },
            start: {},
            stop: {},
            toggleLogin: {}
        )
        .padding(24)
        .frame(width: 820, height: 340, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
