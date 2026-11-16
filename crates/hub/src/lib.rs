// SPDX-License-Identifier: MIT OR Apache-2.0
//! The zTop hub: polls many agents and serves their history as one.
//!
//! A hub is a client of its agents and a server to its own clients
//! (decision 0003): it polls each configured agent on the agent's own
//! cadence, files every sample in SQLite (decision 0004) and serves
//! the agent protocol with one addition, a `host` selector, so a
//! client talks to the hub exactly as it talks to an agent and picks
//! the machine with `?host=`. `/v1/hosts` lists what the hub watches
//! and how fresh each one is; everything else keeps the agent's
//! shapes and status codes. Pairing and tokens are the hub's own
//! (a client pairs with the hub, not with every agent behind it);
//! the auth and TLS layers are the agent's, reused verbatim.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Query, State};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use ztop_agent::auth;
use ztop_core::collector::Collector;
use ztop_core::model::Sample;

/// How often the hub asks each agent for a sample. The agents sample
/// at the same cadence, so this keeps the hub's history one poll
/// behind the agents' rings at most.
pub const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// A sample fresher than this is `live`; past it the host is marked
/// unreachable in `/v1/hosts`. Same window the app's overview uses.
const FRESH_MS: u128 = 10_000;

/// Rows older than this are pruned: a day of 2-second samples per
/// agent is ~43k rows, comfortably small for SQLite.
const RETENTION_MS: u128 = 24 * 60 * 60 * 1000;

/// How often the retention prune runs.
const PRUNE_INTERVAL: Duration = Duration::from_secs(10 * 60);

/// One watched agent, as the hub's config file names it:
/// `"target"` is `host:port`; `"pin"` (present = TLS, matching what
/// the agent printed) and `"token"` are optional for loopback agents
/// that serve plain HTTP unauthenticated.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct AgentConfig {
    pub name: String,
    pub target: String,
    #[serde(default)]
    pub pin: Option<String>,
    #[serde(default)]
    pub token: Option<String>,
}

/// The hub's agent list, loaded from a JSON file:
/// `{ "agents": [ ... ] }`.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct HubConfig {
    pub agents: Vec<AgentConfig>,
}

impl HubConfig {
    /// Load and validate the config: names must be unique, every
    /// agent needs a target, and a pin must look like the agent's
    /// fingerprint (`SHA256:<64 hex>`).
    pub fn load(path: &Path) -> std::io::Result<HubConfig> {
        let text = std::fs::read_to_string(path)?;
        let config: HubConfig = serde_json::from_str(&text).map_err(|error| {
            std::io::Error::other(format!("{} is not a hub config: {error}", path.display()))
        })?;
        config.validate().map_err(std::io::Error::other)?;
        Ok(config)
    }

    /// Validate an already-parsed config; exposed for tests.
    pub fn validate(&self) -> Result<(), String> {
        let mut seen = std::collections::HashSet::new();
        for agent in &self.agents {
            if agent.name.is_empty() {
                return Err("an agent needs a name".into());
            }
            if agent.target.is_empty() {
                return Err(format!("agent {} needs a target", agent.name));
            }
            if !seen.insert(agent.name.as_str()) {
                return Err(format!("agent {} is listed twice", agent.name));
            }
            if let Some(pin) = &agent.pin {
                if ztop_core::client::RemoteCollector::tls(agent.target.clone(), pin, None).is_err()
                {
                    return Err(format!(
                        "agent {}: pin must look like what the agent prints: SHA256:<64 hex>",
                        agent.name
                    ));
                }
            }
        }
        Ok(())
    }
}

/// The SQLite history: the samples the hub polled, by host.
pub struct Store {
    pool: sqlx::SqlitePool,
}

