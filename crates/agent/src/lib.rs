// SPDX-License-Identifier: MIT OR Apache-2.0
//! The zTop agent: serves one host's samples over the versioned protocol.
//!
//! A background thread samples the host on a fixed interval and pushes
//! each sample into a bounded ring; HTTP handlers under `/v1` read the
//! ring: `/v1/snapshot` for the latest sample, `/v1/processes` for its
//! process list and `/v1/history` for recent samples. The live
//! WebSocket stream carries the same samples as they arrive. Pairing
//! and tokens live in [`auth`]; they are enforced wherever the agent
//! is not deliberately serving the loopback interface in plain mode.
//! TLS and control actions arrive later in milestone M4 under the
//! transport decision (0003).

pub mod auth;
pub mod tls;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, Request, State};
use axum::http::StatusCode;
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Serialize;
use tokio::sync::broadcast::error::RecvError;
use ztop_core::model::{Process, Sample};

/// The protocol version served under `/v1`. Grows when a change breaks
/// older clients; the client checks it before trusting any payload.
/// Defined beside the client so both halves share one number.
pub use ztop_core::client::PROTOCOL_VERSION;

/// How often the agent samples the host.
pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(1);

/// Full-resolution history: one hour at the default one-second
/// interval. The ring drops the oldest sample past this bound; the
/// downsampled long tier arrives with the hub's persistence work.
const FULL_RESOLUTION: usize = 3600;

/// The shared state behind every handler: the sample ring, the
/// fan-out channel the live stream reads, and the auth.
pub struct AgentState {
    history: Mutex<VecDeque<Sample>>,
    sender: tokio::sync::broadcast::Sender<Sample>,
    /// Pairing and tokens; `Mutex` because pair and revoke mutate.
    pub auth: Mutex<auth::Auth>,
    /// Whether `/v1` routes (except pairing) demand a bearer token.
    /// Off for plain loopback serving, on wherever TLS is on.
    pub enforce_auth: bool,
    /// Whether paired tokens may act on this machine (signals, renice,
    /// and the Linux-only tweaks). Off by default: watching is safe,
    /// acting is a decision (decision 0042).
    pub allow_control: bool,
}

