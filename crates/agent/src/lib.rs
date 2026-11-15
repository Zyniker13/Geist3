// SPDX-License-Identifier: MIT OR Apache-2.0
//! The zTop agent: serves one host's samples over the versioned protocol.
//!
//! A background thread samples the host on a fixed interval and pushes
//! each sample into a bounded ring; HTTP handlers under `/v1` read the
//! ring: `/v1/snapshot` for the latest sample, `/v1/processes` for its
//! process list and `/v1/history` for recent samples. The live
//! WebSocket stream, TLS pairing and control actions arrive later in
//! milestone M4 under the transport decision (0003).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::Serialize;
use ztop_core::model::{Process, Sample};

/// The protocol version served under `/v1`. Grows when a change breaks
/// older clients; the client checks it before trusting any payload.
pub const PROTOCOL_VERSION: u32 = 1;

/// How often the agent samples the host.
pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(1);

/// Full-resolution history: one hour at the default one-second
/// interval. The ring drops the oldest sample past this bound; the
/// downsampled long tier arrives with the hub's persistence work.
const FULL_RESOLUTION: usize = 3600;

/// The shared state behind every handler: the sample ring.
pub struct AgentState {
    history: Mutex<VecDeque<Sample>>,
}

impl Default for AgentState {
    fn default() -> Self {
        Self {
            history: Mutex::new(VecDeque::with_capacity(FULL_RESOLUTION.min(1024))),
        }
    }
}

impl AgentState {
    /// Push one sample, dropping the oldest past the ring's bound.
    pub fn push(&self, sample: Sample) {
        let mut ring = self.history.lock().expect("history lock");
        if ring.len() == FULL_RESOLUTION {
            ring.pop_front();
        }
        ring.push_back(sample);
    }

    /// The latest sample, if the sampler has produced one yet.
    pub fn latest(&self) -> Option<Sample> {
        self.history.lock().expect("history lock").back().cloned()
    }

    /// Samples taken within the last `seconds` seconds, oldest first.
    pub fn since(&self, seconds: u64) -> Vec<Sample> {
        let ring = self.history.lock().expect("history lock");
        let from = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|age| age.as_millis() as u64)
            .unwrap_or(0)
            .saturating_sub(seconds.saturating_mul(1000));
        ring.iter()
            .filter(|sample| sample.timestamp_ms >= from)
            .cloned()
            .collect()
    }
}

/// The `seconds` query parameter of `/v1/history`.
#[derive(Debug, serde::Deserialize)]
struct HistoryQuery {
    seconds: Option<u64>,
}

/// The versioned envelope every `/v1` payload travels in.
#[derive(Debug, Serialize)]
struct Envelope<T> {
    protocol: u32,
    #[serde(flatten)]
    body: T,
}

/// Build the agent's HTTP router over `state`.
pub fn router(state: Arc<AgentState>) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/processes", get(processes))
        .route("/v1/history", get(history))
        .with_state(state)
}

/// Serve the agent protocol on `127.0.0.1:port` until the process is
/// stopped, sampling the host on [`DEFAULT_INTERVAL`] in the background.
pub async fn serve(port: u16) -> std::io::Result<()> {
    let state = Arc::new(AgentState::default());
    spawn_sampler(state.clone(), DEFAULT_INTERVAL);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
    axum::serve(listener, router(state)).await
}

/// Start the sampler thread for this platform. The collector is built
/// inside the thread and never leaves it: macOS collectors hold IOKit
/// objects the compiler cannot prove movable across threads.
fn spawn_sampler(state: Arc<AgentState>, interval: Duration) -> std::thread::JoinHandle<()> {
    fn run<C: ztop_core::collector::Collector + Default + 'static>(
        state: Arc<AgentState>,
        interval: Duration,
    ) {
        let mut collector = C::default();
        loop {
            match collector.sample() {
                Ok(sample) => state.push(sample),
                // One bad sample is skipped, not fatal: the next tick
                // retries, and a rate-dependent metric heals itself.
                Err(_error) => {}
            }
            std::thread::sleep(interval);
        }
    }

    #[cfg(target_os = "linux")]
    {
        std::thread::spawn(move || run::<ztop_core::linux::LinuxCollector>(state, interval))
    }
    #[cfg(target_os = "macos")]
    {
        std::thread::spawn(move || run::<ztop_core::macos_live::MacOsCollector>(state, interval))
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        // No collector on this platform: serve an empty history, which
        // the routes report as "no sample yet".
        let _ = (state, interval);
        std::thread::spawn(|| {})
    }
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "service": "ztop-agent",
        "protocol": PROTOCOL_VERSION,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

