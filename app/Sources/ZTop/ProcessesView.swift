// SPDX-License-Identifier: MIT OR Apache-2.0
// The process table section of the detail screen: search, sort, and the
// control menu (signals by the TARGET agent's numbering, renice by delta).
import SwiftUI
// Foundation also declares a `Process`; the selective import keeps
// `Process` unambiguous in this file.
import struct ZTopKit.Process
import ZTopKit

/// The host's process table. The rows come from the parent's polling
/// loop; this view owns the search text, the sort choice, the signal
/// catalog, and the control calls. A plain VStack, so it composes in
/// the detail's `ScrollView` and renders in the recorded-run snapshots
/// (ImageRenderer cannot draw `List` or `Table`).
struct ProcessListView: View {
    let record: HostRecord
    /// The latest sample's rows, as the parent's loop fetched them.
    let rows: [Process]
    /// The wording to show when the parent's fetch failed and no rows
    /// have ever arrived.
    let fetchError: String?

    /// The recorded-run snapshot renders the search field as a drawn
    /// box: ImageRenderer cannot draw `TextField` (it paints the
    /// unsupported-view banner instead). The window always edits for
    /// real; only the offscreen capture sees the drawn one.
    var staticSearch = false

    @State private var query = ""
    @State private var sortKey: ProcessSortKey = .cpu
    @State private var sortDirection: SortDirection = .descending
    /// The target's signal catalog; empty when it could not be read.
    @State private var signals: [SignalEntry] = []
    @State private var report: ProcessReport?
    @State private var confirmingKill: Process?
    @State private var working = false

