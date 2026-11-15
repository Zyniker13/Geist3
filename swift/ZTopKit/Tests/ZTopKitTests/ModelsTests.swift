// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Testing

@testable import ZTopKit

/// Decoding against wire-shaped JSON: every field the agent writes, in
/// the snake_case names the protocol uses, with fake values only
/// (`host-a`, `alice`) per the repository's fixture rules.
struct ModelsTests {
    static let fullSnapshotJSON = """
    {
      "protocol": 1,
      "sample": {
        "timestamp_ms": 1700000000000,
        "hostname": "host-a",
        "system": "Linux 6.8.0-test",
        "threads": {"value": 48.0, "unit": "count", "available": true},
        "kernel_threads": {"value": 5.0, "unit": "count", "available": true},
        "cpu": {
          "cores": [{"user": 3.0, "system": 1.0, "nice": 2.0, "idle": 12.0,
                     "io_wait": 0.5, "irq": 0.25, "soft_irq": 0.25,
                     "steal": 0.0, "guest": 0.0}],
          "busy_percent": [30.0],
          "state_percent": [{"user": 25.0, "system": 12.5, "nice": 25.0,
                             "idle": 37.5, "io_wait": 0.0, "irq": 0.0,
                             "soft_irq": 0.0, "steal": 0.0, "guest": 0.0}],
          "frequency_mhz": [{"value": 3200.0, "unit": "hertz", "available": false}]
        },
        "memory": {
          "total": {"value": 17179869184.0, "unit": "bytes", "available": true},
          "used": {"value": 8589934592.0, "unit": "bytes", "available": true},
          "free": {"value": 8589934592.0, "unit": "bytes", "available": true},
          "buffers": {"value": 0.0, "unit": "bytes", "available": true},
          "shared": {"value": 0.0, "unit": "bytes", "available": true},
          "cache": {"value": 0.0, "unit": "bytes", "available": true},
          "swap_total": {"value": 0.0, "unit": "bytes", "available": false},
          "swap_used": {"value": 0.0, "unit": "bytes", "available": false},
          "compressed": {"value": 0.0, "unit": "bytes", "available": false}
        },
        "load_avg": [1.5, 1.25, 1.0],
        "uptime": {"value": 86400.0, "unit": "seconds", "available": true},
        "processes": [
          {
            "pid": 101, "parent": 1, "user": "alice", "state": "S",
            "name": "worker-01", "cpu_percent": 12.5, "mem_percent": 4.0,
            "virtual_bytes": 1073741824, "resident_bytes": 10485760,
            "threads": 4, "priority": 20, "nice": 0, "shared_bytes": 2097152,
            "total_time_ns": 123456789, "start_time_secs": 1699999000,
            "processor": 3, "command": "/usr/bin/worker-01",
            "is_thread": false, "kernel_thread": false,
            "io": {"read_bytes": 4096, "write_bytes": 2048,
                   "read_rate": 100.0, "write_rate": 50.0},
            "container": {"id": "abc123def456", "runtime": "docker"}
          }
        ],
        "disks": [{"name": "sda", "read_bytes": 1000, "write_bytes": 2000,
                   "mount": "/", "total_bytes": 100, "used_bytes": 50,
                   "usage_pct": 50.0, "read_rate": 1.0, "write_rate": 2.0}],
        "net": [{"name": "eth0", "rx_bytes": 10, "rx_packets": 1,
                 "tx_bytes": 20, "tx_packets": 2, "rx_rate": 0.5,
                 "tx_rate": 0.25}],
        "sensors": {
          "temps": [{"label": "zone-0", "celsius": {"value": 45.0,
                     "unit": "celsius", "available": true}}],
          "fans": [{"label": "fan-0", "rpm": {"value": 2400.0,
                    "unit": "revolutions_per_minute", "available": true}}],
          "battery": {"percent": {"value": 88.0, "unit": "percent",
                      "available": true},
                      "power_watts": {"value": 12.5, "unit": "watts",
                      "available": true},
                      "state": "discharging"},
          "gpu_watts": {"value": 0.0, "unit": "watts", "available": false},
          "system_watts": {"value": 0.0, "unit": "watts", "available": false}
        },
        "pressure": {
          "cpu": {"some": {"ten": 1.0, "sixty": 2.0, "three_hundred": 3.0},
                  "full": null},
          "memory": {"some": {"ten": 0.0, "sixty": 0.0, "three_hundred": 0.0},
                     "full": {"ten": 1.0, "sixty": 1.0, "three_hundred": 1.0}},
          "io": {"some": {"ten": 0.0, "sixty": 0.0, "three_hundred": 0.0},
                 "full": null}
        },
        "apple_silicon": {
          "chip_name": "Apple M3 Pro", "e_core_count": {"value": 6.0,
          "unit": "count", "available": true},
          "p_core_count": {"value": 6.0, "unit": "count", "available": true},
          "e_cluster_busy_percent": {"value": 5.0, "unit": "percent",
          "available": true},
          "e_cluster_frequency_mhz": {"value": 0.0, "unit": "hertz",
          "available": false},
          "p_cluster_busy_percent": {"value": 9.0, "unit": "percent",
          "available": true},
          "p_cluster_frequency_mhz": {"value": 0.0, "unit": "hertz",
          "available": false},
          "gpu_busy_percent": {"value": 0.0, "unit": "percent",
          "available": false},
          "gpu_frequency_mhz": {"value": 0.0, "unit": "hertz",
          "available": false},
          "ane_watts": {"value": 0.0, "unit": "watts", "available": false},
          "cpu_watts": {"value": 0.0, "unit": "watts", "available": false},
          "package_watts": {"value": 0.0, "unit": "watts", "available": false},
          "current_watts": {"value": 3.5, "unit": "watts", "available": true},
          "average_watts": {"value": 3.2, "unit": "watts", "available": true},
          "peak_watts": {"value": 5.0, "unit": "watts", "available": true},
          "thermal_pressure": {"value": 0.0, "unit": "count",
          "available": false},
          "power_history": [{"timestamp_ms": 1700000000000, "watts": 3.5}]
        },
        "gpus": [{"name": "AMD GPU (card1)",
                  "utilization": {"value": 9.0, "unit": "percent",
                  "available": true},
                  "memory_used": {"value": 1000.0, "unit": "bytes",
                  "available": true},
                  "memory_total": {"value": 2000.0, "unit": "bytes",
                  "available": true},
                  "watts": {"value": 0.0, "unit": "watts",
                  "available": false},
                  "temperature": {"value": 0.0, "unit": "celsius",
                  "available": false},
                  "fan_percent": {"value": 0.0, "unit": "percent",
                  "available": false}}]
      }
    }
    """