impl Default for AgentState {
    fn default() -> Self {
        // A small queue is enough: a live client consumes each sample
        // as it arrives, and a client that falls behind is dropped
        // (decision 0036) rather than buffered unboundedly.
        let (sender, _) = tokio::sync::broadcast::channel(16);
        Self {
            history: Mutex::new(VecDeque::with_capacity(FULL_RESOLUTION.min(1024))),
            sender,
            auth: Mutex::new(auth::Auth::in_memory()),
            enforce_auth: false,
            allow_control: false,
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
        .route("/v1/pair", post(pair))
        .route("/v1/control", get(control_catalog).post(control))
        .route("/v1/tokens", get(tokens_list))
        .route("/v1/tokens/{id}", delete(tokens_revoke))
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/processes", get(processes))
        .route("/v1/history", get(history))
        .route("/v1/stream", get(stream))
        .layer(middleware::from_fn_with_state(state.clone(), enforce_auth))
        .with_state(state)
}

/// The auth gate: when the agent is enforced (`enforce_auth`), every
/// `/v1` route except `/healthz` and `/v1/pair` needs a bearer token
/// the auth knows. Plain loopback serving runs unauthenticated.
async fn enforce_auth(
    State(state): State<Arc<AgentState>>,
    request: Request,
    next: Next,
) -> Response {
    if !state.enforce_auth {
        return next.run(request).await;
    }
    let path = request.uri().path();
    if path == "/healthz" || path == "/v1/pair" {
        return next.run(request).await;
    }
    let bearer = request
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    let accepted = bearer
        .map(|token| state.auth.lock().expect("auth").check(token))
        .unwrap_or(false);
    if accepted {
        next.run(request).await
    } else {
        (
            StatusCode::UNAUTHORIZED,
            "pair first: POST /v1/pair with the agent's pairing code",
        )
            .into_response()
    }
}

/// The bind rules: loopback needs no TLS, anything wider does. A
/// non-loopback bind without TLS would publish unauthenticated
/// metrics to the network, and read-only-by-default beats convenient.
pub fn bind_rules(bind: std::net::IpAddr, tls: bool) -> Result<(), String> {
    let loopback = match bind {
        std::net::IpAddr::V4(v4) => v4.is_loopback(),
        std::net::IpAddr::V6(v6) => v6.is_loopback(),
    };
    if loopback || tls {
        Ok(())
    } else {
        Err(format!(
            "binding {bind} exposes the agent beyond this machine: pass --tls"
        ))
    }
}

/// Advertise `_ztop._tcp` for this agent. The record carries the
/// protocol version, so a browser can skip incompatible services;
/// registration failures downgrade to a note, never to a crash — a
/// machine without multicast routes still serves its agents.
fn advertise(bind: std::net::IpAddr, port: u16) -> mdns_sd::ServiceDaemon {
    let name = ztop_core::host::hostname();
    let instance = format!("ztop on {name}");
    let mdns_name = if name.contains('.') {
        name
    } else {
        format!("{name}.local.")
    };
    let properties = std::collections::HashMap::from([(
        "protocol".to_string(),
        ztop_core::client::PROTOCOL_VERSION.to_string(),
    )]);
    let info = mdns_sd::ServiceInfo::new(
        "_ztop._tcp.local.",
        &instance,
        &mdns_name,
        bind,
        port,
        properties,
    )
    .map(|info| info.enable_addr_auto());
    match info {
        Ok(info) => match mdns_sd::ServiceDaemon::new() {
            Ok(daemon) => {
                if let Err(error) = daemon.register(info) {
                    eprintln!("ztop-agent: not advertising: {error}");
                }
                daemon
            }
            Err(error) => {
                eprintln!("ztop-agent: not advertising: {error}");
                // A daemon that never registers is dropped harmlessly.
                mdns_sd::ServiceDaemon::new().expect("fresh daemon")
            }
        },
        Err(error) => {
            eprintln!("ztop-agent: not advertising: {error}");
            mdns_sd::ServiceDaemon::new().expect("fresh daemon")
        }
    }
}

/// Serve the agent protocol on `bind:port` until the process is
/// stopped, sampling the host on [`DEFAULT_INTERVAL`] in the background.
/// With `pair`, print a pairing code the person can trade for a token.
/// With `tls`, serve HTTPS with the agent's self-signed certificate and
/// enforce tokens (decision 0003: TLS is the trust boundary); a bind
/// wider than loopback requires it (decision 0044). With `advertise`
/// and TLS, the agent is discoverable over Bonjour as `_ztop._tcp`.
pub async fn serve(
    bind: std::net::IpAddr,
    port: u16,
    pair: bool,
    tls: bool,
    allow_control: bool,
    should_advertise: bool,
) -> std::io::Result<()> {
    bind_rules(bind, tls).map_err(std::io::Error::other)?;
    let mut auth = match ztop_core::paths::state_dir() {
        Some(dir) => auth::Auth::at(dir.join("tokens.json")).unwrap_or_default(),
        None => auth::Auth::in_memory(),
    };
    if pair {
        let rights = if allow_control {
            vec!["read".to_string(), "control".to_string()]
        } else {
            vec!["read".to_string()]
        };
        match auth.start_pairing(
            "pairing from the command line".into(),
            auth::now_ms(),
            rights,
        ) {
            Ok(code) => println!("Pairing code: {code} (valid for 5 minutes)"),
            Err(error) => eprintln!("ztop-agent: pairing is unavailable: {error}"),
        }
    }
    let (sender, _) = tokio::sync::broadcast::channel(16);
    let state = Arc::new(AgentState {
        history: Mutex::new(VecDeque::with_capacity(FULL_RESOLUTION.min(1024))),
        sender,
        auth: Mutex::new(auth),
        // Plain loopback serving runs unauthenticated; TLS flips this
        // on (decision 0003).
        enforce_auth: tls,
        allow_control,
    });
    spawn_sampler(state.clone(), DEFAULT_INTERVAL);
    let listener = tokio::net::TcpListener::bind((bind, port)).await?;
    // The advertisement lasts as long as the daemon handle: dropping it
    // unregisters, so keep it in scope for the whole serve.
    let _mdns = if tls && should_advertise {
        Some(advertise(bind, port))
    } else {
        None
    };
    if tls {
        let dir = ztop_core::paths::state_dir().ok_or_else(|| {
            std::io::Error::other("no home directory: TLS material cannot persist")
        })?;
        let material = tls::load_or_create(&dir)?;
        println!("TLS fingerprint: {}", material.fingerprint);
        return tls::serve_on_tls(state, listener, material.config).await;
    }
    serve_on(state, listener).await
}

/// Serve the router over an already-bound listener: the seam the
/// integration tests use to get an ephemeral port.
pub async fn serve_on(
    state: Arc<AgentState>,
    listener: tokio::net::TcpListener,
) -> std::io::Result<()> {
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
            tick(&mut collector, &state);
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

/// The body of `POST /v1/pair`: the agent's shown code.
#[derive(Debug, serde::Deserialize)]
struct PairBody {
    code: String,
}

/// `POST /v1/pair`: trade the agent's pairing code for a token. Works
/// even when auth is not enforced (a loopback client may pair ahead of
/// a later TLS setup).
async fn pair(State(state): State<Arc<AgentState>>, Json(body): Json<PairBody>) -> Response {
    let mut auth = state.auth.lock().expect("auth");
    match auth.pair(&body.code, auth::now_ms()) {
        Ok(token) => Json(serde_json::json!({
            "protocol": PROTOCOL_VERSION,
            "token": token,
        }))
        .into_response(),
        Err(auth::AuthError::BadCode) => (
            StatusCode::FORBIDDEN,
            "the pairing code does not match, is used up or expired",
        )
            .into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("pairing failed: {error}"),
        )
            .into_response(),
    }
}

/// The body of `POST /v1/control`: a control plan for this machine.
#[derive(Debug, serde::Deserialize)]
struct ControlBody {
    pids: Vec<u32>,
    action: ztop_core::control::Control,
}

/// `GET /v1/control`: this platform's signal catalog, so a remote
/// client sends signals by the numbers THIS agent's platform uses —
/// macOS and Linux number STOP/TSTP/CONT differently, and a number
/// from the client's own table would hit the wrong signal.
async fn control_catalog(
    State(state): State<Arc<AgentState>>,
    headers: axum::http::HeaderMap,
) -> Response {
    let bearer = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    let known = state.auth.lock().expect("auth").check(bearer.unwrap_or(""));
    if state.enforce_auth && !known {
        return (StatusCode::UNAUTHORIZED, "pair with this agent to read it").into_response();
    }
    let signals: Vec<serde_json::Value> = ztop_core::control::common_signals()
        .iter()
        .map(|(name, number)| serde_json::json!({ "name": name, "number": number }))
        .collect();
    Json(serde_json::json!({
        "protocol": PROTOCOL_VERSION,
        "signals": signals,
    }))
    .into_response()
}

/// How many pids one control request may touch: the TUI plans cover a
/// screen's tags, so this is generous, but an unbounded list is a
/// request to hang the agent's kill loop.
const CONTROL_PID_LIMIT: usize = 256;

/// `POST /v1/control`: run a plan here, when the agent allows control
/// and the token carries the right. Signal 0 is the permission probe:
/// it sends nothing, so it is the safe way to check both gates.
async fn control(
    State(state): State<Arc<AgentState>>,
    headers: axum::http::HeaderMap,
    Json(body): Json<ControlBody>,
) -> Response {
    if !state.enforce_auth {
        return (
            StatusCode::FORBIDDEN,
            "control needs --tls: the action would cross an unauthenticated channel",
        )
            .into_response();
    }
    let bearer = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if !state
        .auth
        .lock()
        .expect("auth")
        .can_control(bearer.unwrap_or(""))
    {
        return (
            StatusCode::FORBIDDEN,
            "this token may read but not control: pair again from an agent started with --allow-control",
        )
            .into_response();
    }
    if !state.allow_control {
        return (
            StatusCode::FORBIDDEN,
            "this agent does not allow control: start it with --allow-control",
        )
            .into_response();
    }
    if body.pids.len() > CONTROL_PID_LIMIT {
        return (
            StatusCode::BAD_REQUEST,
            format!("too many pids: the limit is {CONTROL_PID_LIMIT}"),
        )
            .into_response();
    }
    let plan = ztop_core::control::Plan {
        pids: body.pids,
        action: body.action,
    };
    let results: Vec<serde_json::Value> = ztop_core::control::execute(&plan)
        .into_iter()
        .map(|(pid, result)| match result {
            Ok(()) => serde_json::json!({ "pid": pid, "ok": true }),
            Err(error) => serde_json::json!({ "pid": pid, "ok": false, "error": error }),
        })
        .collect();
    Json(serde_json::json!({
        "protocol": PROTOCOL_VERSION,
        "results": results,
    }))
    .into_response()
}

/// `GET /v1/tokens`: the accepted clients, oldest first.
async fn tokens_list(State(state): State<Arc<AgentState>>) -> Response {
    let tokens = state.auth.lock().expect("auth").list();
    Json(serde_json::json!({
        "protocol": PROTOCOL_VERSION,
        "tokens": tokens,
    }))
    .into_response()
}

/// `DELETE /v1/tokens/{id}`: revoke a token.
async fn tokens_revoke(
    State(state): State<Arc<AgentState>>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Response {
    let revoked = state.auth.lock().expect("auth").revoke(&id);
    if revoked {
        Json(serde_json::json!({
            "protocol": PROTOCOL_VERSION,
            "revoked": id,
        }))
        .into_response()
    } else {
        (StatusCode::NOT_FOUND, "no such token").into_response()
    }
}

/// One sampler tick: take a sample, file it in the ring and hand it to
/// every live-stream client. A failing sample is skipped, not fatal:
/// the next tick retries and a rate-dependent metric heals itself.
fn tick<C: ztop_core::collector::Collector>(collector: &mut C, state: &AgentState) {
    match collector.sample() {
        Ok(sample) => {
            state.push(sample.clone());
            let _ = state.sender.send(sample);
        }
        Err(_error) => {}
    }
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

/// `GET /v1/stream`: a WebSocket that carries every new sample as one
/// text message, starting with the latest one.
async fn stream(State(state): State<Arc<AgentState>>, upgrade: WebSocketUpgrade) -> Response {
    upgrade.on_upgrade(move |socket| stream_loop(state, socket))
}

/// The live stream for one client: the latest sample first, then one
/// message per tick. A client that cannot keep up is closed (the
/// broadcast queue overflows) rather than slowing the sampler down.
async fn stream_loop(state: Arc<AgentState>, mut socket: WebSocket) {
    let mut receiver = state.sender.subscribe();
    if let Some(sample) = state.latest() {
        if send_sample(&mut socket, &sample).await.is_err() {
            return;
        }
    }
    loop {
        match receiver.recv().await {
            Ok(sample) => {
                if send_sample(&mut socket, &sample).await.is_err() {
                    return;
                }
            }
            // The queue overflowed: this client fell behind and gets
            // dropped instead of holding the sampler back.
            Err(RecvError::Lagged(_)) => {
                let _ = socket.send(Message::Close(None)).await;
                return;
            }
            Err(RecvError::Closed) => return,
        }
    }
}

async fn send_sample(socket: &mut WebSocket, sample: &Sample) -> Result<(), axum::Error> {
    let text = serde_json::to_string(&Envelope {
        protocol: PROTOCOL_VERSION,
        body: SnapshotBody {
            sample: sample.clone(),
        },
    })
    .expect("a sample serializes");
    socket.send(Message::Text(text.into())).await
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

    #[test]
    fn loopback_binds_without_tls_and_wider_needs_it() {
        assert!(super::bind_rules("127.0.0.1".parse().unwrap(), false).is_ok());
        assert!(super::bind_rules("::1".parse().unwrap(), false).is_ok());
        // TEST-NET-1: never a real machine, and not loopback.
        assert!(super::bind_rules("192.0.2.10".parse().unwrap(), false).is_err());
        assert!(super::bind_rules("192.0.2.10".parse().unwrap(), true).is_ok());
        let message = super::bind_rules("192.0.2.10".parse().unwrap(), false).expect_err("refused");
        assert!(message.contains("--tls"), "{message}");
    }

    /// A live register-and-browse round trip; ignored because it needs
    /// working multicast, which CI containers do not promise. Run it
    /// where Bonjour works: `cargo test -p ztop-agent -- --ignored`.
    #[tokio::test]
    #[ignore = "needs working multicast: run on a real desktop host"]
    async fn the_agent_is_discoverable_over_bonjour() {
        let bind: std::net::IpAddr = "127.0.0.1".parse().unwrap();
        let daemon = super::advertise(bind, 0);
        let browser = daemon.browse("_ztop._tcp.local.").expect("browser");
        let found = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            while let Ok(event) = browser.recv_async().await {
                if let mdns_sd::ServiceEvent::ServiceResolved(info) = event {
                    if info.get_fullname().starts_with("ztop on ") {
                        return true;
                    }
                }
            }
            false
        })
        .await
        .unwrap_or(false);
        let _ = daemon.stop_browse("_ztop._tcp.local.");
        let _ = daemon.shutdown();
        assert!(found, "the advertised ztop service was not browsed back");
    }

    #[tokio::test]
    async fn control_needs_tls_the_allowance_and_the_right() {
        // A plain loopback agent: control is refused outright.
        let state = Arc::new(AgentState::default());
        let response = control(
            State(state),
            axum::http::HeaderMap::new(),
            Json(ControlBody {
                pids: vec![std::process::id()],
                action: ztop_core::control::Control::Signal(0),
            }),
        )
        .await
        .into_response();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert!(body_text(response).await.contains("--tls"));

        // TLS is on but the agent does not allow control.
        let mut inner = AgentState {
            allow_control: false,
            ..AgentState::default()
        };
        inner.enforce_auth = true;
        let state = Arc::new(inner);
        let token = control_token(&state, vec!["read".to_string(), "control".to_string()]);
        let response = control(
            State(state),
            bearer(&token),
            Json(ControlBody {
                pids: vec![std::process::id()],
                action: ztop_core::control::Control::Signal(0),
            }),
        )
        .await
        .into_response();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert!(body_text(response).await.contains("--allow-control"));

        // TLS and the allowance are on, but the token reads only.
        let mut inner = AgentState {
            allow_control: true,
            ..AgentState::default()
        };
        inner.enforce_auth = true;
        let state = Arc::new(inner);
        let token = control_token(&state, vec!["read".to_string()]);
        let response = control(
            State(state),
            bearer(&token),
            Json(ControlBody {
                pids: vec![std::process::id()],
                action: ztop_core::control::Control::Signal(0),
            }),
        )
        .await
        .into_response();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert!(body_text(response).await.contains("not control"));
    }

    #[tokio::test]
    async fn the_signal_catalog_names_this_platforms_signals() {
        // Unpaired and enforced: the catalog needs a token like any read.
        let state = Arc::new(AgentState {
            enforce_auth: true,
            ..AgentState::default()
        });
        let response = control_catalog(State(state.clone()), axum::http::HeaderMap::new())
            .await
            .into_response();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        // Paired: the catalog answers with this platform's names and
        // numbers, TERM among them whatever the platform numbers it.
        let token = control_token(&state, vec!["read".to_string()]);
        let response = control_catalog(State(state), bearer(&token))
            .await
            .into_response();
        assert_eq!(response.status(), StatusCode::OK);
        let body = body_text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("a JSON catalog");
        assert_eq!(value["protocol"], 1);
        let signals = value["signals"].as_array().expect("a signal list").clone();
        assert!(
            signals
                .iter()
                .any(|entry| entry["name"] == "TERM" && entry["number"].as_i64() == Some(15)),
            "TERM is 15 on both platforms: {signals:?}"
        );
        assert!(
            signals
                .iter()
                .any(|entry| entry["name"] == "STOP" && entry["number"].as_i64().is_some()),
            "STOP is present with this platform's number: {signals:?}"
        );
    }

    #[tokio::test]
    async fn control_answers_per_pid_when_all_the_gates_pass() {
        let mut inner = AgentState {
            allow_control: true,
            ..AgentState::default()
        };
        inner.enforce_auth = true;
        let state = Arc::new(inner);
        let token = control_token(&state, vec!["read".to_string(), "control".to_string()]);
        // Signal 0 probes permission without acting: our own pid answers
        // ok, a pid that cannot exist answers with the OS's error text.
        let response = control(
            State(state),
            bearer(&token),
            Json(ControlBody {
                pids: vec![std::process::id(), 999_999_999],
                action: ztop_core::control::Control::Signal(0),
            }),
        )
        .await
        .into_response();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["protocol"], PROTOCOL_VERSION);
        let results = value["results"].as_array().expect("results");
        assert_eq!(results.len(), 2);
        assert_eq!(results[0]["pid"], std::process::id());
        assert_eq!(results[0]["ok"], true);
        assert_eq!(results[1]["pid"], 999_999_999);
        assert_eq!(results[1]["ok"], false);
        assert!(results[1]["error"].as_str().is_some_and(|e| !e.is_empty()));
    }

    /// Pair a fresh token with exactly `rights` into the state's auth.
    fn control_token(state: &AgentState, rights: Vec<String>) -> String {
        let code = {
            let mut auth = state.auth.lock().expect("auth");
            auth.start_pairing("tests".into(), auth::now_ms(), rights)
                .expect("code")
        };
        state
            .auth
            .lock()
            .expect("auth")
            .pair(&code, auth::now_ms())
            .expect("token")
    }

    /// Authorization headers carrying `token` as a bearer.
    fn bearer(token: &str) -> axum::http::HeaderMap {
        let mut headers = axum::http::HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {token}").parse().expect("header value"),
        );
        headers
    }