/// `GET /v1/snapshot`: the latest sample.
async fn snapshot(State(state): State<Arc<AgentState>>) -> Response {
    match state.latest() {
        Some(sample) => Json(Envelope {
            protocol: PROTOCOL_VERSION,
            body: SnapshotBody { sample },
        })
        .into_response(),
        None => no_sample_yet(),
    }
}

#[derive(Debug, Serialize)]
struct SnapshotBody {
    sample: Sample,
}

/// `GET /v1/processes`: the latest sample's process list.
async fn processes(State(state): State<Arc<AgentState>>) -> Response {
    match state.latest() {
        Some(sample) => Json(Envelope {
            protocol: PROTOCOL_VERSION,
            body: ProcessesBody {
                count: sample.processes.len(),
                processes: sample.processes,
            },
        })
        .into_response(),
        None => no_sample_yet(),
    }
}

#[derive(Debug, Serialize)]
struct ProcessesBody {
    count: usize,
    processes: Vec<Process>,
}

/// `GET /v1/history?seconds=N`: samples from the last `N` seconds,
/// oldest first; no parameter means the whole ring.
async fn history(State(state): State<Arc<AgentState>>, query: Query<HistoryQuery>) -> Response {
    let seconds = query.seconds.unwrap_or(u64::MAX);
    Json(Envelope {
        protocol: PROTOCOL_VERSION,
        body: HistoryBody {
            seconds,
            samples: state.since(seconds),
        },
    })
    .into_response()
}

#[derive(Debug, Serialize)]
struct HistoryBody {
    seconds: u64,
    samples: Vec<Sample>,
}

