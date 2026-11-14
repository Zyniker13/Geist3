// SPDX-License-Identifier: MIT OR Apache-2.0
//! The zTop agent: serves one host's samples over the versioned protocol.
//!
//! The skeleton serves `/healthz` on the loopback interface only. The
//! protocol routes (snapshot, processes, history, live stream) arrive with
//! milestone M4 under the transport decision (0003).

use axum::routing::get;
use axum::{Json, Router};

/// Build the agent's HTTP router.
pub fn router() -> Router {
    Router::new().route("/healthz", get(health))
}

/// Serve the agent protocol on `127.0.0.1:port` until the process is stopped.
pub async fn serve(port: u16) -> std::io::Result<()> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
    axum::serve(listener, router()).await
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "service": "ztop-agent",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

#[cfg(test)]
mod tests {
    use axum::http::StatusCode;
    use axum::response::IntoResponse;

    #[tokio::test]
    async fn health_reports_service_and_version() {
        let response = super::health().await.into_response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["content-type"], "application/json");
    }
}
