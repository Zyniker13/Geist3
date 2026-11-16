// SPDX-License-Identifier: MIT OR Apache-2.0

/// The metric charts the host detail draws, built from a history
/// window. Pure data — no UI — so the math is testable in ZTopKit and
/// the app only decides how to draw it.
public struct ChartSeries: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case cpu, memory, load, power, network
    }

    public var role: Role
    public var label: String
    /// The value at each sample, in `unit`; a gap (`nil`) marks a
    /// sample where the metric was unavailable.
    public var points: [Double?]
    public var unit: String
    /// The value a full chart height stands for: 1 for the 0…1
    /// fractions, or the window's maximum with headroom for the open
    /// ones.
    public var topValue: Double

    /// The points scaled to 0…1 of the chart height, gaps kept.
    public var normalized: [Double?] {
        points.map { point in
            guard let point, topValue > 0 else { return nil }
            return min(max(point / topValue, 0), 1)
        }
    }

    /// The newest known value, for the headline number.
    public var latest: Double? {
        points.reversed().first(where: { $0 != nil }) ?? nil
    }

    /// The busiest and quietest known values, for the chart's range
    /// caption.
    public var range: (low: Double, high: Double)? {
        let known = points.compactMap(\.self)
        guard let low = known.min(), let high = known.max() else { return nil }
        return (low, high)
    }

    /// Mean CPU busy (0…1) across the window; per-core readings are
    /// averaged by the model already.
    public static func cpu(_ samples: [Sample]) -> ChartSeries {
        ChartSeries(
            role: .cpu,
            label: "CPU busy",
            points: samples.map { sample in
                sample.cpu.busyPercent.isEmpty
                    ? nil
                    : min(sample.cpu.meanBusyPercent, 100) / 100
            },
            unit: "%",
            topValue: 1
        )
    }

    /// Memory used as a fraction of total; unavailable when either
    /// side is.
    public static func memory(_ samples: [Sample]) -> ChartSeries {
        ChartSeries(
            role: .memory,
            label: "Memory",
            points: samples.map { sample in
                guard sample.memory.total.available, sample.memory.used.available,
                      sample.memory.total.value > 0
                else { return nil }
                return min(max(sample.memory.used.value / sample.memory.total.value, 0), 1)
            },
            unit: "%",
            topValue: 1
        )
    }

    /// The one-minute load average, scaled to the window's own
    /// maximum (never below 1, so an idle host still reads as idle).
    public static func load(_ samples: [Sample]) -> ChartSeries {
        let known = samples.compactMap { sample in sample.loadAvg.first }
        let top = max(1.0, (known.max() ?? 1.0) * 1.1)
        return ChartSeries(
            role: .load,
            label: "Load (1 min)",
            points: samples.map { $0.loadAvg.first },
            unit: "",
            topValue: top
        )
    }

    /// Package watts on Apple Silicon; a gap wherever the sample has
    /// no SoC block or no package reading.
    public static func power(_ samples: [Sample]) -> ChartSeries {
        let known = samples.compactMap { sample -> Double? in
            guard let soc = sample.appleSilicon, soc.packageWatts.available
            else { return nil }
            return soc.packageWatts.value
        }
        let top = max(1.0, (known.max() ?? 1.0) * 1.1)
        return ChartSeries(
            role: .power,
            label: "Package power",
            points: samples.map { sample in
                guard let soc = sample.appleSilicon, soc.packageWatts.available
                else { return nil }
                return soc.packageWatts.value
            },
            unit: "W",
            topValue: top
        )
    }

    /// Total network traffic (receive + send) across all interfaces,
    /// in bytes per second.
    public static func network(_ samples: [Sample]) -> ChartSeries {
        let known = samples.compactMap { sample -> Double? in
            let rates = sample.net.flatMap { [$0.rxRate, $0.txRate].compactMap(\.self) }
            return rates.isEmpty ? nil : rates.reduce(0, +)
        }
        let top = max(1.0, (known.max() ?? 1.0) * 1.1)
        return ChartSeries(
            role: .network,
            label: "Network",
            points: samples.map { sample in
                let rates = sample.net.flatMap { [$0.rxRate, $0.txRate].compactMap(\.self) }
                return rates.isEmpty ? nil : rates.reduce(0, +)
            },
            unit: "B/s",
            topValue: top
        )
    }
}

/// Bytes rendered the way the screens show them: one decimal under a
/// megabyte, whole units above, so rows stay short and readable.
public func humanBytes(_ value: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var size = max(value, 0)
    var unit = 0
    while size >= 1024, unit < units.count - 1 {
        size /= 1024
        unit += 1
    }
    return unit == 0 ? "\(Int(size.rounded())) B" : String(format: "%.1f %@", size, units[unit])
}
