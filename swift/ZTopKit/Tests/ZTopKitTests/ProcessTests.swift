// SPDX-License-Identifier: MIT OR Apache-2.0

import struct Foundation.Data
import class Foundation.JSONEncoder
import Testing

@testable import ZTopKit

/// The process table's pure filter and sort rules, and the control
/// wire shapes, against synthetic rows (fake values only).
struct ProcessTests {
    /// A process row with only the fields the table uses varied.
    func makeProcess(
        pid: UInt32,
        user: String = "alice",
        name: String = "worker",
        cpu: Double = 1.0,
        mem: Double = 0.5
    ) -> Process {
        Process(
            pid: pid,
            parent: nil,
            user: user,
            state: "run",
            name: name,
            cpuPercent: cpu,
            memPercent: mem,
            virtualBytes: 0,
            residentBytes: 0,
            threads: 1,
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

    // MARK: filter

    @Test func anEmptyQueryKeepsEverything() {
        let rows = [makeProcess(pid: 1, name: "worker"), makeProcess(pid: 2, name: "helper")]
        #expect(ProcessTable.filter(rows, query: "").count == 2)
        #expect(ProcessTable.filter(rows, query: "   ").count == 2)
    }

    @Test func theQueryMatchesNameUserAndPidPrefix() {
        let rows = [
            makeProcess(pid: 4242, user: "alice", name: "worker"),
            makeProcess(pid: 7, user: "bob", name: "helper"),
        ]
        // Name, case-insensitive.
        #expect(ProcessTable.filter(rows, query: "WORK").map(\.pid) == [4242])
        // User.
        #expect(ProcessTable.filter(rows, query: "bob").map(\.pid) == [7])
        // A pid whose digits start with the query.
        #expect(ProcessTable.filter(rows, query: "42").map(\.pid) == [4242])
        // No match anywhere.
        #expect(ProcessTable.filter(rows, query: "zzz").isEmpty)
    }

    // MARK: sort

    @Test func theDefaultViewSortsCpuDescendingThenPid() {
        let rows = [
            makeProcess(pid: 30, cpu: 5.0),
            makeProcess(pid: 10, cpu: 5.0),
            makeProcess(pid: 20, cpu: 9.0),
        ]
        #expect(ProcessTable.byCpu(rows).map(\.pid) == [20, 10, 30])
    }

    @Test func everyKeySortsBothWaysWithAStablePidTiebreak() {
        let rows = [
            makeProcess(pid: 30, user: "carol", name: "worker", cpu: 5.0, mem: 2.0),
            makeProcess(pid: 10, user: "alice", name: "helper", cpu: 5.0, mem: 2.0),
            makeProcess(pid: 20, user: "bob", name: "monitor", cpu: 1.0, mem: 9.0),
        ]
        // The pid tie-break stays pid-ASCENDING in both directions, so
        // descending is not the reverse of ascending when values tie.
        let keys: [(ProcessSortKey, [UInt32], [UInt32])] = [
            (.cpu, [20, 10, 30], [10, 30, 20]),   // 5.0 ties between 10 and 30
            (.memory, [10, 30, 20], [20, 10, 30]), // 2.0 ties between 10 and 30
            (.pid, [10, 20, 30], [30, 20, 10]),
            (.name, [10, 20, 30], [30, 20, 10]),  // helper, monitor, worker
            (.user, [10, 20, 30], [30, 20, 10]),  // alice, bob, carol
        ]
        for (key, ascending, descending) in keys {
            #expect(
                ProcessTable.sort(rows, by: key, direction: .ascending).map(\.pid) == ascending,
                "\(key) ascending"
            )
            #expect(
                ProcessTable.sort(rows, by: key, direction: .descending).map(\.pid) == descending,
                "\(key) descending"
            )
        }
    }

    // MARK: the control wire

    @Test func aSignalEncodesAsTheRustEnumNamesIt() throws {
        let data = try JSONEncoder().encode(ControlAction.signal(15))
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text == #"{"Signal":15}"#, "got \(text)")

        let renice = try JSONEncoder().encode(ControlAction.renice(10))
        #expect(String(data: renice, encoding: .utf8) == #"{"Renice":10}"#)
    }

    @Test func controlAndCatalogAndProcessBodiesDecode() throws {
        let reply = ControlReply(
            protocolVersion: 1,
            results: [
                ControlResult(pid: 1, ok: true, error: nil),
                ControlResult(pid: 2, ok: false, error: "no such process"),
            ]
        )
        let data = try JSONEncoder().encode(reply)
        let back = try AgentCoding.decoder.decode(ControlReply.self, from: data)
        #expect(back.results == reply.results)

        let catalog = SignalCatalogReply(
            protocolVersion: 1,
            signals: [SignalEntry(name: "TERM", number: 15), SignalEntry(name: "STOP", number: 17)]
        )
        let catalogBack = try AgentCoding.decoder.decode(
            SignalCatalogReply.self, from: JSONEncoder().encode(catalog)
        )
        #expect(catalogBack.signals.count == 2)
        #expect(catalogBack.signals[0].name == "TERM")

        let envelope = ProcessesEnvelope(protocolVersion: 1, count: 1, processes: [makeProcess(pid: 9)])
        let envelopeBack = try AgentCoding.decoder.decode(
            ProcessesEnvelope.self, from: JSONEncoder().encode(envelope)
        )
        #expect(envelopeBack.count == 1)
        #expect(envelopeBack.processes.first?.pid == 9)
    }
}