impl Store {
    /// Open (creating if needed) the history file and run the
    /// embedded migrations. WAL keeps a poll and a reader from
    /// blocking each other.
    pub async fn open(path: &Path) -> Result<Store, sqlx::Error> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let options = sqlx::sqlite::SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(4)
            .connect_with(options)
            .await?;
        sqlx::migrate!().run(&pool).await?;
        Ok(Store { pool })
    }

    /// An in-memory store, for tests. One connection only: separate
    /// pooled connections each open their own empty in-memory
    /// database, which would hide the migrated schema from them.
    pub async fn in_memory() -> Result<Store, sqlx::Error> {
        let options = sqlx::sqlite::SqliteConnectOptions::new()
            .in_memory(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::migrate!().run(&pool).await?;
        Ok(Store { pool })
    }

    /// File one sample under `host`.
    pub async fn insert(&self, host: &str, ts_ms: u64, payload: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO samples (host, ts_ms, payload) VALUES (?, ?, ?)")
            .bind(host)
            .bind(ts_ms as i64)
            .bind(payload)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// The newest sample for `host`, or `None` before the first poll.
    pub async fn latest(&self, host: &str) -> Result<Option<Sample>, sqlx::Error> {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT payload FROM samples WHERE host = ? ORDER BY ts_ms DESC LIMIT 1",
        )
        .bind(host)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.and_then(|row| serde_json::from_str(&row.0).ok()))
    }

    /// Samples for `host` from the last `seconds` seconds, oldest
    /// first, the same shape the agent's history serves.
    pub async fn since(&self, host: &str, seconds: u64) -> Result<Vec<Sample>, sqlx::Error> {
        let from = now_ms().saturating_sub(seconds.saturating_mul(1000)) as i64;
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT payload FROM samples WHERE host = ? AND ts_ms >= ? ORDER BY ts_ms ASC",
        )
        .bind(host)
        .bind(from)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| serde_json::from_str(&row.0).ok())
            .collect())
    }

    /// Delete rows older than `older_than_ms` milliseconds; the
    /// retention task's worker. The age is relative to now.
    pub async fn prune(&self, older_than_ms: u64) -> Result<(), sqlx::Error> {
        let cutoff = (now_ms() as i64) - (older_than_ms as i64);
        sqlx::query("DELETE FROM samples WHERE ts_ms < ?")
            .bind(cutoff)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

/// Milliseconds since the Unix epoch; the timestamp every sample and
/// status carries.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// One agent's polling state as `/v1/hosts` reports it.
#[derive(Debug, Clone, Default)]
pub struct AgentStatus {
    pub last_ok_ms: Option<u64>,
    pub last_error: Option<String>,
}

/// The hub's shared state: config, history, its own auth and the
/// per-agent polling statuses.
pub struct HubState {
    pub config: HubConfig,
    pub store: Store,
    pub auth: Mutex<auth::Auth>,
    /// TLS serving flips this on, exactly as the agent does.
    pub enforce_auth: bool,
    pub statuses: Mutex<HashMap<String, AgentStatus>>,
}

impl HubState {
    /// Build a hub over an open store; the caller chooses the auth
    /// (memory for tests, the state dir for a real serve).
    pub fn new(
        config: HubConfig,
        store: Store,
        auth: auth::Auth,
        enforce_auth: bool,
    ) -> Arc<HubState> {
        let statuses = config
            .agents
            .iter()
            .map(|agent| (agent.name.clone(), AgentStatus::default()))
            .collect();
        Arc::new(HubState {
            config,
            store,
            auth: Mutex::new(auth),
            enforce_auth,
            statuses: Mutex::new(statuses),
        })
    }

    /// Poll every agent once: one sample each, statuses and history
    /// updated. A failing agent is marked unreachable and skipped,
    /// never fatal: the hub outlives any one agent.
    pub async fn poll_once(&self) {
        for agent in &self.config.agents {
            let result = poll_agent(agent).await;
            self.record(agent, result).await;
        }
    }

    /// File one poll's outcome: a sample goes to the store and marks
    /// the agent live, a failure marks it unreachable with the
    /// reason. The one seam both the tests and the pollers use. The
    /// status lock is taken after the await, never across it.
    async fn record(&self, agent: &AgentConfig, result: Result<Sample, String>) {
        match result {
            Ok(sample) => {
                if let Ok(payload) = serde_json::to_string(&sample) {
                    let _ = self
                        .store
                        .insert(&agent.name, sample.timestamp_ms, &payload)
                        .await;
                }
                let mut statuses = self.statuses.lock().expect("statuses");
                let status = statuses.entry(agent.name.clone()).or_default();
                status.last_ok_ms = Some(now_ms());
                status.last_error = None;
            }
            Err(error) => {
                let mut statuses = self.statuses.lock().expect("statuses");
                let status = statuses.entry(agent.name.clone()).or_default();
                status.last_error = Some(error);
            }
        }
    }

    /// The state string for `name` in `/v1/hosts`.
    fn state_of(&self, name: &str) -> &'static str {
        let statuses = self.statuses.lock().expect("statuses");
        match statuses.get(name).and_then(|status| status.last_ok_ms) {
            Some(ms) if (now_ms() as i128 - ms as i128).unsigned_abs() < FRESH_MS => "live",
            Some(_) => "unreachable",
            None => "pending",
        }
    }
}