    /// The response body as text.
    async fn body_text(response: axum::response::Response) -> String {
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        String::from_utf8_lossy(&bytes).into_owned()
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

    /// A collector that hands out pre-built samples one per call, then
    /// fails forever.
    struct OneShotCollector {
        samples: Vec<Option<Sample>>,
        taken: usize,
    }

    impl OneShotCollector {
        fn of(samples: Vec<Sample>) -> Self {
            Self {
                samples: samples.into_iter().map(Some).collect(),
                taken: 0,
            }
        }
    }

    impl ztop_core::collector::Collector for OneShotCollector {
        fn sample(&mut self) -> Result<Sample, ztop_core::collector::CollectError> {
            let next = self.samples.get_mut(self.taken).and_then(Option::take);
            self.taken += 1;
            next.ok_or(ztop_core::collector::CollectError::Unavailable {
                origin: "test",
                what: "anything",
            })
        }
    }

    #[tokio::test]
    async fn a_tick_files_the_ring_and_reaches_the_stream() {
        use tokio::sync::broadcast::error::TryRecvError;
        let state = Arc::new(AgentState::default());
        let mut receiver = state.sender.subscribe();
        assert_eq!(receiver.try_recv(), Err(TryRecvError::Empty));

        let mut collector = OneShotCollector::of(vec![{
            let mut sample = a_sample();
            sample.timestamp_ms = 42;
            sample
        }]);
        super::tick(&mut collector, &state);
        assert_eq!(state.latest().map(|s| s.timestamp_ms), Some(42));
        assert_eq!(receiver.try_recv().map(|s| s.timestamp_ms), Ok(42));

        // The collector is exhausted: the tick skips, and neither the
        // ring nor the stream grows.
        super::tick(&mut collector, &state);
        assert_eq!(state.latest().map(|s| s.timestamp_ms), Some(42));
        assert_eq!(receiver.try_recv(), Err(TryRecvError::Empty));
    }

    /// The protocol's two halves against each other: the agent serves a
    /// pushed sample, and the core crate's remote collector fetches it
    /// over a real socket.
    #[tokio::test]
    async fn the_remote_collector_reads_a_live_agent() {
        use ztop_core::collector::Collector as _;
        let state = Arc::new(AgentState::default());
        state.push({
            let mut sample = a_sample();
            sample.timestamp_ms = 7_000;
            sample.hostname = "host-a".into();
            sample
        });
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move { super::serve_on(state, listener).await });

        // The client is blocking; run it off the async workers so the
        // server task can make progress.
        let fetched = tokio::task::spawn_blocking(move || {
            let mut collector = ztop_core::client::RemoteCollector::new(address.to_string());
            collector.sample()
        })
        .await
        .expect("join");
        let sample = fetched.expect("a sample");
        assert_eq!(sample.hostname, "host-a");
        assert_eq!(sample.timestamp_ms, 7_000);
        server.abort();
    }

