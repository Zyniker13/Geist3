// SPDX-License-Identifier: MIT OR Apache-2.0
//! The data model every part of zTop shares, mirrored from
//! `crates/core/src/model.rs` so the app reads the agent's protocol v1
//! shapes directly.
//!
//! Metrics carry their unit and their availability, because parity with
//! `htop` and `asitop` means several values exist only on one platform:
//! an absent source is an unavailable metric, not a missing field, so
//! layouts keep their place and the UI shows an explicit gap instead of
//! silently shifting rows.

import Foundation

/// One measured value: the number, its unit, and whether the host provides it.
public struct Metric: Codable, Hashable, Sendable {
    public var value: Double
    public var unit: Unit
    public var available: Bool

    /// A value this platform does not provide; renders as a dash, keeps its slot.
    public static func unavailable(_ unit: Unit) -> Metric {
        Metric(value: 0, unit: unit, available: false)
    }
}

/// Physical unit of a `Metric`.
public enum Unit: String, Codable, Hashable, Sendable {
    case percent
    case bytes
    case bytesPerSecond = "bytes_per_second"
    case hertz
    case celsius
    case watts
    case revolutionsPerMinute = "revolutions_per_minute"
    case seconds
    case count
}

/// CPU time per state, in seconds, for one core or the whole package.
public struct CpuTimes: Codable, Hashable, Sendable {
    public var user: Double
    public var system: Double
    public var nice: Double
    public var idle: Double
    public var ioWait: Double
    public var irq: Double
    public var softIrq: Double
    public var steal: Double
    public var guest: Double

    /// Total busy time (everything but idle). `guest` is deliberately left
    /// out: the kernel already counts guest time inside `user`.
    public var busy: Double {
        user + system + nice + ioWait + irq + softIrq + steal
    }

    /// Total observed time: busy plus idle.
    public var total: Double {
        busy + idle
    }
}

/// CPU state for one host: per-core times and, when reported, frequencies.
public struct Cpu: Codable, Hashable, Sendable {
    public var cores: [CpuTimes]
    /// Per-core CPU utilization in percent over the sample interval.
    public var busyPercent: [Double]
    /// Per-core busy time split by state, in percent of the interval.
    public var statePercent: [CpuTimes]
    /// Current frequency per core, when the platform reports it.
    public var frequencyMhz: [Metric]

    /// The mean busy percent across all cores; empty on the first sample.
    public var meanBusyPercent: Double {
        guard !busyPercent.isEmpty else { return 0 }
        return busyPercent.reduce(0, +) / Double(busyPercent.count)
    }
}

/// Memory and swap in bytes.
public struct Memory: Codable, Hashable, Sendable {
    public var total: Metric
    public var used: Metric
    public var free: Metric
    /// Kernel buffer cache (Linux); unavailable on macOS.
    public var buffers: Metric
    /// Shared memory (Linux); unavailable on macOS.
    public var shared: Metric
    /// Page cache (Linux); unavailable on macOS.
    public var cache: Metric
    public var swapTotal: Metric
    public var swapUsed: Metric
    /// macOS compressed memory; unavailable elsewhere.
    public var compressed: Metric
}

/// One process as the process table shows it.
public struct Process: Codable, Hashable, Sendable, Identifiable {
    public var pid: UInt32
    /// Parent pid, when the platform reports it.
    public var parent: UInt32?
    public var user: String
    public var state: String
    public var name: String
    /// CPU percent over the sample interval.
    public var cpuPercent: Double
    public var memPercent: Double
    public var virtualBytes: UInt64
    public var residentBytes: UInt64
    public var threads: UInt32
    /// Scheduling priority, when the platform reports it.
    public var priority: Int32?
    /// Nice value, when the platform reports it.
    public var nice: Int32?
    /// Shared memory bytes, when the platform reports them (Linux).
    public var sharedBytes: UInt64?
    /// Total CPU time (user plus system) since process start, when reported.
    public var totalTimeNs: UInt64?
    /// Wall-clock start time in Unix seconds, when reported.
    public var startTimeSecs: UInt64?
    /// Index of the core the process last ran on, when reported (Linux).
    public var processor: UInt32?
    /// Full command line, when the platform reports it.
    public var command: String?
    /// This row is a thread of the process named by `parent`.
    public var isThread: Bool
    /// This process is a kernel thread.
    public var kernelThread: Bool
    /// Per-process disk I/O, when the platform reports it (Linux).
    public var io: ProcessIo
    /// The container the process runs in, when its cgroup path names one.
    public var container: Container?

