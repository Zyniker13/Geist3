// SPDX-License-Identifier: MIT OR Apache-2.0
//! The macOS live collector: the same parse path as the recorded captures.
//!
//! The collector assembles the same text the `ztop capture` recorder writes
//! (the shared producers in [`crate::capture_macos`]) and parses it with
//! the same parsers the fixture replay uses, so a recorded capture and a
//! live sample are interpreted identically and the two cannot drift apart
//! (decision 0010).

use std::collections::HashMap;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::collector::{CollectError, Collector};
use crate::macos::{core_times, parse_hostinfo, parse_processes, sample_from_parts};
use crate::model::{CpuTimes, Sample};

/// Reads the live macOS host through Mach, libproc and sysctl.
///
/// Per-core and per-process rates are deltas between samples: the first
/// sample reports 0.0 everywhere, later samples the share of the interval
/// since the previous one, like `htop`. Every source is read without root
/// (decision 0009); what the kernel denies is `-` in the model, never
/// faked.
#[derive(Debug, Default)]
pub struct MacOsCollector {
    prev: Option<Prev>,
    hostname: Option<String>,
}

/// State from the previous sample needed for rates.
#[derive(Debug, Clone)]
struct Prev {
    at: Instant,
    cores: Vec<CpuTimes>,
    /// Cumulative (user, system) CPU nanoseconds per pid.
    pids: HashMap<u32, (u64, u64)>,
}

impl Collector for MacOsCollector {
    fn sample(&mut self) -> Result<Sample, CollectError> {
        let now = Instant::now();
        let timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| CollectError::Unavailable {
                origin: "clock",
                what: "the wall clock",
            })?
            .as_millis() as u64;
        let interval_secs = self
            .prev
            .as_ref()
            .map(|prev| now.duration_since(prev.at).as_secs_f64());

        let host_text = crate::capture_macos::hostinfo_text().ok_or(CollectError::Unavailable {
            origin: "hostinfo",
            what: "Mach host statistics",
        })?;
        let host = parse_hostinfo(&host_text);
        let procs = parse_processes(&crate::capture_macos::processes_text());
        let memsize =
            crate::capture_macos::sysctl_u64("hw.memsize").ok_or(CollectError::Unavailable {
                origin: "sysctl-hw_memsize",
                what: "total memory",
            })?;
        let hostname = self.hostname();
        let cores = core_times(&host.cores);

        let cpu_busy = match (self.prev.as_ref(), interval_secs) {
            (Some(prev), Some(secs)) => crate::model::core_percents(&cores, &prev.cores, secs),
            _ => vec![0.0; cores.len()],
        };

        // Per-process CPU rates: the delta of cumulative nanoseconds over
        // the interval, as a share of wall time.
        let interval_ns = interval_secs.map(|secs| (secs * 1e9) as u64).unwrap_or(0);
        let mut cpu_by_pid: HashMap<u32, f64> = HashMap::new();
        let mut current_pids: HashMap<u32, (u64, u64)> = HashMap::new();
        for proc in &procs {
            let Some(usage) = proc.task else {
                continue;
            };
            current_pids.insert(proc.pid, (usage.utime_ns, usage.stime_ns));
            let delta_ns = match self.prev.as_ref().and_then(|prev| prev.pids.get(&proc.pid)) {
                Some(&(old_user, old_system)) if interval_ns > 0 => {
                    (usage.utime_ns.saturating_sub(old_user)
                        + usage.stime_ns.saturating_sub(old_system)) as f64
                }
                _ => 0.0,
            };
            let percent = if interval_ns > 0 {
                (delta_ns / interval_ns as f64 * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            };
            cpu_by_pid.insert(proc.pid, percent);
        }

        let mut sample = sample_from_parts(host, procs, memsize, &hostname, timestamp_ms, cpu_busy)
            .map_err(|source| CollectError::Unavailable {
                origin: source.origin,
                what: source.what,
            })?;
        for process in &mut sample.processes {
            if let Some(cpu) = cpu_by_pid.get(&process.pid) {
                process.cpu_percent = *cpu;
            }
        }
        self.prev = Some(Prev {
            at: now,
            cores,
            pids: current_pids,
        });
        Ok(sample)
    }
}

impl MacOsCollector {
    /// The hostname, read once from `kern.hostname` and cached.
    fn hostname(&mut self) -> String {
        if let Some(name) = &self.hostname {
            return name.clone();
        }
        let name = crate::capture_macos::sysctl_text("kern.hostname")
            .unwrap_or_else(|| "unknown".to_string());
        self.hostname = Some(name.clone());
        name
    }
}