/// One poll of one agent: a synchronous pinned client run on the
/// blocking pool (decision 0040's seam). Any failure — TLS, HTTP,
/// protocol — comes back as the reason the agent is unreachable.
async fn poll_agent(agent: &AgentConfig) -> Result<Sample, String> {
    let agent = agent.clone();
    tokio::task::spawn_blocking(move || {
        let mut collector = match &agent.pin {
            Some(pin) => ztop_core::client::RemoteCollector::tls(
                agent.target.clone(),
                pin,
                agent.token.clone(),
            )
            .map_err(|error| error.to_string())?,
            None => ztop_core::client::RemoteCollector::new(agent.target.clone()),
        };
        collector.sample().map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| format!("the poll task failed: {error}"))?
}

/// The versioned envelope every `/v1` payload travels in; the same
/// shape the agent serves.
#[derive(Debug, serde::Serialize)]
struct Envelope<T> {
    protocol: u32,
    #[serde(flatten)]
    body: T,
}

/// The `host` and `seconds` query parameters the hub's read routes
/// take. `host` is the config's name for the agent, not necessarily
/// the sample's hostname.
#[derive(Debug, Deserialize)]
struct HostQuery {
    host: Option<String>,
    seconds: Option<u64>,
}

/// Build the hub's HTTP router over `state`.
pub fn router(state: Arc<HubState>) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/pair", post(pair))
        .route("/v1/hosts", get(hosts))
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/history", get(history))
        .route("/v1/tokens", get(tokens_list))
        .route("/v1/tokens/{id}", delete(tokens_revoke))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            enforce_auth,
        ))
        .with_state(state)
}