fn no_sample_yet() -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        "no sample yet: the sampler has not produced one",
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    /// A minimal sample built the way collectors build them: the fields
    /// without serde defaults are filled, everything else stays empty
    /// or unavailable.
    fn a_sample() -> Sample {
        use ztop_core::model::{AppleSilicon, Cpu, CpuTimes, Memory, Metric, Sensors, Unit};
        Sample {
            timestamp_ms: 0,
            hostname: "host-a".to_string(),
            system: String::new(),
            threads: Metric::unavailable(Unit::Count),
            kernel_threads: Metric::unavailable(Unit::Count),
            cpu: Cpu {
                cores: vec![CpuTimes::default()],
                busy_percent: vec![0.0],
                state_percent: vec![CpuTimes::default()],
                frequency_mhz: Vec::new(),
            },
            memory: Memory {
                total: Metric::unavailable(Unit::Bytes),
                used: Metric::unavailable(Unit::Bytes),
                free: Metric::unavailable(Unit::Bytes),
                buffers: Metric::unavailable(Unit::Bytes),
                shared: Metric::unavailable(Unit::Bytes),
                cache: Metric::unavailable(Unit::Bytes),
                swap_total: Metric::unavailable(Unit::Bytes),
                swap_used: Metric::unavailable(Unit::Bytes),
                compressed: Metric::unavailable(Unit::Bytes),
            },
            load_avg: [0.0; 3],
            uptime: Metric::unavailable(Unit::Seconds),
            processes: Vec::new(),
            disks: Vec::new(),
            net: Vec::new(),
            sensors: Sensors::default(),
            pressure: None,
            apple_silicon: AppleSilicon::default(),
            gpus: Vec::new(),
        }
    }

    fn a_process(pid: u32) -> Process {
        use ztop_core::model::ProcessIo;
        Process {
            pid,
            parent: None,
            user: "alice".to_string(),
            state: "S".to_string(),
            name: format!("worker-{pid:02}"),
            cpu_percent: 0.0,
            mem_percent: 0.0,
            virtual_bytes: 0,
            resident_bytes: 0,
            threads: 1,
            priority: None,
            nice: None,
            shared_bytes: None,
            total_time_ns: None,
            start_time_secs: None,
            processor: None,
            command: None,
            is_thread: false,
            kernel_thread: false,
            io: ProcessIo::default(),
            container: None,
        }
    }

    fn a_sample_with_processes(count: usize) -> Sample {
        let mut sample = a_sample();
        sample.processes = (0..count).map(|i| a_process(100 + i as u32)).collect();
        sample
    }

    #[tokio::test]
    async fn health_reports_service_protocol_and_version() {
        let response = health().await.into_response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["content-type"], "application/json");
    }

    #[tokio::test]
    async fn snapshot_serves_the_latest_sample() {
        let state = Arc::new(AgentState::default());
        assert_eq!(state.latest(), None);
        let sample = a_sample_with_processes(2);
        state.push(sample.clone());
        assert_eq!(state.latest(), Some(sample));
    }

    #[tokio::test]
    async fn snapshot_says_no_sample_yet_before_the_first_one() {
        let response = snapshot(State(Arc::new(AgentState::default())))
            .await
            .into_response();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn snapshot_carries_the_protocol_version() {
        let state = Arc::new(AgentState::default());
        state.push(a_sample());
        let response = snapshot(State(state)).await.into_response();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["protocol"], PROTOCOL_VERSION);
        assert!(value["sample"].is_object());
    }

    #[tokio::test]
    async fn processes_list_the_latest_samples_processes() {
        let state = Arc::new(AgentState::default());
        state.push(a_sample_with_processes(3));
        let response = processes(State(state)).await.into_response();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["protocol"], PROTOCOL_VERSION);
        assert_eq!(value["count"], 3);
        assert_eq!(value["processes"].as_array().map(Vec::len), Some(3));
    }

    #[tokio::test]
    async fn history_returns_the_requested_window() {
        let state = Arc::new(AgentState::default());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|age| age.as_millis() as u64)
            .unwrap_or(0);
        let mut older = a_sample();
        older.timestamp_ms = now.saturating_sub(10_000);
        let mut newer = a_sample();
        newer.timestamp_ms = now.saturating_sub(2_000);
        state.push(older);
        state.push(newer);
        // A one-second window keeps only the recent sample; no parameter
        // means the whole ring.
        let window = history(
            State(state.clone()),
            Query(HistoryQuery { seconds: Some(5) }),
        )
        .await
        .into_response();
        let bytes = axum::body::to_bytes(window.into_body(), usize::MAX)
            .await
            .expect("body");
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["protocol"], PROTOCOL_VERSION);
        assert_eq!(value["samples"].as_array().map(Vec::len), Some(1));
        assert_eq!(value["samples"][0]["timestamp_ms"], now - 2_000);

        let all = history(State(state), Query(HistoryQuery { seconds: None }))
            .await
            .into_response();
        let bytes = axum::body::to_bytes(all.into_body(), usize::MAX)
            .await
            .expect("body");
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["samples"].as_array().map(Vec::len), Some(2));
    }

    #[test]
    fn the_ring_drops_its_oldest_past_the_bound() {
        let state = Arc::new(AgentState::default());
        for i in 0..FULL_RESOLUTION as u64 + 5 {
            let mut sample = a_sample();
            sample.timestamp_ms = i;
            state.push(sample);
        }
        let ring = state.history.lock().expect("lock");
        assert_eq!(ring.len(), FULL_RESOLUTION);
        assert_eq!(ring.front().map(|s| s.timestamp_ms), Some(5));
        assert_eq!(
            ring.back().map(|s| s.timestamp_ms),
            Some(FULL_RESOLUTION as u64 + 4)
        );
    }
}