    public var id: UInt32 { pid }

    public init(
        pid: UInt32,
        parent: UInt32? = nil,
        user: String,
        state: String,
        name: String,
        cpuPercent: Double,
        memPercent: Double,
        virtualBytes: UInt64,
        residentBytes: UInt64,
        threads: UInt32,
        priority: Int32? = nil,
        nice: Int32? = nil,
        sharedBytes: UInt64? = nil,
        totalTimeNs: UInt64? = nil,
        startTimeSecs: UInt64? = nil,
        processor: UInt32? = nil,
        command: String? = nil,
        isThread: Bool = false,
        kernelThread: Bool = false,
        io: ProcessIo = ProcessIo(),
        container: Container? = nil
    ) {
        self.pid = pid
        self.parent = parent
        self.user = user
        self.state = state
        self.name = name
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.virtualBytes = virtualBytes
        self.residentBytes = residentBytes
        self.threads = threads
        self.priority = priority
        self.nice = nice
        self.sharedBytes = sharedBytes
        self.totalTimeNs = totalTimeNs
        self.startTimeSecs = startTimeSecs
        self.processor = processor
        self.command = command
        self.isThread = isThread
        self.kernelThread = kernelThread
        self.io = io
        self.container = container
    }
}

/// One container as the process table and detail screen show it.
public struct Container: Codable, Hashable, Sendable {
    /// The runtime's identifier for the container.
    public var id: String
    /// The runtime the cgroup path names.
    public var runtime: String
}

/// Per-process disk I/O counters and rates.
public struct ProcessIo: Codable, Hashable, Sendable {
    public var readBytes: UInt64?
    public var writeBytes: UInt64?
    public var readRate: Double?
    public var writeRate: Double?

    public init(
        readBytes: UInt64? = nil,
        writeBytes: UInt64? = nil,
        readRate: Double? = nil,
        writeRate: Double? = nil
    ) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readRate = readRate
        self.writeRate = writeRate
    }
}

/// One pressure-stall resource: `some` and optional `full` averages.
public struct Psi: Codable, Hashable, Sendable {
    public var some: PsiAvg
    /// The kernel reports no `full` line for cpu.
    public var full: PsiAvg?
}

/// The three averages of one pressure stall kind, in percent.
public struct PsiAvg: Codable, Hashable, Sendable {
    public var ten: Double
    public var sixty: Double
    public var threeHundred: Double
}

/// Pressure stall information for the three resources.
public struct Pressure: Codable, Hashable, Sendable {
    public var cpu: Psi
    public var memory: Psi
    public var io: Psi
}

/// Lifetime IO counters of one block device, in bytes.
public struct Disk: Codable, Hashable, Sendable {
    public var name: String
    public var readBytes: UInt64
    public var writeBytes: UInt64
    /// Mount point (e.g. `/`, `/home`). Empty when unavailable.
    public var mount: String
    /// Total capacity in bytes (0 when unavailable).
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    /// Usage percentage (0–100).
    public var usagePct: Double
    /// Disk read rate in bytes per second between two live samples.
    public var readRate: Double?
    /// Disk write rate in bytes per second between two live samples.
    public var writeRate: Double?
}

/// Lifetime counters of one network interface.
public struct NetIf: Codable, Hashable, Sendable {
    public var name: String
    public var rxBytes: UInt64
    public var rxPackets: UInt64
    public var txBytes: UInt64
    public var txPackets: UInt64
    public var rxRate: Double?
    public var txRate: Double?
}

/// One discrete GPU as the platform reports it.
public struct Gpu: Codable, Hashable, Sendable {
    public var name: String
    public var utilization: Metric
    public var memoryUsed: Metric
    public var memoryTotal: Metric
    public var watts: Metric
    public var temperature: Metric
    public var fanPercent: Metric
}