/// The auth gate: when the hub is enforced (`enforce_auth`), every
/// `/v1` route except `/healthz` and `/v1/pair` needs a bearer token
/// the hub's auth knows. Plain loopback serving runs unauthenticated,
/// exactly as the agent does.
async fn enforce_auth(
    State(state): State<Arc<HubState>>,
    request: axum::http::Request<axum::body::Body>,
    next: axum::middleware::Next,
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
            axum::http::StatusCode::UNAUTHORIZED,
            "pair first: POST /v1/pair with the hub's pairing code",
        )
            .into_response()
    }
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({
        "service": "ztop-hub",
        "protocol": ztop_core::client::PROTOCOL_VERSION,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

/// The body of `POST /v1/pair`: the hub's shown code.
#[derive(Debug, Deserialize)]
struct PairBody {
    code: String,
}

/// `POST /v1/pair`: trade the hub's pairing code for a hub token.
/// The response is the agent's shape; the token only opens the hub.
async fn pair(State(state): State<Arc<HubState>>, Json(body): Json<PairBody>) -> Response {
    let mut auth = state.auth.lock().expect("auth");
    match auth.pair(&body.code, auth::now_ms()) {
        Ok(token) => Json(json!({
            "protocol": ztop_core::client::PROTOCOL_VERSION,
            "token": token,
        }))
        .into_response(),
        Err(auth::AuthError::BadCode) => (
            axum::http::StatusCode::FORBIDDEN,
            "the pairing code does not match, is used up or expired",
        )
            .into_response(),
        Err(error) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            format!("pairing failed: {error}"),
        )
            .into_response(),
    }
}

/// `GET /v1/hosts`: what the hub watches, unreachable hosts last.
async fn hosts(State(state): State<Arc<HubState>>) -> Response {
    let mut hosts: Vec<serde_json::Value> = state
        .config
        .agents
        .iter()
        .map(|agent| {
            let status = state
                .statuses
                .lock()
                .expect("statuses")
                .get(&agent.name)
                .cloned()
                .unwrap_or_default();
            json!({
                "name": agent.name,
                "target": agent.target,
                "state": state.state_of(&agent.name),
                "last_ms": status.last_ok_ms,
                "error": status.last_error,
            })
        })
        .collect();
    hosts.sort_by_key(|host| {
        (
            host["state"].as_str().unwrap_or_default().to_string(),
            host["name"].as_str().unwrap_or_default().to_string(),
        )
    });
    Json(json!({
        "protocol": ztop_core::client::PROTOCOL_VERSION,
        "hosts": hosts,
    }))
    .into_response()
}

/// `GET /v1/snapshot?host=name`: the agent's latest sample through
/// the hub. Unknown host is 404, known host with no poll yet is 503,
/// both with the agent's wording.
async fn snapshot(State(state): State<Arc<HubState>>, query: Query<HostQuery>) -> Response {
    // No selector means the first agent: a client that does not know
    // about fleets (the TUI's connect) gets exactly what it would
    // have gotten from one agent.
    let host = query.host.as_deref().map(str::to_owned);
    let host = match host {
        Some(host) => host,
        None => match state.config.agents.first() {
            Some(agent) => agent.name.clone(),
            None => {
                return (
                    axum::http::StatusCode::SERVICE_UNAVAILABLE,
                    "the hub watches no agents: add some to agents.json",
                )
                    .into_response();
            }
        },
    };
    if !state.config.agents.iter().any(|agent| agent.name == host) {
        return (
            axum::http::StatusCode::NOT_FOUND,
            format!("no agent named {host}: GET /v1/hosts lists them"),
        )
            .into_response();
    }
    match state.store.latest(&host).await {
        Ok(Some(sample)) => Json(Envelope {
            protocol: ztop_core::client::PROTOCOL_VERSION,
            body: json!({ "sample": sample }),
        })
        .into_response(),
        Ok(None) => (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            "no sample yet: the hub has not polled this agent",
        )
            .into_response(),
        Err(error) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            format!("history read failed: {error}"),
        )
            .into_response(),
    }
}

/// `GET /v1/history?host=name&seconds=N`: the hub's stored samples
/// for that host, oldest first.
async fn history(State(state): State<Arc<HubState>>, query: Query<HostQuery>) -> Response {
    let Some(host) = query.host.as_deref() else {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            "which host: add ?host=name (GET /v1/hosts lists them)",
        )
            .into_response();
    };
    if !state.config.agents.iter().any(|agent| agent.name == host) {
        return (
            axum::http::StatusCode::NOT_FOUND,
            format!("no agent named {host}: GET /v1/hosts lists them"),
        )
            .into_response();
    }
    let seconds = query.seconds.unwrap_or(u64::MAX);
    match state.store.since(host, seconds).await {
        Ok(samples) => Json(Envelope {
            protocol: ztop_core::client::PROTOCOL_VERSION,
            body: json!({ "seconds": seconds, "samples": samples }),
        })
        .into_response(),
        Err(error) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            format!("history read failed: {error}"),
        )
            .into_response(),
    }
}

/// `GET /v1/tokens`: the hub's accepted clients, oldest first.
async fn tokens_list(State(state): State<Arc<HubState>>) -> Response {
    let tokens = state.auth.lock().expect("auth").list();
    Json(json!({
        "protocol": ztop_core::client::PROTOCOL_VERSION,
        "tokens": tokens,
    }))
    .into_response()
}

