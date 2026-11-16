// SPDX-License-Identifier: MIT OR Apache-2.0
import SwiftUI
import ZTopKit

/// One host's detail: charts over the history window plus the
/// current readings the overview card compresses.
struct HostDetailView: View {
    @ObservedObject var store: HostStore
    let record: HostRecord

    @State private var history: [Sample] = []
    @State private var loadError: String?

    var body: some View {
        let live = store.live[record.id]
        ScrollView {
            HostDetailContent(record: record, live: live, history: history)
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .navigationTitle(record.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await refreshLoop() }
    }

    /// Fetches the history window on arrival and every few seconds
    /// after; a failed fetch keeps the last window and reports once.
    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                let samples = try await AgentClient(endpoint: record.endpoint)
                    .history(seconds: 3600)
                history = samples
                loadError = nil
            } catch {
                if history.isEmpty { loadError = error.localizedDescription }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// The detail's content, split out so the recorded-run hook can
/// render it offscreen (ImageRenderer cannot draw `ScrollView` or
/// `List`, the same limits the overview works around).
struct HostDetailContent: View {
    let record: HostRecord
    let live: HostLive?
    let history: [Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            let cpu = ChartSeries.cpu(effectiveHistory)
            if cpu.range != nil {
                chartSection(cpu, tint: .blue) {
                    CoreBars(busy: live?.sample?.cpu.busyPercent ?? [])
                }
            }
            let memory = ChartSeries.memory(effectiveHistory)
            if memory.range != nil {
                chartSection(memory, tint: .purple) {
                    memoryRows
                }
            }
            let load = ChartSeries.load(effectiveHistory)
            if load.range != nil {
                chartSection(load, tint: .orange) {
                    EmptyView()
                }
            }
            let network = ChartSeries.network(effectiveHistory)
            if network.range != nil {
                chartSection(network, tint: .green) {
                    networkRows
                }
            }
            let power = ChartSeries.power(effectiveHistory)
            if power.range != nil {
                chartSection(power, tint: .pink) {
                    EmptyView()
                }
            }
            diskSection
            sensorsSection
            socSection
            gpuSection
            pressureSection
        }
    }

    /// The history window when it arrived, else the one live sample —
    /// a host seen for the first time still shows its charts.
    private var effectiveHistory: [Sample] {
        if !history.isEmpty { return history }
        return live?.sample.map { [$0] } ?? []
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(stateColor)
                Text(record.name).font(.title3.weight(.semibold))
                Spacer()
                Text(stateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stateColor)
            }
            Text("\(record.host):\(record.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let sample = live?.sample {
                Text("\(sample.system) · up \(uptimeText(sample.uptime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch live?.state {
        case .live: .green
        case .stale: .orange
        case .unreachable: .red
        case .connecting, .none: .gray
        }
    }

    private var stateText: String {
        switch live?.state {
        case .live: "live"
        case .stale: "stale"
        case .unreachable: "unreachable"
        case .connecting, .none: "connecting…"
        }
    }

    private var memoryRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let memory = live?.sample?.memory {
                if memory.total.available, memory.used.available {
                    row("Used", "\(humanBytes(memory.used.value)) of \(humanBytes(memory.total.value))")
                }
                if memory.swapTotal.available, memory.swapUsed.available, memory.swapTotal.value > 0 {
                    row("Swap", "\(humanBytes(memory.swapUsed.value)) of \(humanBytes(memory.swapTotal.value))")
                }
                if memory.compressed.available, memory.compressed.value > 0 {
                    row("Compressed", humanBytes(memory.compressed.value))
                }
            }
        }
    }

    private var networkRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            let interfaces = (live?.sample?.net ?? []).sorted {
                traffic($0) > traffic($1)
            }
            ForEach(interfaces.prefix(4), id: \.name) { net in
                row(
                    net.name,
                    "↓ \(humanBytes(net.rxRate ?? 0))/s · ↑ \(humanBytes(net.txRate ?? 0))/s"
                )
            }
        }
    }

    private func traffic(_ net: NetIf) -> Double {
        (net.rxRate ?? 0) + (net.txRate ?? 0)
    }

    private var diskSection: some View {
        let disks = live?.sample?.disks ?? []
        return Group {
            if !disks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Disks")
                    ForEach(disks, id: \.name) { disk in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(disk.name) · \(disk.mount)").font(.caption)
                                Spacer()
                                Text(String(format: "%.0f%%", disk.usagePct))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Capsule()
                                .fill(.quaternary)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(disk.usagePct > 85 ? Color.red : disk.usagePct > 60 ? Color.orange : Color.blue)
                                        .frame(width: max(4, disk.usagePct / 100 * 240))
                                }
                                .frame(width: 240, height: 6)
                            if disk.readRate != nil || disk.writeRate != nil {
                                Text("read \(humanBytes(disk.readRate ?? 0))/s · write \(humanBytes(disk.writeRate ?? 0))/s")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sensorsSection: some View {
        let sensors = live?.sample?.sensors
        let rows: [(String, String)] = {
            var rows: [(String, String)] = []
            if let sensors {
                for temp in sensors.temps where temp.celsius.available {
                    rows.append((temp.label, String(format: "%.0f °C", temp.celsius.value)))
                }
                for fan in sensors.fans where fan.rpm.available {
                    rows.append((fan.label, String(format: "%.0f rpm", fan.rpm.value)))
                }
                if let battery = sensors.battery, battery.percent.available {
                    var text = String(format: "%.0f%%", battery.percent.value)
                    if battery.powerWatts.available {
                        text += String(format: " · %.1f W", battery.powerWatts.value)
                    }
                    rows.append(("Battery (\(battery.state.rawValue))", text))
                }
            }
            return rows
        }()
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Temperatures, fans, battery")
                    ForEach(rows, id: \.0) { label, value in
                        row(label, value)
                    }
                }
            }
        }
    }

    private var socSection: some View {
        let soc = live?.sample?.appleSilicon
        return Group {
            if let soc, soc.chipName != nil {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Apple Silicon")
                    if let chip = soc.chipName { row("Chip", chip) }
                    if soc.pClusterBusyPercent.available, soc.pCoreCount.available {
                        row(
                            "P cluster",
                            String(format: "%.0f%% of %.0f cores", soc.pClusterBusyPercent.value, soc.pCoreCount.value)
                        )
                    }
                    if soc.eClusterBusyPercent.available, soc.eCoreCount.available {
                        row(
                            "E cluster",
                            String(format: "%.0f%% of %.0f cores", soc.eClusterBusyPercent.value, soc.eCoreCount.value)
                        )
                    }
                    if soc.gpuBusyPercent.available {
                        row("GPU", String(format: "%.0f%%", soc.gpuBusyPercent.value))
                    }
                    if soc.currentWatts.available {
                        row("Power now", String(format: "%.1f W", soc.currentWatts.value))
                    }
                    if soc.averageWatts.available {
                        row("Power average", String(format: "%.1f W", soc.averageWatts.value))
                    }
                    if soc.peakWatts.available {
                        row("Power peak", String(format: "%.1f W", soc.peakWatts.value))
                    }
                    if soc.thermalPressure.available {
                        row("Thermal", thermalText(soc.thermalPressure.value))
                    }
                }
            }
        }
    }

    private var gpuSection: some View {
        let gpus = live?.sample?.gpus ?? []
        return Group {
            if !gpus.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("GPUs")
                    ForEach(gpus, id: \.name) { gpu in
                        row(
                            gpu.name,
                            gpu.utilization.available
                                ? String(format: "%.0f%% busy", gpu.utilization.value)
                                : "busy unavailable"
                        )
                    }
                }
            }
        }
    }

    private var pressureSection: some View {
        let pressure = live?.sample?.pressure
        return Group {
            if let pressure {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Pressure (PSI)")
                    row("CPU stalled", psiText(pressure.cpu))
                    row("Memory stalled", psiText(pressure.memory))
                    row("I/O stalled", psiText(pressure.io))
                }
            }
        }
    }

    // MARK: pieces

    private func chartSection(_ series: ChartSeries, tint: Color, @ViewBuilder extra: () -> some View)
        -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.label).font(.subheadline.weight(.medium))
                Spacer()
                if let latest = series.latest {
                    Text(chartValue(series, latest))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            MetricChart(points: series.normalized, tint: tint)
            if let range = series.range {
                Text("\(chartValue(series, range.low)) – \(chartValue(series, range.high))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            extra()
        }
    }

    private func chartValue(_ series: ChartSeries, _ value: Double) -> String {
        switch series.role {
        case .cpu, .memory:
            "\(Int((value * 100).rounded()))%"
        case .load:
            String(format: "%.2f", value)
        case .power:
            String(format: "%.1f W", value)
        case .network:
            "\(humanBytes(value))/s"
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func uptimeText(_ uptime: Metric) -> String {
        guard uptime.available else { return "?" }
        let seconds = Int(uptime.value)
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func thermalText(_ raw: Double) -> String {
        switch raw {
        case ..<0.5: "none"
        case ..<1.5: "light"
        case ..<2.5: "moderate"
        default: "severe"
        }
    }

    private func psiText(_ psi: Psi) -> String {
        String(format: "%.1f%% of the last 5 min", psi.some.threeHundred)
    }
}

/// Per-core busy bars, the detail's zoom-in on the CPU chart.
struct CoreBars: View {
    let busy: [Double]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(busy.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text("core \(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(busy[index] > 85 ? Color.red : busy[index] > 60 ? Color.orange : Color.green)
                            .frame(width: max(3, busy[index] / 100 * 84))
                    }
                    .frame(width: 84, height: 5)
                }
            }
        }
    }
}

