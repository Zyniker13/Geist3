// SPDX-License-Identifier: MIT OR Apache-2.0
//! TLS for the agent: a self-signed certificate per agent, created on
//! first `--tls` start and kept next to the token store, so a client
//! that pinned the certificate stays pinned across restarts. The
//! fingerprint is the SHA-256 of the certificate's DER, printed by the
//! agent and checked by the client (decision 0003: nothing about TLS
//! is written by hand).

use std::fs;
use std::io;
use std::path::Path;
use std::sync::Arc;

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use sha2::Digest;

/// How long a freshly generated agent certificate lives. Self-signed
/// and pinned by hash, so it is renewed only by the person running the
/// agent; a short life would break every client's pin.
const VALIDITY_DAYS: i64 = 365 * 10;

/// The ready-to-serve TLS configuration plus the pin clients use.
pub struct TlsMaterial {
    pub config: rustls::ServerConfig,
    /// `SHA256:<hex of the leaf certificate's DER>`.
    pub fingerprint: String,
}

/// Load the agent's certificate and key from `dir`, creating a fresh
/// self-signed pair when they are missing. The key is written 0600.
pub fn load_or_create(dir: &Path) -> io::Result<TlsMaterial> {
    let cert_path = dir.join("agent-cert.pem");
    let key_path = dir.join("agent-key.pem");
    if !cert_path.exists() || !key_path.exists() {
        generate(&cert_path, &key_path)?;
    }
    let cert_pem = fs::read(&cert_path)?;
    let key_pem = fs::read(&key_path)?;
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(&cert_pem)
        .collect::<Result<_, _>>()
        .map_err(|error| io::Error::other(format!("bad certificate file: {error}")))?;
    let key: PrivateKeyDer<'static> = PrivateKeyDer::from_pem_slice(&key_pem)
        .map_err(|error| io::Error::other(format!("bad key file: {error}")))?;

    let leaf = certs
        .first()
        .ok_or_else(|| io::Error::other("the certificate file is empty"))?;
    let fingerprint = format!("SHA256:{}", hex(&sha2::Sha256::digest(leaf.as_ref())));

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|error| io::Error::other(format!("TLS versions: {error}")))?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|error| io::Error::other(format!("TLS material: {error}")))?;
    Ok(TlsMaterial {
        config,
        fingerprint,
    })
}

/// Generate a self-signed certificate for loopback names and write it
/// with its key. The key file is 0600 on unix.
fn generate(cert_path: &Path, key_path: &Path) -> io::Result<()> {
    let key = rcgen::KeyPair::generate()
        .map_err(|error| io::Error::other(format!("key generation: {error}")))?;
    let mut params =
        rcgen::CertificateParams::new(vec!["localhost".to_string(), "127.0.0.1".to_string()])
            .map_err(|error| io::Error::other(format!("certificate parameters: {error}")))?;
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, "ztop-agent");
    let now = time::OffsetDateTime::now_utc();
    params.not_before = now - time::Duration::days(1);
    params.not_after = now + time::Duration::days(VALIDITY_DAYS);
    let cert = params
        .self_signed(&key)
        .map_err(|error| io::Error::other(format!("self-signing: {error}")))?;
    fs::write(cert_path, cert.pem())?;
    fs::write(key_path, key.serialize_pem())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(key_path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// Lowercase hex, no separators.
fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

/// Serve the router over TLS on an already-bound listener: the seam
/// the integration tests use to get an ephemeral port. A failed
/// handshake just drops that connection.
pub async fn serve_on_tls(
    state: Arc<crate::AgentState>,
    listener: tokio::net::TcpListener,
    config: rustls::ServerConfig,
) -> io::Result<()> {
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let router = crate::router(state);
    loop {
        let (stream, _) = listener.accept().await?;
        let acceptor = acceptor.clone();
        let router = router.clone();
        tokio::spawn(async move {
            let tls_stream = match acceptor.accept(stream).await {
                Ok(stream) => stream,
                Err(_) => return,
            };
            let service = hyper_util::service::TowerToHyperService::new(router.clone());
            let _ =
                hyper_util::server::conn::auto::Builder::new(hyper_util::rt::TokioExecutor::new())
                    .serve_connection_with_upgrades(
                        hyper_util::rt::TokioIo::new(tls_stream),
                        service,
                    )
                    .await;
        });
    }
}