    /// The rows the search keeps, in the chosen order.
    private var visible: [Process] {
        ProcessTable.sort(ProcessTable.filter(rows, query: query), by: sortKey, direction: sortDirection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Processes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(visible.count) of \(rows.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                sortMenu
            }
            if staticSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    Text("Search name, user, or pid")
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                TextField("Search name, user, or pid", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
            }
            if rows.isEmpty, let fetchError {
                Text("processes unavailable: \(fetchError)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("waiting for the first sample…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                header
                ForEach(visible.prefix(30), id: \.pid) { row in
                    ProcessRow(
                        row: row,
                        signals: signals,
                        working: working,
                        onSignal: { number in Task { await run(.signal(number), on: [row.pid]) } },
                        onRenice: { delta in Task { await run(.renice(delta), on: [row.pid]) } },
                        onKill: { confirmingKill = row }
                    )
                }
                if visible.count > 30 {
                    Text("\(visible.count - 30) more — search to narrow the list")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task { await loadCatalog() }
        .alert(item: $report) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
        .confirmationDialog(
            confirmingKill.map { "Kill \($0.name) (pid \($0.pid))?" } ?? "",
            isPresented: Binding(
                get: { confirmingKill != nil },
                set: { if !$0 { confirmingKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Send SIGKILL", role: .destructive) {
                if let row = confirmingKill { killConfirmed(row) }
            }
            Button("Cancel", role: .cancel) { confirmingKill = nil }
        } message: {
            Text("SIGKILL cannot be caught or ignored; the process dies without cleaning up.")
        }
    }

    // MARK: header pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("name").frame(maxWidth: .infinity, alignment: .leading)
            Text("pid").frame(width: 56, alignment: .trailing)
            Text("cpu").frame(width: 52, alignment: .trailing)
            Text("mem").frame(width: 52, alignment: .trailing)
            // Keeps the row menus aligned under the header.
            Text("").frame(width: 22)
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
    }

    /// The sort menu: the active key is checkmarked and carries the
    /// direction arrow; picking it again flips the direction.
    private var sortMenu: some View {
        Menu {
            ForEach(ProcessSortKey.allCases, id: \.self) { key in
                Button {
                    if key == sortKey {
                        sortDirection = sortDirection == .ascending ? .descending : .ascending
                    } else {
                        sortKey = key
                        // Counts read best biggest-first; names and
                        // ids read best alphabetically / numerically.
                        switch key {
                        case .cpu, .memory: sortDirection = .descending
                        case .pid, .name, .user: sortDirection = .ascending
                        }
                    }
                } label: {
                    if key == sortKey {
                        Label(label(key, sortDirection), systemImage: "checkmark")
                    } else {
                        Text(label(key, nil))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .disabled(rows.isEmpty)
    }

    private func label(_ key: ProcessSortKey, _ direction: SortDirection?) -> String {
        var text = key.rawValue
        if let direction {
            text += direction == .ascending ? " ↑" : " ↓"
        }
        return text
    }

    // MARK: control

    /// Fetches the target's signal catalog once; a failure leaves the
    /// menu on the platform-independent fallback (see `signalItems`).
    private func loadCatalog() async {
        guard signals.isEmpty else { return }
        signals = (try? await AgentClient(endpoint: record.endpoint).signalCatalog()) ?? []
    }

    /// Confirms and sends SIGKILL: the one uncatchable signal gets an
    /// explicit second step, everything else runs straight from the menu.
    private func killConfirmed(_ row: Process) {
        confirmingKill = nil
        // The kill path carries the SIGKILL number from the catalog
        // when it could be read; 9 is the same everywhere anyway.
        let number = signals.first { $0.name == "KILL" }?.number ?? 9
        Task { await run(.signal(number), on: [row.pid]) }
    }

    private func run(_ action: ControlAction, on pids: [UInt32]) async {
        working = true
        defer { working = false }
        do {
            let results = try await AgentClient(endpoint: record.endpoint).control(pids: pids, action: action)
            let failed = results.filter { !$0.ok }
            if failed.isEmpty {
                report = ProcessReport(
                    title: "Done",
                    message: results.map { "pid \($0.pid): ok" }.joined(separator: "\n")
                )
            } else {
                report = ProcessReport(
                    title: "Some pids refused",
                    message: results.map { result in
                        result.ok ? "pid \(result.pid): ok" : "pid \(result.pid): \(result.error ?? "failed")"
                    }.joined(separator: "\n")
                )
            }
        } catch let error as AgentError {
            switch error {
            case .refused(let wording):
                report = ProcessReport(title: "The agent refused", message: wording)
            case .needsPairing:
                report = ProcessReport(title: "Not paired", message: "Pair with this agent to control it.")
            case .wrongPin:
                report = ProcessReport(title: "Wrong pin", message: "The agent's certificate no longer matches the pin.")
            default:
                report = ProcessReport(title: "Control failed", message: String(describing: error))
            }
        } catch {
            report = ProcessReport(title: "Control failed", message: error.localizedDescription)
        }
    }
}

/// One row: identity on the left, the two percent columns on the
/// right, and the control menu.
struct ProcessRow: View {
    let row: Process
    /// The target's catalog; empty falls back to TERM/KILL only.
    let signals: [SignalEntry]
    let working: Bool
    let onSignal: (Int) -> Void
    let onRenice: (Int) -> Void
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.name).lineLimit(1)
                    if let container = row.container {
                        Text(container.runtime)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.footnote)
                Text("\(row.user) · \(row.state)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(row.pid))
                .frame(width: 56, alignment: .trailing)
            Text(String(format: "%.1f", row.cpuPercent))
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(row.cpuPercent >= 50 ? Color.orange : Color.primary)
            Text(String(format: "%.1f", row.memPercent))
                .frame(width: 52, alignment: .trailing)
            controlMenu
        }
        .font(.caption.monospacedDigit())
    }

    /// The signal menu, htop's F9 in a row: every signal the target's
    /// platform numbers, plus renice by delta.
    private var controlMenu: some View {
        Menu {
            ForEach(signalItems, id: \.name) { item in
                Button("\(item.name) (\(item.number))") { onSignal(item.number) }
            }
            Divider()
            Button("Renice +10 (nicer)") { onRenice(10) }
            Button("Renice −5 (more CPU)") { onRenice(-5) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .disabled(working)
    }

    /// The signals offered for this row. The catalog's entries come
    /// first, in the agent's own order. Without a catalog (an agent
    /// older than the catalog endpoint, or a read failure) the menu
    /// still offers TERM and KILL: those two numbers are the same on
    /// every platform this app serves, so sending them needs no
    /// catalog. A numbered STOP/CONT guess would not be safe.
    private var signalItems: [SignalEntry] {
        if !signals.isEmpty { return signals }
        return [SignalEntry(name: "TERM", number: 15), SignalEntry(name: "KILL", number: 9)]
    }
}

/// One control call's outcome, shown as an alert.
struct ProcessReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
