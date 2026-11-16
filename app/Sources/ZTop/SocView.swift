// SPDX-License-Identifier: MIT OR Apache-2.0
import SwiftUI
import ZTopKit

/// The Apple Silicon screen: the asitop-style zoom-in on the SoC —
/// clusters, GPU, power and thermal — pushed from the detail page's
/// Apple Silicon section (toolbar gauge).
///
/// Everything availability-gated like the detail page: a field the
/// host cannot expose unprivileged keeps its row out instead of
/// showing a dash, so the screen reads well on Intel Macs' agents too
/// (where it simply never appears — the entry point is hidden).
struct SocView: View {
    @ObservedObject var store: HostStore
    let record: HostRecord

    var body: some View {
        ScrollView {
            SocContent(record: record, live: store.live[record.id])
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .navigationTitle("SoC · \(record.name)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // No fetch loop of its own: everything the screen shows rides
        // the poller's latest snapshot, including the agent's own
        // power history (`AppleSilicon.powerHistory`).
    }
}

/// The SoC screen's content, split out so the recorded-run hook can
/// render it offscreen (ImageRenderer limits, decision 0046).
struct SocContent: View {
    let record: HostRecord
    let live: HostLive?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let soc = live?.sample?.appleSilicon
            if let soc, soc.chipName != nil {
                chipHeader(soc)
                clusterSection(soc)
                gpuSection(soc)
                powerSection(soc)
            } else {
                Text("the host has not reported an Apple Silicon chip yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chipHeader(_ soc: ZTopKit.AppleSilicon) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.pink)
                Text(soc.chipName ?? "")
                    .font(.title3.weight(.semibold))
                Spacer()
                if soc.thermalPressure.available {
                    Text(thermalText(soc.thermalPressure.value))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeTint(soc.thermalPressure.value).opacity(0.18), in: Capsule())
                        .foregroundStyle(badgeTint(soc.thermalPressure.value))
                }
            }
        }
    }

    private func clusterSection(_ soc: ZTopKit.AppleSilicon) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Clusters")
            if soc.pClusterBusyPercent.available {
                clusterBar("P cluster", busy: soc.pClusterBusyPercent, cores: soc.pCoreCount)
            }
            if soc.eClusterBusyPercent.available {
                clusterBar("E cluster", busy: soc.eClusterBusyPercent, cores: soc.eCoreCount)
            }
            if !soc.pClusterBusyPercent.available, !soc.eClusterBusyPercent.available {
                Text("cluster utilization unavailable unprivileged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func clusterBar(_ label: String, busy: Metric, cores: Metric?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(
                    cores?.available == true
                        ? String(format: "%.0f%% of %.0f cores", busy.value, cores!.value)
                        : String(format: "%.0f%%", busy.value)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(busy.value > 85 ? Color.red : busy.value > 60 ? Color.orange : Color.green)
                    .frame(width: max(3, busy.value / 100 * 300))
            }
            .frame(height: 6)
        }
    }

    private func gpuSection(_ soc: ZTopKit.AppleSilicon) -> some View {
        Group {
            if soc.gpuBusyPercent.available {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("GPU")
                    clusterBar("Integrated GPU", busy: soc.gpuBusyPercent, cores: nil)
                }
            }
        }
    }

    private func powerSection(_ soc: ZTopKit.AppleSilicon) -> some View {
        let series = ChartSeries.socPower(soc)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Power")
            if soc.currentWatts.available {
                row("Power now", String(format: "%.1f W", soc.currentWatts.value))
            }
            if soc.averageWatts.available {
                row("Power average", String(format: "%.1f W", soc.averageWatts.value))
            }
            if soc.peakWatts.available {
                row("Power peak", String(format: "%.1f W", soc.peakWatts.value))
            }
            if series.range != nil {
                chartBlock(series)
            }
        }
    }

    private func chartBlock(_ series: ChartSeries) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.label).font(.subheadline.weight(.medium))
                Spacer()
                if let latest = series.latest {
                    Text(String(format: "%.1f W", latest))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.pink)
                }
            }
            MetricChart(points: series.normalized, tint: .pink)
            if let range = series.range {
                Text("\(String(format: "%.1f", range.low)) – \(String(format: "%.1f", range.high)) W")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
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

    private func thermalText(_ raw: Double) -> String {
        switch raw {
        case ..<0.5: "none"
        case ..<1.5: "light"
        case ..<2.5: "moderate"
        default: "severe"
        }
    }

    private func badgeTint(_ raw: Double) -> Color {
        switch raw {
        case ..<0.5: .green
        case ..<1.5: .yellow
        case ..<2.5: .orange
        default: .red
        }
    }
}
