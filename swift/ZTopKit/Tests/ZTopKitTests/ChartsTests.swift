// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import ZTopKit

/// The chart series math, against synthetic samples (fake values
/// only, per the repository's fixture rules).
struct ChartsTests {
    /// A minimal sample with just the fields the series read; the
    /// rest get the unavailable/empty defaults.
    func makeSample(
        busy: Double? = 20.0,
        load: Double = 1.0,
        memUsed: Double = 4_294_967_296,
        memTotal: Double = 17_179_869_184,
        packageWatts: Double? = nil,
        rx: Double? = nil,
        tx: Double? = nil
    ) -> Sample {
        Sample(
            timestampMs: 1_700_000_000_000,
            hostname: "host-a",
            system: "test",
            threads: Metric(value: 0, unit: .count, available: false),
            kernelThreads: Metric(value: 0, unit: .count, available: false),
            cpu: Cpu(
                cores: [],
                busyPercent: busy.map { [$0] } ?? [],
                statePercent: [],
                frequencyMhz: []
            ),
            memory: Memory(
                total: Metric(value: memTotal, unit: .bytes, available: memTotal > 0),
                used: Metric(value: memUsed, unit: .bytes, available: true),
                free: Metric(value: 0, unit: .bytes, available: false),
                buffers: Metric(value: 0, unit: .bytes, available: false),
                shared: Metric(value: 0, unit: .bytes, available: false),
                cache: Metric(value: 0, unit: .bytes, available: false),
                swapTotal: Metric(value: 0, unit: .bytes, available: false),
                swapUsed: Metric(value: 0, unit: .bytes, available: false),
                compressed: Metric(value: 0, unit: .bytes, available: false)
            ),
            loadAvg: [load, load / 2, load / 4],
            uptime: Metric(value: 0, unit: .seconds, available: false),
            processes: [],
            disks: [],
            net: rx == nil && tx == nil
                ? []
                : [NetIf(
                    name: "eth0", rxBytes: 0, rxPackets: 0, txBytes: 0, txPackets: 0,
                    rxRate: rx, txRate: tx
                )],
            sensors: Sensors(
                temps: [],
                fans: [],
                battery: nil,
                gpuWatts: Metric(value: 0, unit: .watts, available: false),
                systemWatts: Metric(value: 0, unit: .watts, available: false)
            ),
            pressure: nil,
            appleSilicon: packageWatts.map { watts in
                AppleSilicon(
                    chipName: "Apple M3 Pro",
                    eCoreCount: Metric(value: 0, unit: .count, available: false),
                    pCoreCount: Metric(value: 0, unit: .count, available: false),
                    eClusterBusyPercent: Metric(value: 0, unit: .percent, available: false),
                    eClusterFrequencyMhz: Metric(value: 0, unit: .hertz, available: false),
                    pClusterBusyPercent: Metric(value: 0, unit: .percent, available: false),
                    pClusterFrequencyMhz: Metric(value: 0, unit: .hertz, available: false),
                    gpuBusyPercent: Metric(value: 0, unit: .percent, available: false),
                    gpuFrequencyMhz: Metric(value: 0, unit: .hertz, available: false),
                    aneWatts: Metric(value: 0, unit: .watts, available: false),
                    cpuWatts: Metric(value: 0, unit: .watts, available: false),
                    packageWatts: Metric(value: watts, unit: .watts, available: true),
                    currentWatts: Metric(value: 0, unit: .watts, available: false),
                    averageWatts: Metric(value: 0, unit: .watts, available: false),
                    peakWatts: Metric(value: 0, unit: .watts, available: false),
                    thermalPressure: Metric(value: 0, unit: .count, available: false),
                    powerHistory: []
                )
            },
            gpus: []
        )
    }

    @Test func cpuSeriesReadsMeanBusyAsAFraction() {
        let samples = (1...4).map { makeSample(busy: Double($0) * 10) }
        let series = ChartSeries.cpu(samples)
        #expect(series.unit == "%")
        #expect(series.topValue == 1)
        #expect(series.points == [0.1, 0.2, 0.3, 0.4])
        #expect(series.normalized == series.points)
        #expect(series.latest == 0.4)
        #expect(series.range?.low == 0.1)
        #expect(series.range?.high == 0.4)
    }

    @Test func cpuSeriesGapsWhereCoresAreMissing() {
        let samples = [makeSample(busy: 50.0), makeSample(busy: nil)]
        let series = ChartSeries.cpu(samples)
        #expect(series.points == [0.5, nil])
        #expect(series.latest == 0.5)
    }

    @Test func memorySeriesIsUsedOverTotalAndGapsWithoutTotal() {
        let series = ChartSeries.memory([makeSample()])
        #expect(abs((series.points[0] ?? 0) - 0.25) < 0.0001)
        let noTotal = makeSample(memTotal: 0)
        #expect(ChartSeries.memory([noTotal]).points[0] == nil)
    }

    @Test func loadSeriesScalesToTheWindowWithHeadroom() {
        let samples = [makeSample(load: 0.5), makeSample(load: 2.0), makeSample(load: 1.0)]
        let series = ChartSeries.load(samples)
        #expect(abs(series.topValue - 2.2) < 0.0001)
        #expect(series.points[1] == 2.0)
        #expect(abs((series.normalized[1] ?? 0) - 2.0 / 2.2) < 0.0001)
        // An idle window still tops at 1.
        let idle = ChartSeries.load([makeSample(load: 0.1)])
        #expect(idle.topValue == 1)
    }

    @Test func powerSeriesGapsWithoutTheSoCBlock() {
        let with = makeSample(packageWatts: 5.0)
        let without = makeSample()
        let series = ChartSeries.power([without, with])
        #expect(series.points == [nil, 5.0])
        #expect(series.latest == 5.0)
        #expect(abs(series.topValue - 5.5) < 0.0001)
        #expect(ChartSeries.power([without, without]).latest == nil)
    }

    @Test func networkSeriesSumsBothDirectionsAndGapsWithoutRates() {
        let series = ChartSeries.network([makeSample(rx: 100, tx: 50), makeSample()])
        #expect(series.points == [150.0, nil])
        #expect(abs(series.topValue - 165) < 0.0001)
    }

    @Test func normalizedClampsAboveTheTop() {
        // A hand-set top smaller than a point clamps; the auto-scale
        // builders (top = max * 1.1) keep every point under it.
        let pinned = ChartSeries(role: .cpu, label: "x", points: [2.0, 0.5], unit: "%", topValue: 1)
        #expect(pinned.normalized == [1.0, 0.5])
        let auto = ChartSeries.load([makeSample(load: 9.0), makeSample(load: 0.5)])
        #expect(abs((auto.normalized[0] ?? 0) - 9.0 / 9.9) < 0.0001)
    }

    @Test func humanBytesClimbsTheUnits() {
        #expect(humanBytes(999) == "999 B")
        #expect(humanBytes(1024) == "1.0 KB")
        #expect(humanBytes(1536) == "1.5 KB")
        #expect(humanBytes(1_572_864) == "1.5 MB")
        #expect(humanBytes(2.5 * 1024 * 1024 * 1024) == "2.5 GB")
        #expect(humanBytes(0) == "0 B")
        #expect(humanBytes(-5) == "0 B")
    }
}