    @Test func aSnapshotDecodesFieldByField() throws {
        let data = try #require(Self.fullSnapshotJSON.data(using: .utf8))
        let envelope = try AgentCoding.decoder.decode(SnapshotEnvelope.self, from: data)
        let sample = try #require(try? envelope.checked())
        #expect(envelope.protocolVersion == 1)
        #expect(sample.hostname == "host-a")
        #expect(sample.system == "Linux 6.8.0-test")
        #expect(sample.timestampMs == 1_700_000_000_000)
        #expect(sample.threads.value == 48.0)
        #expect(sample.cpu.busyPercent == [30.0])
        #expect(sample.cpu.statePercent[0].user == 25.0)
        #expect(sample.cpu.statePercent[0].busy == 62.5)
        #expect(sample.memory.total.value == 17_179_869_184.0)
        #expect(sample.loadAvg == [1.5, 1.25, 1.0])
        let process = try #require(sample.processes.first)
        #expect(process.pid == 101)
        #expect(process.parent == 1)
        #expect(process.user == "alice")
        #expect(process.sharedBytes == 2_097_152)
        #expect(process.startTimeSecs == 1_699_999_000)
        #expect(process.command == "/usr/bin/worker-01")
        #expect(process.io.readRate == 100.0)
        #expect(process.container?.runtime == "docker")
        #expect(sample.disks[0].usagePct == 50.0)
        #expect(sample.net[0].rxRate == 0.5)
        #expect(sample.sensors.battery?.state == .discharging)
        #expect(sample.sensors.temps[0].celsius.value == 45.0)
        #expect(sample.pressure?.cpu.full == nil)
        #expect(sample.pressure?.memory.full?.ten == 1.0)
        #expect(sample.appleSilicon?.chipName == "Apple M3 Pro")
        #expect(sample.appleSilicon?.thermalPressure.available == false)
        #expect(sample.appleSilicon?.currentWatts.value == 3.5)
        #expect(sample.gpus[0].utilization.value == 9.0)
        #expect(sample.gpus[0].watts.available == false)
    }

    /// The optional groups decode as nil when an agent leaves them out;
    /// the fields the agent always writes stay required, as on the wire.
    @Test func aMinimalSampleDecodesWithDefaultsAbsent() throws {
        let json = """
        {
          "protocol": 1,
          "sample": {
            "timestamp_ms": 1,
            "hostname": "host-a",
            "system": "",
            "threads": {"value": 0, "unit": "count", "available": false},
            "kernel_threads": {"value": 0, "unit": "count", "available": false},
            "cpu": {"cores": [], "busy_percent": [], "state_percent": [],
                    "frequency_mhz": []},
            "memory": {
              "total": {"value": 0, "unit": "bytes", "available": false},
              "used": {"value": 0, "unit": "bytes", "available": false},
              "free": {"value": 0, "unit": "bytes", "available": false},
              "buffers": {"value": 0, "unit": "bytes", "available": false},
              "shared": {"value": 0, "unit": "bytes", "available": false},
              "cache": {"value": 0, "unit": "bytes", "available": false},
              "swap_total": {"value": 0, "unit": "bytes", "available": false},
              "swap_used": {"value": 0, "unit": "bytes", "available": false},
              "compressed": {"value": 0, "unit": "bytes", "available": false}
            },
            "load_avg": [0, 0, 0],
            "uptime": {"value": 0, "unit": "seconds", "available": false},
            "processes": [],
            "disks": [],
            "net": [],
            "sensors": {
              "temps": [], "fans": [],
              "gpu_watts": {"value": 0, "unit": "watts", "available": false},
              "system_watts": {"value": 0, "unit": "watts", "available": false}
            },
            "gpus": []
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let envelope = try AgentCoding.decoder.decode(SnapshotEnvelope.self, from: data)
        let sample = envelope.sample
        #expect(sample.system.isEmpty)
        #expect(sample.processes.isEmpty)
        #expect(sample.pressure == nil)
        #expect(sample.appleSilicon == nil)
        #expect(sample.gpus.isEmpty)
        #expect(sample.sensors.battery == nil)
    }

    @Test func pinsParseWhenWellFormedAndFailOtherwise() {
        let good = "SHA256:" + String(repeating: "ab", count: 32)
        #expect(parsePin(good) == good)
        #expect(parsePin(good.uppercased()) == good)
        #expect(parsePin("SHA256:abc") == nil)
        #expect(parsePin("nothex") == nil)
        #expect(parsePin("SHA256:" + String(repeating: "zz", count: 32)) == nil)
        #expect(parsePin("") == nil)
    }
}