/// `DELETE /v1/tokens/{id}`: revoke a hub token.
async fn tokens_revoke(
    State(state): State<Arc<HubState>>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Response {
    let revoked = state.auth.lock().expect("auth").revoke(&id);
    if revoked {
        Json(json!({
            "protocol": ztop_core::client::PROTOCOL_VERSION,
            "revoked": id,
        }))
        .into_response()
    } else {
        (axum::http::StatusCode::NOT_FOUND, "no such token").into_response()
    }
}

/// The hub's bind rules: loopback needs no TLS, anything wider does
/// — the same rule as the agent, the hub being the wider door.
fn bind_rules(bind: std::net::IpAddr, tls: bool) -> Result<(), String> {
    let loopback = match bind {
        std::net::IpAddr::V4(v4) => v4.is_loopback(),
        std::net::IpAddr::V6(v6) => v6.is_loopback(),
    };
    if loopback || tls {
        Ok(())
    } else {
        Err(format!(
            "binding {bind} exposes the hub beyond this machine: pass --tls"
        ))
    }
}

/// Serve the hub: load the config and history, start the pollers and
/// answer clients until the process is stopped. With `pair`, print a
/// pairing code for clients. With `tls`, serve HTTPS with the same
/// self-signed certificate scheme as the agent and enforce tokens.
pub async fn serve(
    bind: std::net::IpAddr,
    port: u16,
    agents_path: &Path,
    db_path: &Path,
    pair: bool,
    tls: bool,
) -> std::io::Result<()> {
    bind_rules(bind, tls).map_err(std::io::Error::other)?;
    let config = HubConfig::load(agents_path)?;
    let store = Store::open(db_path)
        .await
        .map_err(|error| std::io::Error::other(format!("opening the history failed: {error}")))?;
    let mut auth = match ztop_core::paths::state_dir() {
        Some(dir) => auth::Auth::at(dir.join("hub").join("tokens.json")).unwrap_or_default(),
        None => auth::Auth::in_memory(),
    };
    if pair {
        let rights = vec!["read".to_string()];
        match auth.start_pairing(
            "pairing from the command line".into(),
            auth::now_ms(),
            rights,
        ) {
            Ok(code) => println!("Pairing code: {code} (valid for 5 minutes)"),
            Err(error) => eprintln!("ztop-hub: pairing is unavailable: {error}"),
        }
    }
    let watching = config.agents.len();
    let state = HubState::new(config, store, auth, tls);
    spawn_pollers(state.clone());
    let listener = tokio::net::TcpListener::bind((bind, port)).await?;
    println!("ztop-hub: watching {watching} agent(s) on {bind}:{port}");
    if tls {
        let dir = ztop_core::paths::state_dir().ok_or_else(|| {
            std::io::Error::other("no home directory: TLS material cannot persist")
        })?;
        let material = ztop_agent::tls::load_or_create(&dir.join("hub"))?;
        println!("TLS fingerprint: {}", material.fingerprint);
        return ztop_agent::tls::serve_router_on_tls(listener, material.config, router(state))
            .await;
    }
    axum::serve(listener, router(state)).await
}

/// Start one poller per agent plus the retention prune. Each poller
/// owns its agent's config; a slow or dead agent delays only its own
/// history, never the others'.
fn spawn_pollers(state: Arc<HubState>) {
    for agent in state.config.agents.clone() {
        let state = state.clone();
        tokio::spawn(async move {
            loop {
                let result = poll_agent(&agent).await;
                state.record(&agent, result).await;
                tokio::time::sleep(POLL_INTERVAL).await;
            }
        });
    }
    let prune_state = state.clone();
    tokio::spawn(async move {
        loop {
            let cutoff = now_ms().saturating_sub(RETENTION_MS as u64);
            let _ = prune_state.store.prune(cutoff).await;
            tokio::time::sleep(PRUNE_INTERVAL).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    use ztop_core::model::{AppleSilicon, Cpu, CpuTimes, Memory, Metric, Sensors, Unit};

    /// A minimal sample the way collectors build them, with the
    /// host's name and a distinctive load stamped in.
    fn a_sample(hostname: &str, ts_ms: u64, load: f64) -> Sample {
        Sample {
            timestamp_ms: ts_ms,
            hostname: hostname.to_string(),
            system: String::new(),
            threads: Metric::unavailable(Unit::Count),
            kernel_threads: Metric::unavailable(Unit::Count),
            cpu: Cpu {
                cores: vec![CpuTimes::default()],
                busy_percent: vec![load],
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
            load_avg: [load, load, load],
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

    fn two_agents() -> HubConfig {
        serde_json::from_str(
            r#"{"agents":[
            {"name":"host-a","target":"127.0.0.1:7151"},
            {"name":"host-b","target":"127.0.0.1:7152"}
        ]}"#,
        )
        .expect("config")
    }

    async fn hub_with(config: HubConfig, enforce: bool) -> Arc<HubState> {
        let store = Store::in_memory().await.expect("store");
        HubState::new(config, store, auth::Auth::in_memory(), enforce)
    }

    /// A hub state reassembled around a fresh store, for tests that
    /// seed history by hand.
    fn reseed(state: &Arc<HubState>, store: Store) -> Arc<HubState> {
        Arc::new(HubState {
            config: state.config.clone(),
            store,
            auth: Mutex::new(auth::Auth::in_memory()),
            enforce_auth: false,
            statuses: Mutex::new(HashMap::new()),
        })
    }

    async fn get(router: Router, uri: &str) -> axum::response::Response {
        router
            .oneshot(
                Request::builder()
                    .uri(uri)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response")
    }

    async fn text(response: axum::response::Response) -> String {
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[tokio::test]
    async fn config_rejects_duplicates_bad_targets_and_bad_pins() {
        assert!(HubConfig::load(Path::new("/nonexistent/hub.json")).is_err());
        let dup: HubConfig = serde_json::from_str(
            r#"{"agents":[{"name":"x","target":"a:1"},{"name":"x","target":"b:2"}]}"#,
        )
        .expect("parses");
        assert!(dup.validate().is_err());
        let no_target: HubConfig =
            serde_json::from_str(r#"{"agents":[{"name":"x","target":""}]}"#).expect("parses");
        assert!(no_target.validate().is_err());
        let pin: HubConfig = serde_json::from_str(
            r#"{"agents":[{"name":"x","target":"a:1","pin":"SHA256:short"}]}"#,
        )
        .expect("parses");
        assert!(pin.validate().is_err());
        let good: HubConfig = serde_json::from_str(
            r#"{"agents":[{"name":"x","target":"a:1","pin":"SHA256:00aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00ee11ff22aa33bb44cc55dd"}]}"#,
        )
        .expect("parses");
        assert!(good.validate().is_ok());
    }

    #[tokio::test]
    async fn store_round_trips_and_prunes() {
        let store = Store::in_memory().await.expect("store");
        let base = now_ms();
        for (age, load) in [(3000u64, 1.0), (2000, 2.0)] {
            let sample = a_sample("host-a", base - age, load);
            store
                .insert(
                    "host-a",
                    base - age,
                    &serde_json::to_string(&sample).unwrap(),
                )
                .await
                .expect("insert");
        }
        let b = a_sample("host-b", base - 3000, 3.0);
        store
            .insert("host-b", base - 3000, &serde_json::to_string(&b).unwrap())
            .await
            .expect("insert");
        assert_eq!(
            store
                .latest("host-a")
                .await
                .expect("latest")
                .map(|s| s.timestamp_ms),
            Some(base - 2000)
        );
        assert_eq!(store.latest("ghost").await.expect("latest"), None);
        assert_eq!(store.since("host-a", 1000).await.expect("since").len(), 2);
        store.prune(2500).await.expect("prune");
        assert_eq!(
            store.since("host-a", u64::MAX).await.expect("since").len(),
            1
        );
        assert_eq!(
            store.since("host-b", u64::MAX).await.expect("since").len(),
            0
        );
    }

    #[tokio::test]
    async fn snapshot_defaults_to_the_first_agent_and_knows_the_fleet() {
        let state = hub_with(two_agents(), false).await;
        // No selector: the first agent, before any poll — the exact
        // answer one agent would have given.
        let response = get(router(state.clone()), "/v1/snapshot").await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = text(response).await;
        assert!(body.contains("no sample yet"), "{body}");
        let response = get(router(state.clone()), "/v1/snapshot?host=ghost").await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        let body = text(response).await;
        assert!(body.contains("no agent named ghost"), "{body}");
    }

    #[tokio::test]
    async fn snapshot_serves_the_polled_sample() {
        let state = hub_with(two_agents(), false).await;
        let store = Store::in_memory().await.expect("store");
        let sample = a_sample("host-a", now_ms(), 42.0);
        store
            .insert(
                "host-a",
                sample.timestamp_ms,
                &serde_json::to_string(&sample).unwrap(),
            )
            .await
            .expect("insert");
        let state = reseed(&state, store);
        let response = get(router(state), "/v1/snapshot?host=host-a").await;
        assert_eq!(response.status(), StatusCode::OK);
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        assert_eq!(value["protocol"], ztop_core::client::PROTOCOL_VERSION);
        assert_eq!(value["sample"]["hostname"], "host-a");
        assert_eq!(value["sample"]["load_avg"][0], 42.0);
    }

    #[tokio::test]
    async fn snapshot_says_no_sample_yet_before_the_first_poll() {
        let state = hub_with(two_agents(), false).await;
        let response = get(router(state), "/v1/snapshot?host=host-b").await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn history_serves_the_stored_window() {
        let state = hub_with(two_agents(), false).await;
        let base = now_ms();
        for (offset, load) in [(3000u64, 1.0), (2000, 2.0), (500, 3.0)] {
            let sample = a_sample("host-a", base - offset, load);
            state
                .store
                .insert(
                    "host-a",
                    sample.timestamp_ms,
                    &serde_json::to_string(&sample).unwrap(),
                )
                .await
                .expect("insert");
        }
        let response = get(router(state.clone()), "/v1/history?host=host-a&seconds=1").await;
        assert_eq!(response.status(), StatusCode::OK);
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        assert_eq!(value["seconds"], 1);
        assert_eq!(value["samples"].as_array().expect("samples").len(), 1);
        let response = get(router(state.clone()), "/v1/history?host=host-a").await;
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        assert_eq!(value["samples"].as_array().expect("samples").len(), 3);
    }

    #[tokio::test]
    async fn hosts_lists_the_fleet_with_states() {
        let state = hub_with(two_agents(), false).await;
        state.statuses.lock().expect("statuses").insert(
            "host-a".into(),
            AgentStatus {
                last_ok_ms: Some(now_ms()),
                last_error: None,
            },
        );
        state.statuses.lock().expect("statuses").insert(
            "host-b".into(),
            AgentStatus {
                last_ok_ms: None,
                last_error: Some("unreachable".into()),
            },
        );
        let response = get(router(state), "/v1/hosts").await;
        assert_eq!(response.status(), StatusCode::OK);
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        let hosts = value["hosts"].as_array().expect("hosts");
        assert_eq!(hosts.len(), 2);
        let a = hosts
            .iter()
            .find(|h| h["name"] == "host-a")
            .expect("host-a");
        let b = hosts
            .iter()
            .find(|h| h["name"] == "host-b")
            .expect("host-b");
        assert_eq!(a["state"], "live");
        assert_eq!(b["state"], "pending");
        assert_eq!(b["error"], "unreachable");
    }

    #[tokio::test]
    async fn enforced_hub_rejects_unpaired_reads_and_pairs() {
        let state = hub_with(two_agents(), true).await;
        let response = get(router(state.clone()), "/v1/hosts").await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let response = get(router(state.clone()), "/healthz").await;
        assert_eq!(response.status(), StatusCode::OK);
        // Pair with the hub's own code, then read with the token.
        let code = state
            .auth
            .lock()
            .expect("auth")
            .start_pairing("tests".into(), auth::now_ms(), vec!["read".into()])
            .expect("code");
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/pair")
                    .header("content-type", "application/json")
                    .body(Body::from(format!(r#"{{"code":"{code}"}}"#)))
                    .expect("request"),
            )
            .await
            .expect("response");
        assert_eq!(response.status(), StatusCode::OK);
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        let token = value["token"].as_str().expect("token").to_string();
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .uri("/v1/hosts")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        assert_eq!(response.status(), StatusCode::OK);
    }

    /// End to end: two real agent servers (in-process, synthetic
    /// samples), a hub polling both over real HTTP, and a client
    /// reading through the hub — snapshot, history, hosts, and a dead
    /// agent that leaves the rest of the fleet standing.
    #[tokio::test]
    async fn the_hub_polls_two_agents_and_serves_the_fleet() {
        // Two real agent states with fresh samples, each on its own
        // ephemeral loopback port.
        let mut ports = Vec::new();
        for hostname in ["host-a", "host-b"] {
            let agent_state = std::sync::Arc::new(ztop_agent::AgentState::default());
            agent_state.push(a_sample(hostname, now_ms(), 7.0));
            agent_state.push(a_sample(hostname, now_ms() + 1000, 8.0));
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .expect("bind");
            let port = listener.local_addr().expect("addr").port();
            ports.push(port);
            tokio::spawn(ztop_agent::serve_on(agent_state, listener));
        }
        // The hub watches both.
        let config: HubConfig = serde_json::from_value(json!({
            "agents": [
                {"name": "host-a", "target": format!("127.0.0.1:{}", ports[0])},
                {"name": "host-b", "target": format!("127.0.0.1:{}", ports[1])},
            ]
        }))
        .expect("config");
        config.validate().expect("valid");
        let store = Store::in_memory().await.expect("store");
        let state = HubState::new(config, store, auth::Auth::in_memory(), false);
        state.poll_once().await;
        let fleet = router(state.clone());
        // Snapshots through the hub carry each agent's own sample.
        for hostname in ["host-a", "host-b"] {
            let response = get(fleet.clone(), &format!("/v1/snapshot?host={hostname}")).await;
            assert_eq!(response.status(), StatusCode::OK);
            let body = text(response).await;
            let value: serde_json::Value = serde_json::from_str(&body).expect("json");
            assert_eq!(value["sample"]["hostname"], hostname);
            assert_eq!(value["sample"]["load_avg"][0], 8.0);
        }
        // History accumulated from the polls.
        let response = get(fleet.clone(), "/v1/history?host=host-a&seconds=60").await;
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        assert_eq!(value["samples"].as_array().expect("samples").len(), 1);
        // The fleet listing shows both live.
        let response = get(fleet.clone(), "/v1/hosts").await;
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        for host in value["hosts"].as_array().expect("hosts") {
            assert_eq!(host["state"], "live", "{host}");
        }
        // A dead agent: point one name at a port nobody listens on.
        let dead: HubConfig = serde_json::from_value(json!({
            "agents": [
                {"name": "host-a", "target": format!("127.0.0.1:{}", ports[0])},
                {"name": "host-b", "target": "127.0.0.1:1"},
            ]
        }))
        .expect("config");
        let store = Store::in_memory().await.expect("store");
        let dead_state = HubState::new(dead, store, auth::Auth::in_memory(), false);
        dead_state.poll_once().await;
        let dead_router = router(dead_state.clone());
        let response = get(dead_router.clone(), "/v1/hosts").await;
        let body = text(response).await;
        let value: serde_json::Value = serde_json::from_str(&body).expect("json");
        let hosts = value["hosts"].as_array().expect("hosts");
        let a = hosts
            .iter()
            .find(|h| h["name"] == "host-a")
            .expect("host-a");
        let b = hosts
            .iter()
            .find(|h| h["name"] == "host-b")
            .expect("host-b");
        assert_eq!(a["state"], "live");
        assert_eq!(b["state"], "pending");
        assert!(b["error"].as_str().is_some_and(|e| !e.is_empty()));
        // The live agent still reads fine while the dead one 503s.
        let response = get(dead_router.clone(), "/v1/snapshot?host=host-a").await;
        assert_eq!(response.status(), StatusCode::OK);
        let response = get(dead_router, "/v1/snapshot?host=host-b").await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }
}