/// One temperature reading.
public struct TempSensor: Codable, Hashable, Sendable {
    public var label: String
    public var celsius: Metric
}

/// One fan.
public struct Fan: Codable, Hashable, Sendable {
    public var label: String
    public var rpm: Metric
}

/// Charge state of a battery, as the kernel reports it.
public enum BatteryState: String, Codable, Hashable, Sendable {
    case charging
    case discharging
    case full
    case unknown
}

/// One battery.
public struct Battery: Codable, Hashable, Sendable {
    public var percent: Metric
    /// Current power draw; often unavailable on desktops and servers.
    public var powerWatts: Metric
    public var state: BatteryState
}

/// Temperatures, fans, battery and power.
public struct Sensors: Codable, Hashable, Sendable {
    public var temps: [TempSensor]
    public var fans: [Fan]
    public var battery: Battery?
    /// GPU power draw over the sample interval, where a source exists.
    public var gpuWatts: Metric
    /// Whole-system power draw, where a source exists (macOS `PSTR`).
    public var systemWatts: Metric
}

/// One point in the power-history chart.
public struct PowerSample: Codable, Hashable, Sendable {
    /// Milliseconds since the Unix epoch.
    public var timestampMs: UInt64
    /// Power in watts.
    public var watts: Double
}

/// Apple Silicon–specific metrics (E/P clusters, GPU, ANE, power,
/// thermal pressure). Where the host does not expose a source
/// unprivileged, the field stays unavailable so layouts keep their place.
public struct AppleSilicon: Codable, Hashable, Sendable {
    /// Chip name, e.g. "Apple M3 Pro". Unavailable on non-Apple Silicon.
    public var chipName: String?
    public var eCoreCount: Metric
    public var pCoreCount: Metric
    public var eClusterBusyPercent: Metric
    public var eClusterFrequencyMhz: Metric
    public var pClusterBusyPercent: Metric
    public var pClusterFrequencyMhz: Metric
    public var gpuBusyPercent: Metric
    public var gpuFrequencyMhz: Metric
    /// ANE (Neural Engine) power in watts. Unavailable unprivileged.
    public var aneWatts: Metric
    /// CPU power in watts (current). Unavailable unprivileged.
    public var cpuWatts: Metric
    /// Package power in watts (current). Unavailable unprivileged.
    public var packageWatts: Metric
    /// Current power in watts (CPU + GPU + ANE + other).
    public var currentWatts: Metric
    /// Average power in watts over the history window.
    public var averageWatts: Metric
    /// Peak power in watts observed during the history window.
    public var peakWatts: Metric
    /// Thermal pressure level (0 = none, 1 = light, 2 = moderate, 3 = severe).
    public var thermalPressure: Metric
    /// Power-history samples for the chart (most recent last).
    public var powerHistory: [PowerSample]
}

/// One measurement of one host: the unit of live data the whole app reads.
public struct Sample: Codable, Hashable, Sendable {
    /// Milliseconds since the Unix epoch.
    public var timestampMs: UInt64
    public var hostname: String
    /// The operating system name and kernel version, when reported.
    public var system: String
    /// Total threads on the host, when the platform reports them.
    public var threads: Metric
    /// Kernel threads (Linux); unavailable on macOS.
    public var kernelThreads: Metric
    public var cpu: Cpu
    public var memory: Memory
    /// 1, 5 and 15 minute load averages.
    public var loadAvg: [Double]
    public var uptime: Metric
    public var processes: [Process]
    /// Lifetime IO counters per block device.
    public var disks: [Disk]
    /// Lifetime counters per network interface.
    public var net: [NetIf]
    /// Temperatures, fans and battery, when the host provides them.
    public var sensors: Sensors
    /// Pressure stall information; absent when the host does not expose it.
    public var pressure: Pressure?
    /// Apple Silicon–specific metrics; absent elsewhere.
    public var appleSilicon: AppleSilicon?
    /// Discrete GPUs; empty when the host has none.
    public var gpus: [Gpu]
}