/// A hand-drawn area chart: fills gaps, tops at 1. Canvas draws in
/// ImageRenderer (unlike `ProgressView` and `List`), and a Path
/// chart reads the same on iPad and Mac.
struct MetricChart: View {
    let points: [Double?]
    let tint: Color
    var height: CGFloat = 64

    var body: some View {
        Canvas { context, size in
            let count = points.count
            guard count > 0, size.width > 0 else { return }
            let step = count > 1 ? size.width / CGFloat(count - 1) : 0
            func y(_ value: Double) -> CGFloat {
                size.height - CGFloat(value) * (size.height - 2) - 1
            }
            // One filled area per run of known points.
            var run: [(x: CGFloat, y: CGFloat)] = []
            func flush() {
                guard run.count > 1 else {
                    if let only = run.first {
                        let rect = CGRect(x: only.x - 1.5, y: only.y - 1.5, width: 3, height: 3)
                        context.fill(Path(ellipseIn: rect), with: .color(tint))
                    }
                    run = []
                    return
                }
                var area = Path()
                area.move(to: CGPoint(x: run[0].x, y: size.height))
                for point in run { area.addLine(to: CGPoint(x: point.x, y: point.y)) }
                area.addLine(to: CGPoint(x: run[run.count - 1].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(tint.opacity(0.18)))
                var line = Path()
                line.move(to: CGPoint(x: run[0].x, y: run[0].y))
                for point in run.dropFirst() { line.addLine(to: CGPoint(x: point.x, y: point.y)) }
                context.stroke(line, with: .color(tint), lineWidth: 1.5)
                run = []
            }
            for (index, point) in points.enumerated() {
                let x = CGFloat(index) * step
                if let point {
                    run.append((x, y(point)))
                } else {
                    flush()
                }
            }
            flush()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}