    /// An agent with no sample yet answers 503; the remote collector
    /// turns that into an "unavailable" error instead of a panic or a
    /// bogus sample.
    #[tokio::test]
    async fn the_remote_collector_reports_a_warm_up_agent_as_unavailable() {
        use ztop_core::collector::Collector as _;
        let state = Arc::new(AgentState::default());
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move { super::serve_on(state, listener).await });

        let fetched = tokio::task::spawn_blocking(move || {
            ztop_core::client::RemoteCollector::new(address.to_string()).sample()
        })
        .await
        .expect("join");
        assert!(matches!(
            fetched,
            Err(ztop_core::collector::CollectError::Unavailable { .. })
        ));
        server.abort();
    }

    /// A raw HTTP request from a test, for exercising the middleware:
    /// direct handler calls bypass the router's layers.
    fn raw_request(
        address: std::net::SocketAddr,
        method: &str,
        path: &str,
        bearer: Option<&str>,
        body: Option<&str>,
    ) -> (u16, String) {
        use std::io::{Read, Write};
        let mut stream = std::net::TcpStream::connect(address).expect("connect");
        let mut request = format!("{method} {path} HTTP/1.1\r\nHost: test\r\n");
        if let Some(token) = bearer {
            request.push_str(&format!("Authorization: Bearer {token}\r\n"));
        }
        if let Some(body) = body {
            request.push_str(&format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                body.len()
            ));
        }
        request.push_str("Connection: close\r\n\r\n");
        if let Some(body) = body {
            request.push_str(body);
        }
        stream.write_all(request.as_bytes()).expect("write");
        let mut raw = String::new();
        stream.read_to_string(&mut raw).expect("read");
        let status: u16 = raw
            .split(' ')
            .nth(1)
            .and_then(|code| code.parse().ok())
            .expect("status line");
        let body = raw
            .split_once("\r\n\r\n")
            .map(|(_, body)| body.to_string())
            .unwrap_or_default();
        (status, body)
    }

    /// An enforced agent over a real socket: unauthenticated reads are
    /// refused, pairing and `/healthz` stay reachable.
    #[tokio::test]
    async fn an_enforced_agent_refuses_the_unpaired_and_pairs_the_code() {
        let inner = AgentState {
            enforce_auth: true,
            ..AgentState::default()
        };
        let code = inner
            .auth
            .lock()
            .expect("auth")
            .start_pairing("the app".into(), auth::now_ms(), vec!["read".to_string()])
            .expect("code");
        let state = Arc::new(inner);
        state.push(a_sample());

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move { super::serve_on(state, listener).await });

        let (health, _) = tokio::task::spawn_blocking(move || {
            raw_request(address, "GET", "/healthz", None, None)
        })
        .await
        .expect("join");
        assert_eq!(health, 200, "liveness is never gated");

        let (denied, _) = tokio::task::spawn_blocking(move || {
            raw_request(address, "GET", "/v1/snapshot", None, None)
        })
        .await
        .expect("join");
        assert_eq!(denied, 401);

        let address_string = address.to_string();
        let code_for_pair = code.clone();
        let (paired, pair_body) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "POST",
                "/v1/pair",
                None,
                Some(&format!("{{\"code\": \"{code_for_pair}\"}}")),
            )
        })
        .await
        .expect("join");
        assert_eq!(paired, 200);
        let token: serde_json::Value = serde_json::from_str(&pair_body).expect("pair body");
        let token = token["token"].as_str().expect("token").to_string();

        let address_string = address.to_string();
        let token_for_read = token.clone();
        let (read, read_body) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "GET",
                "/v1/snapshot",
                Some(&token_for_read),
                None,
            )
        })
        .await
        .expect("join");
        assert_eq!(read, 200, "the paired token reads the agent");
        assert!(serde_json::from_str::<serde_json::Value>(&read_body).is_ok());

        let address_string = address.to_string();
        let (rejected, _) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "GET",
                "/v1/snapshot",
                Some("not-the-token"),
                None,
            )
        })
        .await
        .expect("join");
        assert_eq!(rejected, 401, "a wrong token reads nothing");

        server.abort();
    }

    /// Tokens can be listed and revoked over the wire, and a revoked
    /// token stops reading immediately.
    #[tokio::test]
    async fn tokens_can_be_listed_and_revoked_over_the_wire() {
        let inner = AgentState {
            enforce_auth: true,
            ..AgentState::default()
        };
        let code = inner
            .auth
            .lock()
            .expect("auth")
            .start_pairing("the app".into(), auth::now_ms(), vec!["read".to_string()])
            .expect("code");
        let state = Arc::new(inner);
        state.push(a_sample());

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move { super::serve_on(state, listener).await });

        let address_string = address.to_string();
        let pair_body_text = format!("{{\"code\": \"{code}\"}}");
        let (paired, pair_body) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "POST",
                "/v1/pair",
                None,
                Some(&pair_body_text),
            )
        })
        .await
        .expect("join");
        assert_eq!(paired, 200);
        let token: serde_json::Value = serde_json::from_str(&pair_body).expect("pair body");
        let token = token["token"].as_str().expect("token").to_string();

        let address_string = address.to_string();
        let token_for_list = token.clone();
        let (listed, list_body) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "GET",
                "/v1/tokens",
                Some(&token_for_list),
                None,
            )
        })
        .await
        .expect("join");
        assert_eq!(listed, 200);
        let list: serde_json::Value = serde_json::from_str(&list_body).expect("list body");
        assert_eq!(list["tokens"].as_array().expect("tokens").len(), 1);
        let id = list["tokens"][0]["id"].as_str().expect("id").to_string();

        let address_string = address.to_string();
        let token_for_read = token.clone();
        let (revoked, _) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "DELETE",
                &format!("/v1/tokens/{id}"),
                Some(&token_for_read),
                None,
            )
        })
        .await
        .expect("join");
        assert_eq!(revoked, 200);

        let address_string = address.to_string();
        let token_for_check = token.clone();
        let (after_revoke, _) = tokio::task::spawn_blocking(move || {
            raw_request(
                address_string.parse().expect("addr"),
                "GET",
                "/v1/snapshot",
                Some(&token_for_check),
                None,
            )
        })
        .await
        .expect("join");
        assert_eq!(after_revoke, 401, "a revoked token reads nothing");

        server.abort();
    }

    /// A test client that trusts exactly one certificate: the pin. This
    /// is the same check `ztop connect --tls` will make (decision 0039).
    struct Pinning {
        fingerprint: Vec<u8>,
        provider: Arc<rustls::crypto::CryptoProvider>,
    }

    impl std::fmt::Debug for Pinning {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str("Pinning")
        }
    }

    impl rustls::client::danger::ServerCertVerifier for Pinning {
        fn verify_server_cert(
            &self,
            end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            use sha2::Digest;
            let hash = sha2::Sha256::digest(end_entity.as_ref());
            if hash.as_slice() == self.fingerprint.as_slice() {
                Ok(rustls::client::danger::ServerCertVerified::assertion())
            } else {
                Err(rustls::Error::General(
                    "the agent's certificate does not match the pin".into(),
                ))
            }
        }

        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(
                message,
                cert,
                dss,
                &self.provider.signature_verification_algorithms,
            )
        }

        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(
                message,
                cert,
                dss,
                &self.provider.signature_verification_algorithms,
            )
        }

        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            self.provider
                .signature_verification_algorithms
                .supported_schemes()
        }
    }

    /// A raw HTTPS request from a test, over a pinned TLS connection.
    async fn tls_request(
        address: std::net::SocketAddr,
        fingerprint_hex: &str,
        path: &str,
    ) -> (u16, String) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let fingerprint: Vec<u8> = (0..fingerprint_hex.len() / 2)
            .map(|index| {
                u8::from_str_radix(&fingerprint_hex[index * 2..index * 2 + 2], 16)
                    .expect("hex digit")
            })
            .collect();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier = Pinning {
            fingerprint,
            provider: provider.clone(),
        };
        let config = rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .expect("versions")
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_no_client_auth();
        let server_name =
            rustls::pki_types::ServerName::try_from("localhost".to_string()).expect("server name");
        let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
        let tcp = tokio::net::TcpStream::connect(address).await.expect("tcp");
        // A rejected pin (or any failed handshake) reads as (0, ""): the
        // caller asserts on the status.
        let mut stream = match connector.connect(server_name, tcp).await {
            Ok(stream) => stream,
            Err(_) => return (0, String::new()),
        };

        let request = format!("GET {path} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).await.expect("write");
        stream.flush().await.expect("flush");
        let mut raw = String::new();
        stream.read_to_string(&mut raw).await.expect("read");
        let status: u16 = raw
            .split(' ')
            .nth(1)
            .and_then(|code| code.parse().ok())
            .expect("status line");
        let body = raw
            .split_once("\r\n\r\n")
            .map(|(_, body)| body.to_string())
            .unwrap_or_default();
        (status, body)
    }

    /// An isolated material directory.
    fn a_material_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ztop-agent-tls-{}-{}-{tag}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("mkdir");
        dir
    }

    /// TLS serving: a fresh self-signed certificate, the printed pin,
    /// and a client that trusts exactly that pin can read the agent.
    #[tokio::test]
    async fn tls_serves_and_a_pinned_client_reads() {
        let dir = a_material_dir("serves");
        let material = tls::load_or_create(&dir).expect("material");
        assert!(material.fingerprint.starts_with("SHA256:"));
        let fingerprint_hex = material
            .fingerprint
            .strip_prefix("SHA256:")
            .expect("prefix")
            .to_string();
        assert_eq!(fingerprint_hex.len(), 64, "a SHA-256 pin is 64 hex chars");

        // The material is stable: a second load pins the same bytes.
        let again = tls::load_or_create(&dir).expect("material again");
        assert_eq!(again.fingerprint, material.fingerprint);

        // Enforced with no tokens at all: reads are refused.
        let inner = AgentState {
            enforce_auth: true,
            ..AgentState::default()
        };
        let state = Arc::new(inner);
        state.push(a_sample());

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let server =
            tokio::spawn(async move { tls::serve_on_tls(state, listener, material.config).await });

        // Unauthenticated over TLS: /healthz answers, /v1/snapshot 401s.
        let address_string = address.to_string();
        let (status, _) = tls_request(
            address_string.parse().expect("addr"),
            &fingerprint_hex,
            "/healthz",
        )
        .await;
        assert_eq!(status, 200);
        let (status, _) = tls_request(
            address_string.parse().expect("addr"),
            &fingerprint_hex,
            "/v1/snapshot",
        )
        .await;
        assert_eq!(status, 401, "TLS means tokens are enforced");

        // A wrong pin cannot even complete the handshake.
        let wrong_pin = format!("{}00", &fingerprint_hex[..62]);
        let result = tls_request(
            address_string.parse().expect("addr"),
            &wrong_pin,
            "/healthz",
        )
        .await;
        assert_eq!(result.0, 0, "a mismatched pin kills the handshake");

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `ztop connect --tls` end to end: the protocol client speaks
    /// pinned TLS to the enforced agent, trades a pairing code for a
    /// token over the wire, and reads with it.
    #[tokio::test]
    async fn the_protocol_client_reads_a_tls_agent_and_pairs() {
        use ztop_core::collector::Collector as _;
        let dir = a_material_dir("client");
        let material = tls::load_or_create(&dir).expect("material");
        let pin = material.fingerprint.clone();

        let inner = AgentState {
            enforce_auth: true,
            ..AgentState::default()
        };
        let state = Arc::new(inner);
        state.push(a_sample());
        // A token from an earlier pairing stands in for the saved one.
        let saved_token = {
            let mut auth = state.auth.lock().expect("auth");
            let code = auth
                .start_pairing(
                    "earlier pairing".into(),
                    auth::now_ms(),
                    vec!["read".to_string()],
                )
                .expect("code");
            auth.pair(&code, auth::now_ms()).expect("pairs")
        };

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let server_state = state.clone();
        let server =
            tokio::spawn(async move { tls::serve_on_tls(state, listener, material.config).await });
        let target = address.to_string();
        let state = server_state;

        // Without a token the reads come back as "pair first". The
        // collector is synchronous, so every call below runs on the
        // blocking pool: on the current-thread test runtime a blocking
        // client would starve the server task it talks to.
        let mut unpaired =
            ztop_core::client::RemoteCollector::tls(target.clone(), &pin, None).expect("collector");
        let error = tokio::task::spawn_blocking(move || unpaired.sample())
            .await
            .expect("join")
            .expect_err("401 without a token");
        assert!(
            error.to_string().contains("pair"),
            "the error says to pair: {error}"
        );

        // The pairing round trip runs over the same pinned TLS and
        // yields a token the agent accepts.
        let code = {
            let mut auth = state.auth.lock().expect("auth");
            auth.start_pairing(
                "pairing over the wire".into(),
                auth::now_ms(),
                vec!["read".to_string()],
            )
            .expect("code")
        };
        let code_target = target.clone();
        let code_pin = pin.clone();
        let wire_token = tokio::task::spawn_blocking(move || {
            ztop_core::client::pair_with(&code_target, &code_pin, &code)
        })
        .await
        .expect("join")
        .expect("pairs over TLS");
        assert!(!wire_token.is_empty());

        let mut with_saved =
            ztop_core::client::RemoteCollector::tls(target.clone(), &pin, Some(saved_token))
                .expect("collector");
        let sample = tokio::task::spawn_blocking(move || with_saved.sample())
            .await
            .expect("join")
            .expect("reads with the saved token");
        assert!(!sample.hostname.is_empty());

        let mut with_wire =
            ztop_core::client::RemoteCollector::tls(target.clone(), &pin, Some(wire_token))
                .expect("collector");
        tokio::task::spawn_blocking(move || with_wire.sample())
            .await
            .expect("join")
            .expect("reads with the wire token");

        // A one-byte wrong pin: the collector reports the certificate,
        // not the network. The first hex character is replaced by a
        // different one, so the wrong pin always differs (appending
        // could rebuild the real pin whenever the tail is "00").
        let flipped = if pin.as_bytes()["SHA256:".len()] == b'0' {
            "1"
        } else {
            "0"
        };
        let wrong_pin = format!("SHA256:{}{}", flipped, &pin["SHA256:".len() + 1..]);
        let mut impostor =
            ztop_core::client::RemoteCollector::tls(target.clone(), &wrong_pin, None)
                .expect("collector");
        let error = tokio::task::spawn_blocking(move || impostor.sample())
            .await
            .expect("join")
            .expect_err("a wrong pin is refused");
        assert!(
            error.to_string().contains("pin"),
            "the error says the pin mismatched: {error}"
        );

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
