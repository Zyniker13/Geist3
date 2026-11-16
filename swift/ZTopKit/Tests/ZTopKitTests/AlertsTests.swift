// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import ZTopKit

/// The alert engine, against synthetic samples (fake values only, per
/// the repository's fixture rules).
struct AlertsTests {
    let hostA = UUID()
    let hostB = UUID()
    /// A rule that fires when CPU stays above 90% for five minutes.
    let cpuRule = AlertRule(name: "cpu hot", kind: .cpu, threshold: 90, duration: 300)

    /// A sample with the given scalar readings; everything else gets
    /// the unavailable/empty defaults.
    func makeSample(
        cpu: Double = 5.0,
        load: Double = 1.0,
        memUsed: Double = 4_294_967_296,
        memTotal: Double = 17_179_869_184,
        disks: [Disk] = []
    ) -> Sample {
        Sample(
            timestampMs: 1_700_000_000_000,
            hostname: "host-a",
            system: "test",
            threads: Metric(value: 0, unit: .count, available: false),
            kernelThreads: Metric(value: 0, unit: .count, available: false),
            cpu: Cpu(cores: [], busyPercent: [cpu], statePercent: [], frequencyMhz: []),
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
            disks: disks,
            net: [],
            sensors: Sensors(
                temps: [],
                fans: [],
                battery: nil,
                gpuWatts: Metric(value: 0, unit: .watts, available: false),
                systemWatts: Metric(value: 0, unit: .watts, available: false)
            ),
            pressure: nil,
            appleSilicon: nil,
            gpus: []
        )
    }

    /// One engine tick at `minutes` past the epoch.
    func tick(
        _ engine: inout AlertEngine, _ sample: Sample?, at minutes: Double,
        unreachable: Bool = false, host: UUID? = nil
    ) -> [AlertEvent] {
        engine.evaluate(
            rules: [cpuRule], hostID: host ?? hostA, sample: sample,
            unreachable: unreachable, now: Date(timeIntervalSince1970: minutes * 60))
    }

    @Test func firesOnlyAfterTheDurationHolds() {
        var engine = AlertEngine()
        let busy = makeSample(cpu: 95)
        #expect(tick(&engine, busy, at: 0).isEmpty)
        #expect(tick(&engine, busy, at: 1).isEmpty)
        #expect(tick(&engine, busy, at: 4).isEmpty)
        #expect(tick(&engine, busy, at: 5) == [.fired(ruleID: cpuRule.id, hostID: hostA, ruleName: "cpu hot")])
        // Still violating after firing: no repeat event.
        #expect(tick(&engine, busy, at: 6).isEmpty)
    }

    @Test func clearingBeforeTheDurationNeverFires() {
        var engine = AlertEngine()
        #expect(tick(&engine, makeSample(cpu: 95), at: 0).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 2).isEmpty)
        // Back under the threshold before five minutes pass.
        #expect(tick(&engine, makeSample(cpu: 10), at: 3).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 4).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 8.9).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 9).count == 1,
                "the timer restarts from the second violation's start")
    }

    @Test func clearsAfterFiringWhenTheConditionEnds() {
        var engine = AlertEngine()
        let busy = makeSample(cpu: 95)
        _ = tick(&engine, busy, at: 0)
        #expect(tick(&engine, busy, at: 5) == [.fired(ruleID: cpuRule.id, hostID: hostA, ruleName: "cpu hot")])
        #expect(tick(&engine, makeSample(cpu: 20), at: 6) == [.cleared(ruleID: cpuRule.id, hostID: hostA, ruleName: "cpu hot")])
        // Cleared and idle: re-arming starts a fresh violation window.
        #expect(tick(&engine, busy, at: 7).isEmpty)
    }

    @Test func perHostRuleOnlyWatchesItsHost() {
        var engine = AlertEngine()
        let rule = AlertRule(name: "a only", hostID: hostA, kind: .cpu, threshold: 90, duration: 60)
        #expect(engine.evaluate(
            rules: [rule], hostID: hostB, sample: makeSample(cpu: 99),
            unreachable: false, now: Date(timeIntervalSince1970: 0)
        ).isEmpty)
        #expect(engine.evaluate(
            rules: [rule], hostID: hostB, sample: makeSample(cpu: 99),
            unreachable: false, now: Date(timeIntervalSince1970: 120)
        ).isEmpty, "the rule never watches host-b, so its timer never starts")
        #expect(engine.evaluate(
            rules: [rule], hostID: hostA, sample: makeSample(cpu: 99),
            unreachable: false, now: Date(timeIntervalSince1970: 0)
        ).isEmpty)
        #expect(engine.evaluate(
            rules: [rule], hostID: hostA, sample: makeSample(cpu: 99),
            unreachable: false, now: Date(timeIntervalSince1970: 60)
        ).count == 1)
    }

    @Test func fleetWideRuleWatchesEveryHost() {
        var engine = AlertEngine()
        #expect(tick(&engine, makeSample(cpu: 95), at: 0).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 0, host: hostB).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 5, host: hostB)
            == [.fired(ruleID: cpuRule.id, hostID: hostB, ruleName: "cpu hot")])
        // host-a kept its own timer and also fires at the same tick.
        #expect(tick(&engine, makeSample(cpu: 95), at: 5)
            == [.fired(ruleID: cpuRule.id, hostID: hostA, ruleName: "cpu hot")])
    }

    @Test func unreachableRuleFiresAndALiveSampleClearsIt() {
        var engine = AlertEngine()
        let rule = AlertRule(name: "gone", kind: .unreachable, threshold: 0, duration: 60)
        #expect(engine.evaluate(rules: [rule], hostID: hostA, sample: nil, unreachable: true,
                                now: Date(timeIntervalSince1970: 0)).isEmpty)
        #expect(engine.evaluate(rules: [rule], hostID: hostA, sample: nil, unreachable: true,
                                now: Date(timeIntervalSince1970: 60))
            == [.fired(ruleID: rule.id, hostID: hostA, ruleName: "gone")])
        #expect(engine.evaluate(rules: [rule], hostID: hostA, sample: makeSample(), unreachable: false,
                                now: Date(timeIntervalSince1970: 70))
            == [.cleared(ruleID: rule.id, hostID: hostA, ruleName: "gone")])
    }

    @Test func unavailableMetricDoesNotFireAndResetsTheTimer() {
        var engine = AlertEngine()
        #expect(tick(&engine, makeSample(cpu: 95), at: 0).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 2).isEmpty)
        // A failed poll means the value is unknown: not violating, and
        // the accumulated time is dropped.
        #expect(tick(&engine, nil, at: 4).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 5).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 10).count == 1)
    }

    @Test func zeroDurationFiresImmediately() {
        var engine = AlertEngine()
        let rule = AlertRule(name: "now", kind: .cpu, threshold: 90, duration: 0)
        #expect(engine.evaluate(
            rules: [rule], hostID: hostA, sample: makeSample(cpu: 95),
            unreachable: false, now: Date(timeIntervalSince1970: 0)
        ) == [.fired(ruleID: rule.id, hostID: hostA, ruleName: "now")])
    }

    @Test func loadDiskAndMemoryKinds() {
        var engine = AlertEngine()
        var packedDisk = makeSample(cpu: 5, memUsed: 9_500_000_000, memTotal: 10_000_000_000)
        packedDisk.loadAvg = [1.0, 0.5, 0.25]
        packedDisk.disks = [
            Disk(name: "sda", readBytes: 0, writeBytes: 0, mount: "/",
                 totalBytes: 100, usedBytes: 95, usagePct: 95.0)
        ]
        let rules = [
            AlertRule(name: "load", kind: .load, threshold: 10, duration: 0),
            AlertRule(name: "mem", kind: .memory, threshold: 90, duration: 0),
            AlertRule(name: "disk", kind: .disk, threshold: 90, duration: 0),
        ]
        let events = engine.evaluate(
            rules: rules, hostID: hostA, sample: packedDisk, unreachable: false,
            now: Date(timeIntervalSince1970: 0))
        #expect(events.map(\.ruleName) == ["mem", "disk"],
                "memory 95% and disk 95% fire; load 1.0 stays under 10")

        var loaded = makeSample(cpu: 5)
        loaded.loadAvg = [12.5, 4.0, 2.0]
        let loadEvents = engine.evaluate(
            rules: [rules[0]], hostID: hostA, sample: loaded, unreachable: false,
            now: Date(timeIntervalSince1970: 0))
        #expect(loadEvents.map(\.ruleName) == ["load"])
    }

    @Test func deletedRulesLeaveNoStaleTracks() {
        var engine = AlertEngine()
        #expect(tick(&engine, makeSample(cpu: 95), at: 0).isEmpty)
        // The rule list no longer contains cpuRule: the old track must
        // go, so a re-added rule with the same id starts fresh.
        #expect(engine.evaluate(rules: [], hostID: hostA, sample: nil,
                                unreachable: false, now: Date(timeIntervalSince1970: 10)).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 20).isEmpty,
                "a re-added rule starts a fresh window, it does not inherit the old timer")
        #expect(tick(&engine, makeSample(cpu: 95), at: 24).isEmpty)
        #expect(tick(&engine, makeSample(cpu: 95), at: 25).count == 1,
                "five minutes after the re-added rule's window opened, it fires")
    }

    @Test func describeCoversEveryKind() {
        #expect(AlertRule(name: "x", kind: .cpu, threshold: 90, duration: 300).describe == "any host: CPU above 90% for 5m")
        #expect(AlertRule(name: "x", kind: .memory, threshold: 85, duration: 60).describe == "any host: memory above 85% for 1m")
        #expect(AlertRule(name: "x", kind: .load, threshold: 8, duration: 90).describe == "any host: load above 8.0 for 90s")
        #expect(AlertRule(name: "x", kind: .disk, threshold: 90, duration: 600).describe == "any host: disk above 90% for 10m")
        #expect(AlertRule(name: "x", kind: .unreachable, threshold: 0, duration: 60).describe == "any host: unreachable for 1m")
        #expect(AlertRule(name: "x", hostID: hostA, kind: .cpu, threshold: 50, duration: 60).describe == "CPU above 50% for 1m")
    }
}
