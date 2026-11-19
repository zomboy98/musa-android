//! Signed session exchanges: preflight, bootstrap, grant completion, and token refresh.

use super::coordinator::{Check, Flight, SignedSessionClient};
use super::protocol::{self, Record};
use crate::auth::{PendingAuthRequest, callback_state};
use mornye_network::{query, url::UrlParts};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

#[cfg(test)]
mod exchange_race_tests {
    use super::*;
    use crate::auth::AuthRegistry;
    use crate::manifest::SignedSession;
    use crate::signed_session::SignedRegistry;
    use mornye_network::{NetworkOptions, NetworkService};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::thread;

    #[test]
    fn late_exchange_preserves_replacement_challenge_and_grant() {
        exchange_fixture(true);
    }

    #[test]
    fn duplicate_grant_exchanges_and_replaces_a_blocked_session() {
        exchange_fixture(false);
    }

    #[test]
    fn refresh_response_cannot_replace_session_blocked_during_request() {
        let directory = tempfile::tempdir().unwrap();
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions().unwrap().with_no_client_auth()
            .with_single_cert(vec![certificate.cert.der().clone()], rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into()).unwrap();
        let network = NetworkService::with_options(NetworkOptions {
            extra_root_pem: certificate.cert.pem().into_bytes(), doh_upstreams: vec![], ..Default::default()
        }).unwrap();
        network.set_allow_private_network(true);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("https://{}", listener.local_addr().unwrap());
        let (request_seen, seen) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut tls = rustls::StreamOwned::new(rustls::ServerConnection::new(Arc::new(server_config)).unwrap(), stream);
            assert!(tls.read(&mut [0; 4096]).unwrap() > 0);
            request_seen.send(()).unwrap();
            released.recv_timeout(Duration::from_secs(5)).unwrap();
            let body = r#"{"session_id":"replacement","session_secret":"replacement-secret","expires_at":"2099-01-01T00:00:00Z"}"#;
            write!(tls, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        });
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let mut config = SignedSession { namespace: "refresh-race".into(), base_url, ..Default::default() };
        config.endpoints.refresh = "/refresh".into();
        let client = registry.session("example.session", config, network.native_session(Duration::from_secs(5))).unwrap();
        let mut record = client.load().unwrap();
        record.session_id = "original".into();
        record.session_secret = "original-secret".into();
        record.expires_at = chrono::Utc::now().checked_add_signed(chrono::Duration::seconds(60)).unwrap().to_rfc3339();
        record.mark_renewal("allowed");
        client.store.save(&record).unwrap();
        let worker = {
            let client = Arc::clone(&client);
            thread::spawn(move || client.renew_existing(true, || Ok(())))
        };
        seen.recv_timeout(Duration::from_secs(5)).unwrap();
        client.scope.lock().unwrap().blocked_generation = record.generation();
        release.send(()).unwrap();
        let result = worker.join().unwrap().unwrap();
        server.join().unwrap();
        assert_eq!(result.status, "blocked");
        let state = client.scope.lock().unwrap();
        let latest = client.load().unwrap();
        assert!(state.blocked(&latest));
        assert_eq!(latest.session_id, "original");
        assert_eq!(latest.session_secret, "original-secret");
        assert_eq!(latest.expires_at, record.expires_at);
    }
    #[test]
    fn verification_veto_survives_restart_and_cancelled_refresh_cannot_commit() {
        for mode in 0..if cfg!(windows) { 3 } else { 2 } {
            let cancel = mode == 1;
            let persistence_failure = mode == 2;
            let directory = tempfile::tempdir().unwrap();
            let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
            let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions().unwrap().with_no_client_auth()
                .with_single_cert(vec![certificate.cert.der().clone()], rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into()).unwrap();
            let network = NetworkService::with_options(NetworkOptions {
                extra_root_pem: certificate.cert.pem().into_bytes(), doh_upstreams: vec![], ..Default::default()
            }).unwrap();
            network.set_allow_private_network(true);
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let base_url = format!("https://{}", listener.local_addr().unwrap());
            let (request_seen, seen) = mpsc::channel(); let (release, released) = mpsc::channel();
            let server = thread::spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut tls = rustls::StreamOwned::new(rustls::ServerConnection::new(Arc::new(server_config)).unwrap(), stream);
                assert!(tls.read(&mut [0; 4096]).unwrap() > 0);
                request_seen.send(()).unwrap(); released.recv_timeout(Duration::from_secs(5)).unwrap();
                let (status, body) = if cancel { (200, r#"{"session_id":"replacement","session_secret":"replacement-secret","expires_at":"2099-01-01T00:00:00Z"}"#) }
                    else { (428, r#"{"origin":"gateway","code":"VERIFY_REQUIRED","action":"verify"}"#) };
                let _ = write!(tls, "HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            });
            let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
            let mut config = SignedSession { namespace: "durable-guard".into(), base_url, ..Default::default() };
            config.endpoints.refresh = "/refresh".into();
            let client = registry.session("test", config.clone(), network.native_session(Duration::from_secs(5))).unwrap();
            let mut record = client.load().unwrap();
            record.session_id = "original".into(); record.session_secret = "original-secret".into();
            record.expires_at = chrono::Utc::now().checked_add_signed(chrono::Duration::seconds(60)).unwrap().to_rfc3339();
            record.mark_renewal("allowed"); client.store.save(&record).unwrap();
            let cancellation = Arc::new(mornye_core::cancellation::CancellationRegistry::new(mornye_core::cancellation::CancellationDomain::ExtensionRequest));
            let lease = Arc::new(cancellation.acquire("attempt").unwrap());
            let worker = { let client = Arc::clone(&client); let lease = Arc::clone(&lease);
                thread::spawn(move || client.renew_existing_with_lease(&lease)) };
            seen.recv_timeout(Duration::from_secs(5)).unwrap();
            let dirty = client.store.load_existing().unwrap().unwrap();
            assert!(!dirty.renewal_allowed()); assert!(!dirty.renewal_blocked());
            #[cfg(windows)]
            let blocker = if persistence_failure {
                use std::os::windows::fs::OpenOptionsExt;
                Some(std::fs::OpenOptions::new().read(true).share_mode(0x1 | 0x2).open(client.store.path()).unwrap())
            } else { None };
            if cancel { cancellation.cancel("attempt").unwrap(); }
            release.send(()).unwrap();
            let result = worker.join().unwrap(); server.join().unwrap();
            if cancel { assert!(result.is_err()); } else { assert_eq!(result.unwrap().status, "blocked"); }
            #[cfg(windows)]
            drop(blocker);
            drop(client); drop(registry);
            let reopened = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
            let client = reopened.existing_session("test", config, network.native_session(Duration::from_secs(1))).unwrap().unwrap();
            let record = client.store.load_existing().unwrap().unwrap();
            assert_eq!(record.session_id, "original"); assert_eq!(record.session_secret, "original-secret");
            let fresh = cancellation.acquire("different-attempt").unwrap();
            assert_eq!(client.renew_existing_with_lease(&fresh).unwrap().status, if cancel || persistence_failure { "unavailable" } else { "blocked" });
        }
    }

    #[test]
    fn pending_fetch_keeps_refresh_ineligible_even_when_credentials_rotate() {
        for (rotate, verify) in [(false, true), (true, true), (true, false)] {
            let directory = tempfile::tempdir().unwrap();
            let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
            let tls = Arc::new(rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions().unwrap().with_no_client_auth()
                .with_single_cert(vec![certificate.cert.der().clone()], rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into()).unwrap());
            let network = NetworkService::with_options(NetworkOptions { extra_root_pem: certificate.cert.pem().into_bytes(), doh_upstreams: vec![], ..Default::default() }).unwrap();
            network.set_allow_private_network(true);
            let refresh_listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let fetch_listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let base_url = format!("https://{}", fetch_listener.local_addr().unwrap());
            let refresh_url = format!("https://{}/refresh", refresh_listener.local_addr().unwrap());
            let (refresh_seen, refresh_wait) = mpsc::channel(); let (release_refresh, refresh_release) = mpsc::channel();
            let (fetch_seen, fetch_wait) = mpsc::channel(); let (release_fetch, fetch_release) = mpsc::channel();
            let refresh_server = { let tls = Arc::clone(&tls); thread::spawn(move || {
                let (stream, _) = refresh_listener.accept().unwrap(); stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut stream = rustls::StreamOwned::new(rustls::ServerConnection::new(tls).unwrap(), stream);
                assert!(stream.read(&mut [0; 4096]).unwrap() > 0); refresh_seen.send(()).unwrap(); refresh_release.recv_timeout(Duration::from_secs(5)).unwrap();
                let body = if rotate { r#"{"session_id":"rotated","session_secret":"rotated-secret","expires_at":"2099-01-01T00:00:00Z"}"# }
                    else { r#"{"expires_at":"2099-01-01T00:00:00Z"}"# };
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }) };
            let fetch_server = thread::spawn(move || {
                let (stream, _) = fetch_listener.accept().unwrap(); stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut stream = rustls::StreamOwned::new(rustls::ServerConnection::new(tls).unwrap(), stream);
                assert!(stream.read(&mut [0; 4096]).unwrap() > 0); fetch_seen.send(()).unwrap(); fetch_release.recv_timeout(Duration::from_secs(5)).unwrap();
                let (status, body) = if verify { (428, r#"{"origin":"gateway","code":"VERIFY_REQUIRED","action":"verify"}"#) } else { (200, "{}") };
                write!(stream, "HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            });
            let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
            let mut config = SignedSession { namespace: "concurrent-guard".into(), base_url, ..Default::default() }; config.endpoints.refresh = refresh_url;
            let client = registry.session("test", config, network.native_session(Duration::from_secs(5))).unwrap();
            let mut record = client.load().unwrap(); record.session_id = "original".into(); record.session_secret = "secret".into();
            record.expires_at = chrono::Utc::now().checked_add_signed(chrono::Duration::seconds(60)).unwrap().to_rfc3339(); record.mark_renewal("allowed"); client.store.save(&record).unwrap();
            let refresh = { let client = Arc::clone(&client); thread::spawn(move || client.renew_existing(true, || Ok(()))) };
            refresh_wait.recv_timeout(Duration::from_secs(5)).unwrap();
            let fetch = { let client = Arc::clone(&client); let record = record.clone(); thread::spawn(move || client.signed_request(&record, "GET", "/track", "", &BTreeMap::new(), &|| Ok(()))) };
            fetch_wait.recv_timeout(Duration::from_secs(5)).unwrap();
            release_refresh.send(()).unwrap();
            assert_eq!(refresh.join().unwrap().unwrap().status, "refreshed"); refresh_server.join().unwrap();
            let snapshot = client.store.load_existing().unwrap().unwrap();
            let h_server = if rotate {
                let listener = TcpListener::bind("127.0.0.1:0").unwrap();
                let h_url = format!("https://{}/new-generation", listener.local_addr().unwrap());
                let tls = Arc::new(rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                    .with_safe_default_protocol_versions().unwrap().with_no_client_auth()
                    .with_single_cert(vec![certificate.cert.der().clone()], rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into()).unwrap());
                let server = thread::spawn(move || {
                    for _ in 0..2 {
                        let (stream, _) = listener.accept().unwrap(); stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                        let mut stream = rustls::StreamOwned::new(rustls::ServerConnection::new(Arc::clone(&tls)).unwrap(), stream);
                        assert!(stream.read(&mut [0; 4096]).unwrap() > 0);
                        write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}").unwrap();
                    }
                });
                client.signed_request(&snapshot, "GET", &h_url, "", &BTreeMap::new(), &|| Ok(())).unwrap();
                assert!(!client.store.load_existing().unwrap().unwrap().renewal_allowed());
                Some((server, h_url))
            } else { None };
            assert!(!snapshot.renewal_allowed()); assert!(snapshot.renewal_guard.starts_with("dirty-v1:"));
            assert_eq!(snapshot.session_id, if rotate { "rotated" } else { "original" });
            // The warm scheduled API must also reject dirty, without a lease.
            assert_eq!(client.renew_existing(true, || Ok(())).unwrap().status, "unavailable");
            release_fetch.send(()).unwrap(); fetch.join().unwrap().unwrap(); fetch_server.join().unwrap();
            if let Some((server, h_url)) = h_server {
                let latest = client.store.load_existing().unwrap().unwrap();
                client.signed_request(&latest, "GET", &h_url, "", &BTreeMap::new(), &|| Ok(())).unwrap();
                server.join().unwrap();
            }
            let final_record = client.store.load_existing().unwrap().unwrap();
            assert_eq!(final_record.renewal_allowed(), !verify);
            assert_eq!(client.renew_existing(true, || Ok(())).unwrap().status, if !verify { "valid_until" } else if rotate { "unavailable" } else { "blocked" });
        }
    }

    #[test]
    fn snapshot_superseded_before_send_retries_once_with_current_credentials() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let directory = tempfile::tempdir().unwrap();
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let tls = Arc::new(rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions().unwrap().with_no_client_auth()
            .with_single_cert(vec![certificate.cert.der().clone()], rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into()).unwrap());
        let network = NetworkService::with_options(NetworkOptions { extra_root_pem: certificate.cert.pem().into_bytes(), doh_upstreams: vec![], ..Default::default() }).unwrap(); network.set_allow_private_network(true);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("https://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap(); stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut stream = rustls::StreamOwned::new(rustls::ServerConnection::new(tls).unwrap(), stream);
            let mut bytes = [0; 4096]; let count = stream.read(&mut bytes).unwrap();
            let request = String::from_utf8_lossy(&bytes[..count]).to_ascii_lowercase();
            assert!(request.contains("x-sig-session: replacement"));
            assert!(!request.contains("x-sig-session: original"));
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}").unwrap();
        });
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry.session("test", SignedSession { namespace: "superseded".into(), base_url, ..Default::default() }, network.native_session(Duration::from_secs(5))).unwrap();
        let mut original = client.load().unwrap(); original.session_id = "original".into(); original.session_secret = "original-secret".into(); original.expires_at = "2099-01-01T00:00:00Z".into(); original.mark_renewal("allowed"); client.store.save(&original).unwrap();
        let mut replacement = original.clone(); replacement.session_id = "replacement".into(); replacement.session_secret = "replacement-secret".into(); replacement.mark_renewal("dirty");
        let checkpoints = AtomicUsize::new(0);
        client.signed_fetch("GET", "/track", "", &BTreeMap::new(), || {
            if checkpoints.fetch_add(1, Ordering::SeqCst) == 1 {
                // Deterministic interleaving: the request has its old snapshot,
                // but replacement occurs at its pre-send check under scope lock.
                client.store.save(&replacement)?;
            }
            Ok(())
        }).unwrap();
        server.join().unwrap();
        let latest = client.store.load_existing().unwrap().unwrap();
        assert_eq!(latest.session_id, "replacement");
        assert!(!latest.renewal_allowed()); // Interactive fetch succeeded; scheduling stays closed.
        assert_eq!(client.renew_existing(true, || Ok(())).unwrap().status, "unavailable");
    }

    #[cfg(windows)]
    #[test]
    fn failed_durable_invalidation_sends_no_network_request_and_preserves_allowed_ciphertext() {
        use std::os::windows::fs::OpenOptionsExt;
        let directory = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let network = NetworkService::new().unwrap(); network.set_allow_private_network(true);
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let mut config = SignedSession { namespace: "persist-failure".into(), base_url: format!("https://{}", listener.local_addr().unwrap()), ..Default::default() };
        config.endpoints.refresh = "/refresh".into();
        let client = registry.session("test", config, network.native_session(Duration::from_secs(1))).unwrap();
        let mut record = client.load().unwrap();
        record.session_id = "original".into(); record.session_secret = "original-secret".into();
        record.expires_at = chrono::Utc::now().checked_add_signed(chrono::Duration::seconds(60)).unwrap().to_rfc3339();
        record.mark_renewal("allowed"); client.store.save(&record).unwrap();
        let before = std::fs::read(client.store.path()).unwrap();
        // Synthetic fixture denies only replacement, preserving reads and writes.
        let blocker = std::fs::OpenOptions::new().read(true).share_mode(0x1 | 0x2).open(client.store.path()).unwrap();
        let cancellation = mornye_core::cancellation::CancellationRegistry::new(mornye_core::cancellation::CancellationDomain::ExtensionRequest);
        let lease = cancellation.acquire("attempt").unwrap();
        assert_eq!(client.renew_existing_with_lease(&lease).unwrap().status, "unavailable");
        assert_eq!(listener.accept().err().unwrap().kind(), std::io::ErrorKind::WouldBlock);
        assert_eq!(std::fs::read(client.store.path()).unwrap(), before);
        assert_eq!(std::fs::read_dir(client.store.path().parent().unwrap()).unwrap().count(), 1);
        assert!(client.store.load_existing().unwrap().unwrap().renewal_allowed());
        drop(blocker);
    }

    fn exchange_fixture(replace_challenge: bool) {
        let directory = tempfile::tempdir().unwrap();
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![certificate.cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der())
                .into(),
        )
        .unwrap();
        let network = NetworkService::with_options(NetworkOptions {
            extra_root_pem: certificate.cert.pem().into_bytes(),
            doh_upstreams: vec![],
            ..Default::default()
        })
        .unwrap();
        network.set_allow_private_network(true);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("https://{}", listener.local_addr().unwrap());
        let (request_seen, seen) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut tls = rustls::StreamOwned::new(
                rustls::ServerConnection::new(Arc::new(server_config)).unwrap(),
                stream,
            );
            assert!(tls.read(&mut [0; 4096]).unwrap() > 0);
            request_seen.send(()).unwrap();
            released.recv_timeout(Duration::from_secs(5)).unwrap();
            let body = r#"{"session_id":"fixture-id","session_secret":"fixture-secret","expires_at":"2099-01-01T00:00:00Z"}"#;
            write!(
                tls,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let auth = Arc::new(AuthRegistry::default());
        let registry = SignedRegistry::new(directory.path(), Arc::clone(&auth));
        let client = registry
            .session(
                "example.session",
                SignedSession {
                    namespace: "fixture".into(),
                    base_url,
                    ..Default::default()
                },
                network.native_session(Duration::from_secs(5)),
            )
            .unwrap();
        let register = |nonce: &str| {
            let mut scope = client.scope.lock().unwrap();
            let pending = auth
                .register_pending(PendingAuthRequest {
                    extension_id: "example.session".into(),
                    auth_url: "https://example.invalid/verify".into(),
                    callback_url: "mornye://session-grant".into(),
                    verification_id: String::new(),
                    state: nonce.into(),
                    created_at: auth.now(),
                })
                .unwrap();
            scope.remember(pending);
        };
        register("fixture-old");
        if !replace_challenge {
            let mut record = client.load().unwrap();
            record.session_id = "blocked-fixture-id".into();
            record.session_secret = "blocked-fixture-secret".into();
            record.expires_at = "2099-01-01T00:00:00Z".into();
            client.store.save(&record).unwrap();
            let mut scope = client.scope.lock().unwrap();
            scope.blocked_generation = record.generation();
            scope.completed_grant =
                crate::binary::encode(&Sha256::digest("fixture-grant-a"), "hex").unwrap();
        }
        let worker = {
            let client = Arc::clone(&client);
            thread::spawn(move || client.complete_grant("fixture-grant-a", || Ok(())))
        };
        seen.recv_timeout(Duration::from_secs(5)).unwrap();
        if replace_challenge {
            register("fixture-new");
            registry
                .set_grant("example.session", "fixture-grant-b")
                .unwrap();
        }
        release.send(()).unwrap();
        let result = worker.join().unwrap();
        server.join().unwrap();
        if replace_challenge {
            assert!(auth.resolve_callback("fixture-new", false).is_ok());
            assert_eq!(
                registry.grants.lock().unwrap()["example.session"]
                    .value
                    .as_str(),
                "fixture-grant-b"
            );
            assert!(result.is_err());
        } else {
            result.unwrap();
            assert_eq!(client.load().unwrap().session_id, "fixture-id");
        }
    }
}

enum Bootstrap {
    Session(Record),
    Challenge {
        url: String,
        callback: String,
        state: String,
    },
}

fn response_record(body: &[u8]) -> Result<Record, String> {
    let fields = protocol::object_fields(
        body,
        &[
            "session_id",
            "session_secret",
            "expires_at",
            "challenge_id",
            "challenge_url",
            "auth_url",
        ],
        &[],
        &[],
    )?;
    serde_json::from_value(Value::Object(fields)).map_err(|error| error.to_string())
}

#[derive(Debug, serde::Serialize)]
pub struct RenewalResult {
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}
impl RenewalResult {
    pub(crate) fn new(status: &'static str, expires_at: Option<String>) -> Self { Self { status, expires_at } }
}
impl SignedSessionClient {
    pub fn preflight(&self, check: impl Fn() -> Result<(), String>) -> Result<bool, String> {
        self.check(&check)?;
        {
            let state = self.scope.lock().expect("signed session coordinator lock");
            let record = self.load()?;
            if record.usable(self.registry.auth.now()) && !state.blocked(&record) {
                return Ok(false);
            }
        }
        let url = self.bootstrap(&check)?;
        if !url.is_empty() {
            return Ok(true);
        }
        let _state = self.scope.lock().expect("signed session coordinator lock");
        if self.load()?.usable(self.registry.auth.now()) {
            Ok(false)
        } else {
            Err(
                "signed-session bootstrap did not return a session or verification challenge"
                    .into(),
            )
        }
    }

    pub(super) fn bootstrap(&self, check: Check<'_>) -> Result<String, String> {
        loop {
            self.check(check)?;
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            if let Some(challenge) = state.challenge.as_ref().filter(|challenge| {
                !challenge.auth_url.trim().is_empty()
                    && self.registry.auth.now() - challenge.created_at < 180_000_000_000
            }) {
                let mut pending = challenge.clone();
                pending.extension_id = self.id.clone();
                self.registry.auth.register_pending(pending.clone())?;
                state.pending_ids.insert(self.id.clone());
                return Ok(pending.auth_url);
            }
            if state.challenge.is_some() {
                state.clear_challenge(&self.registry.auth);
            }
            if let Some(pending) = self
                .registry
                .auth
                .pending(&self.id)
                .filter(|pending| !pending.auth_url.trim().is_empty())
            {
                let url = pending.auth_url.clone();
                state.remember(pending);
                return Ok(url);
            }
            let record = self
                .load()
                .map_err(|error| format!("load signed-session bootstrap state: {error}"))?;
            if record.usable(self.registry.auth.now()) && !state.blocked(&record) {
                return Ok(String::new());
            }
            if let Some(flight) = state.bootstrap.clone() {
                drop(state);
                flight.wait(&|| self.check(check))?;
                continue;
            }
            let flight = Arc::new(Flight::default());
            state.bootstrap = Some(Arc::clone(&flight));
            let generation = state.clear_generation;
            drop(state);
            let bootstrap = self.perform_bootstrap(&record, check);
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let result = (|| {
                let bootstrap = bootstrap?;
                self.check(check)?;
                if state.clear_generation != generation {
                    return Err("signed-session bootstrap was superseded by session clear".into());
                }
                let mut latest = self.load()?;
                if latest.usable(self.registry.auth.now())
                    && !latest.same_session(&record)
                    && !state.blocked(&latest)
                {
                    state.clear_challenge(&self.registry.auth);
                    return Ok(String::new());
                }
                match bootstrap {
                    Bootstrap::Session(record) => {
                        latest.session_id.clone_from(&record.session_id);
                        latest.session_secret.clone_from(&record.session_secret);
                        latest.expires_at.clone_from(&record.expires_at);
                        latest.mark_renewal(if state.requests.is_empty() { "allowed" } else { "dirty" });
                        state.dirty_owned.insert(latest.generation());
                        self.store.save(&latest).map_err(|error| {
                            format!("save bootstrapped signed session: {error}")
                        })?;
                        if state.requests.is_empty() { state.tainted.clear(); }
                        state.blocked_generation.clear();
                        state.clear_challenge(&self.registry.auth);
                        Ok(String::new())
                    }
                    Bootstrap::Challenge {
                        url,
                        callback,
                        state: nonce,
                    } => {
                        let pending = self.registry.auth.register_pending(PendingAuthRequest {
                            extension_id: self.id.clone(),
                            auth_url: url.clone(),
                            callback_url: callback,
                            verification_id: String::new(),
                            state: nonce,
                            created_at: self.registry.auth.now(),
                        })?;
                        state.remember(pending);
                        Ok(url)
                    }
                }
            })();
            state.bootstrap = None;
            flight.finish(result.as_ref().map(|_| ()).map_err(Clone::clone));
            return result;
        }
    }

    fn perform_bootstrap(&self, record: &Record, check: Check<'_>) -> Result<Bootstrap, String> {
        let url = protocol::endpoint(&self.config, &self.config.endpoints.bootstrap)
            .map_err(|error| format!("build signed-session bootstrap URL: {error}"))?;
        let url = protocol::with_query(
            &url,
            &[
                ("app_version", &self.config.app_version),
                ("install_id", &record.install_id),
            ],
        )?;
        let mut response = self.request("GET", url.clone(), String::new(), BTreeMap::new(), check);
        if response.is_err() {
            self.check(check)?;
            self.network.reset_connections();
            response = self.request("GET", url.clone(), String::new(), BTreeMap::new(), check);
        }
        let response = response.map_err(|error| {
            format!(
                "signed-session bootstrap network request to {} failed: {error}",
                UrlParts::parse(&url)
                    .map(|url| url.authority())
                    .unwrap_or_default()
            )
        })?;
        if !(200..300).contains(&response.status) {
            let mut error = format!(
                "signed-session bootstrap {}returned HTTP {}",
                if response.status >= 500 {
                    "network request "
                } else {
                    ""
                },
                response.status
            );
            let retry = protocol::response_retry_after(&response, self.registry.auth.now());
            if retry > 0 {
                error += &format!("; retry-after seconds: {retry}");
            }
            return Err(error);
        }
        let body = Zeroizing::new(response.body);
        let record = response_record(&body)
            .map_err(|error| format!("decode signed-session bootstrap response: {error}"))?;
        let boot = protocol::object_fields(
            &body,
            &["auth_url", "challenge_url", "challenge_id"],
            &[],
            &[],
        )
        .map_err(|error| format!("decode signed-session bootstrap response: {error}"))?;
        if !record.session_id.is_empty()
            && !record.session_secret.is_empty()
            && !record.expires_at.is_empty()
        {
            return Ok(Bootstrap::Session(record));
        }
        let text = |key| boot.get(key).and_then(Value::as_str).unwrap_or("");
        let mut auth_url = text("auth_url").to_owned();
        if auth_url.is_empty() {
            auth_url = text("challenge_url").to_owned();
        }
        let mut state = callback_state()
            .map_err(|error| format!("prepare signed-session callback state: {error}"))?;
        if let Some(url) = UrlParts::parse(&auth_url) {
            let values = query::parse(&url.raw_query);
            let server_state = values
                .get(b"state".as_slice())
                .and_then(|values| values.first())
                .map(|bytes| crate::host::decode_go_utf8(bytes))
                .unwrap_or_default();
            if !server_state.trim().is_empty() {
                state = server_state.trim().to_owned();
            } else if !auth_url.is_empty() {
                auth_url = protocol::with_query(&auth_url, &[("state", &state)])?;
            }
        }
        let callback = protocol::with_query(&self.config.callback_url, &[("state", &state)])
            .map_err(|error| format!("prepare signed-session callback: {error}"))?;
        if auth_url.is_empty() && !text("challenge_id").is_empty() {
            auth_url = protocol::challenge_url(&self.config, text("challenge_id"), &state)
                .unwrap_or_default();
        }
        if auth_url.is_empty() {
            return Err(
                "signed-session bootstrap did not return a session or verification challenge"
                    .into(),
            );
        }
        Ok(Bootstrap::Challenge {
            url: auth_url,
            callback,
            state,
        })
    }

    pub fn complete_grant(
        &self,
        grant: &str,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        self.complete_verification_grant(grant, None, check)
    }

    pub(crate) fn complete_verification_grant(
        &self,
        grant: &str,
        scoped: Option<Arc<super::VerificationGrant>>,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        let grant = if let Some(scoped) = scoped {
            if !grant.trim().is_empty() && scoped.value.as_str() != grant.trim() {
                return Err("grant does not match the active verification".into());
            }
            scoped
        } else {
            self.registry
                .select_grant(&self.id, grant)?
                .ok_or("no pending grant")?
        };
        let end = Instant::now() + Duration::from_secs(30);
        let check = || {
            self.check(&check)?;
            if Instant::now() >= end {
                Err("context deadline exceeded".into())
            } else {
                Ok(())
            }
        };
        self.exchange(&grant.value, grant.verification_id.as_deref(), &check)?;
        let mut grants = self.registry.grants.lock().expect("session grants lock");
        // A newer callback can arrive during HTTP. Do not discard its grant.
        if grants
            .get(&self.id)
            .is_some_and(|pending| Arc::ptr_eq(pending, &grant))
        {
            grants.remove(&self.id);
        }
        Ok(())
    }

    fn exchange(
        &self,
        grant: &str,
        verification_id: Option<&str>,
        check: Check<'_>,
    ) -> Result<(), String> {
        let generation = self
            .scope
            .lock()
            .expect("signed session coordinator lock")
            .clear_generation;
        let flight = loop {
            self.check(check)?;
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            if let Some(flight) = state.exchange.clone() {
                drop(state);
                // Exchange slots serialize different grants. The preceding
                // grant's failure is not the outcome of this new operation.
                let _ = flight.wait(&|| self.check(check));
                self.check(check)?;
            } else {
                let flight = Arc::new(Flight::default());
                state.exchange = Some(Arc::clone(&flight));
                break flight;
            }
        };
        let result = self.exchange_owned(grant, verification_id, generation, check);
        self.scope
            .lock()
            .expect("signed session coordinator lock")
            .exchange = None;
        flight.finish(result.clone());
        result
    }

    fn exchange_owned(
        &self,
        grant: &str,
        verification_id: Option<&str>,
        generation: u64,
        check: Check<'_>,
    ) -> Result<(), String> {
        let grant_hash =
            crate::binary::encode(&Sha256::digest(grant), "hex").expect("hex encoding");
        let record = {
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            if state.clear_generation != generation {
                return Err("signed-session exchange was superseded by session clear".into());
            }
            if !self
                .registry
                .auth
                .matches_verification(&self.id, verification_id)
            {
                return Err("verification challenge was replaced".into());
            }
            let record = self.load()?;
            if state.completed_grant == grant_hash
                && record.usable(self.registry.auth.now())
                && !state.blocked(&record)
            {
                return self
                    .registry
                    .auth
                    .finish_verification(&self.id, verification_id, || {
                        Self::finish_exchange_scope(&mut state, verification_id);
                        Ok(())
                    });
            }
            record
        };
        let url = protocol::endpoint(&self.config, &self.config.endpoints.exchange)?;
        let body = Zeroizing::new(json!({"grant":grant,"install_id":record.install_id,"app_version":self.config.app_version,"platform":self.config.platform}).to_string());
        let mut exchanged = None;
        for attempt in 0..3 {
            let response = self.request(
                "POST",
                url.clone(),
                body.to_string(),
                BTreeMap::from([("content-type".into(), "application/json".into())]),
                check,
            )?;
            let retry = protocol::response_retry_after(&response, self.registry.auth.now());
            if response.status == 429 && attempt < 2 {
                self.wait(Duration::from_secs(retry.clamp(1, 300) as u64), check)?;
                continue;
            }
            if !(200..300).contains(&response.status) {
                let mut error = format!("session exchange failed: HTTP {}", response.status);
                if retry > 0 {
                    error += &format!("; retry-after seconds: {retry}");
                }
                return Err(error);
            }
            exchanged = Some(
                response_record(&Zeroizing::new(response.body))
                    .map_err(|error| format!("invalid session exchange response: {error}"))?,
            );
            break;
        }
        let exchanged = exchanged.ok_or("session exchange did not complete")?;
        if exchanged.session_id.is_empty()
            || exchanged.session_secret.is_empty()
            || exchanged.expires_at.is_empty()
        {
            return Err("session exchange response missing session fields".into());
        }
        self.check(check)?;
        let mut state = self.scope.lock().expect("signed session coordinator lock");
        if state.clear_generation != generation {
            return Err("signed-session exchange was superseded by session clear".into());
        }
        self.registry
            .auth
            .finish_verification(&self.id, verification_id, || {
                let mut latest = self.load()?;
                if !(latest.usable(self.registry.auth.now())
                    && !state.blocked(&latest)
                    && (state.completed_grant == grant_hash || !latest.same_session(&record)))
                {
                    latest.session_id.clone_from(&exchanged.session_id);
                    latest.session_secret.clone_from(&exchanged.session_secret);
                    latest.expires_at.clone_from(&exchanged.expires_at);
                    latest.mark_renewal(if state.requests.is_empty() { "allowed" } else { "dirty" });
                    state.dirty_owned.insert(latest.generation());
                    self.store.save(&latest)?;
                    state.completed_grant = grant_hash;
                }
                if state.requests.is_empty() { state.tainted.clear(); }
                Self::finish_exchange_scope(&mut state, verification_id);
                Ok(())
            })
    }

    fn finish_exchange_scope(state: &mut super::coordinator::State, verification_id: Option<&str>) {
        state.blocked_generation.clear();
        if state
            .challenge
            .as_ref()
            .map(|pending| pending.verification_id.as_str())
            == verification_id
        {
            state.challenge = None;
            state.pending_ids.clear();
        }
    }

    /// Checks an existing session without bootstrap or verification UI.
    pub fn renew_existing(
        &self,
        enabled: bool,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<RenewalResult, String> {
        self.renew_existing_mode(enabled, check, None)
    }

    pub fn renew_existing_with_lease(&self, lease: &mornye_core::cancellation::RequestLease) -> Result<RenewalResult, String> {
        self.renew_existing_with_lease_checked(lease, || Ok(()))
    }

    pub(crate) fn renew_existing_with_lease_checked(&self, lease: &mornye_core::cancellation::RequestLease, check: impl Fn() -> Result<(), String>) -> Result<RenewalResult, String> {
        self.renew_existing_mode(true, || {
            lease.check_active().map_err(|_| "session renewal cancelled".to_owned())?;
            check()
        }, Some(lease))
    }

    fn renew_existing_mode(&self, enabled: bool, check: impl Fn() -> Result<(), String>, lease: Option<&mornye_core::cancellation::RequestLease>) -> Result<RenewalResult, String> {
        self.check(&check)?;
        if !enabled { return Ok(RenewalResult::new("disabled", None)); }
        let record = {
            let state = self.scope.lock().expect("signed session coordinator lock");
            let record = match self.store.load_existing() {
                Ok(Some(record)) => record,
                Ok(None) => return Ok(RenewalResult::new("missing", None)),
                Err(error) if error == super::store::LEGACY_REQUIRES_FOREGROUND =>
                    return Ok(RenewalResult::new("unavailable", None)),
                Err(error) => return Err(error),
            };
            if record.install_id.trim().is_empty() || record.session_id.trim().is_empty() || record.session_secret.trim().is_empty() {
                return Ok(RenewalResult::new("missing", None));
            }
            if state.blocked(&record) { return Ok(RenewalResult::new("blocked", None)); }
            match protocol::parse_time(&record.expires_at) {
                None => return Ok(RenewalResult::new("unavailable", None)),
                Some(expiry) if expiry <= self.registry.auth.now() => return Ok(RenewalResult::new("invalid", None)),
                Some(_) => {}
            }
            if !record.renewal_allowed() { return Ok(RenewalResult::new("unavailable", None)); }
            if self.config.endpoints.refresh.is_empty() { return Ok(RenewalResult::new("unavailable", None)); }
            record
        };
        if !record.refresh_due(&self.config, self.registry.auth.now()) {
            return Ok(RenewalResult::new("valid_until", Some(record.expires_at.clone())));
        }
        if self.refresh_mode(&check, true, lease).is_err() {
            self.check(&check)?;
            let state = self.scope.lock().expect("signed session coordinator lock");
            let latest = self.store.load_existing()?.ok_or("signed session disappeared")?;
            if state.blocked(&latest) { return Ok(RenewalResult::new("blocked", None)); }
            return Ok(RenewalResult::new("unavailable", None));
        }
        let state = self.scope.lock().expect("signed session coordinator lock");
        let latest = self.store.load_existing()?.ok_or("signed session disappeared")?;
        if state.blocked(&latest) { return Ok(RenewalResult::new("blocked", None)); }
        if latest.session_id.trim().is_empty() || latest.session_secret.trim().is_empty() {
            return Ok(RenewalResult::new("invalid", None));
        }
        match protocol::parse_time(&latest.expires_at) {
            None => return Ok(RenewalResult::new("unavailable", None)),
            Some(expiry) if expiry <= self.registry.auth.now() => return Ok(RenewalResult::new("invalid", None)),
            Some(_) => {}
        }
        let changed = !latest.same_session(&record) || latest.expires_at != record.expires_at;
        Ok(RenewalResult::new(if changed { "refreshed" } else { "valid_until" }, Some(latest.expires_at.clone())))
    }

    pub(super) fn refresh(&self, check: Check<'_>) -> Result<(), String> {
        self.refresh_mode(check, false, None)
    }

    fn refresh_mode(&self, check: Check<'_>, existing_only: bool, lease: Option<&mornye_core::cancellation::RequestLease>) -> Result<(), String> {
        let load = || if existing_only {
            self.store.load_existing()?.ok_or_else(|| "signed session disappeared".to_owned())
        } else { self.load() };
        loop {
            self.check(check)?;
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let record = load()?;
            if state.blocked(&record) || !record.refresh_due(&self.config, self.registry.auth.now()) {
                return Ok(());
            }
            if let Some(flight) = state.refresh.clone() {
                drop(state);
                flight.wait(&|| self.check(check))?;
                continue;
            }
            let flight = Arc::new(Flight::default());
            state.refresh = Some(Arc::clone(&flight));
            let generation = state.clear_generation;
            drop(state);
            let response = self.signed_request_with_lease(
                &record,
                "POST",
                &self.config.endpoints.refresh,
                &json!({"install_id":record.install_id}).to_string(),
                &BTreeMap::new(),
                check,
                lease,
            );
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let result = (|| {
                let response = response?;
                if !(200..300).contains(&response.status) {
                    return Err(format!("session refresh failed: HTTP {}", response.status));
                }
                let refreshed = response_record(&Zeroizing::new(response.body)).map_err(|_| "invalid session refresh response")?;
                self.check(check)?;
                if state.clear_generation != generation {
                    return Err("signed-session refresh was superseded by session clear".into());
                }
                let mut latest = load()?;
                if latest.same_session(&record) {
                    if state.blocked(&record) {
                        return Err("signed-session refresh superseded by verification".into());
                    }
                    if refreshed.session_id.is_empty() && refreshed.session_secret.is_empty() && refreshed.expires_at.is_empty() {
                        return Err("empty session refresh response".into());
                    }
                    let effective_expiry = if refreshed.expires_at.is_empty() { &latest.expires_at } else { &refreshed.expires_at };
                    if !protocol::parse_time(effective_expiry).is_some_and(|expires| expires > self.registry.auth.now()) {
                        return Err("invalid session refresh expiry".into());
                    }
                    let mut changed = false;
                    for (field, value) in [
                        (&mut latest.session_id, &refreshed.session_id),
                        (&mut latest.session_secret, &refreshed.session_secret),
                        (&mut latest.expires_at, &refreshed.expires_at),
                    ] {
                        if !value.is_empty() && field != value {
                            field.clone_from(value);
                            changed = true;
                        }
                    }
                    if changed {
                        // Another request may still discover verification for the
                        // source generation. Never publish cold eligibility while
                        // any request is outstanding, including credential rotation.
                        let eligible = state.requests.is_empty()
                            && state.tainted.is_empty()
                            && !state.blocked(&latest);
                        latest.mark_renewal(if eligible { "allowed" } else { "dirty" });
                        state.dirty_owned.insert(latest.generation());
                        self.check(check)?;
                        self.save_with_lease(&latest, lease)?;
                    }
                }
                Ok(())
            })();
            state.refresh = None;
            flight.finish(result.clone());
            return result;
        }
    }
}

#[cfg(test)]
mod renewal_guard_tests {
    use crate::auth::AuthRegistry;
    use crate::manifest::SignedSession;
    use crate::signed_session::SignedRegistry;
    use mornye_network::NetworkService;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn cancelled_lease_cannot_commit_replacement_session_credentials() {
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry.session("test", SignedSession { namespace: "cancel-commit".into(), base_url: "https://accounts.example.test".into(), ..Default::default() }, network.native_session(Duration::from_secs(1))).unwrap();
        let mut original = client.load().unwrap(); original.session_id = "original".into(); original.session_secret = "original-secret".into(); original.mark_renewal("allowed"); client.store.save(&original).unwrap();
        let before = std::fs::read(client.store.path()).unwrap();
        let mut replacement = original.clone(); replacement.session_secret = "replacement-secret".into();
        let cancellation = mornye_core::cancellation::CancellationRegistry::new(mornye_core::cancellation::CancellationDomain::ExtensionRequest);
        let lease = cancellation.acquire("attempt").unwrap(); lease.check_active().unwrap();
        cancellation.cancel("attempt").unwrap();
        assert_eq!(client.save_with_lease(&replacement, Some(&lease)).err().unwrap(), "session renewal cancelled");
        assert_eq!(std::fs::read(client.store.path()).unwrap(), before);
    }

    #[test]
    fn cold_reader_never_creates_identity_or_challenge() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("absent");
        let network = NetworkService::new().unwrap();
        let auth = Arc::new(AuthRegistry::default());
        let registry = SignedRegistry::new(&root, Arc::clone(&auth));
        let config = SignedSession { namespace: "cold".into(), base_url: "https://127.0.0.1".into(), ..Default::default() };
        assert!(registry.existing_session("test", config.clone(), network.native_session(Duration::from_secs(1))).unwrap().is_none());
        assert!(!root.exists());
        std::fs::create_dir_all(root.join("signed_sessions")).unwrap();
        let client = registry.existing_session("test", config, network.native_session(Duration::from_secs(1))).unwrap().unwrap();
        assert_eq!(client.renew_existing(true, || Ok(())).unwrap().status, "missing");
        assert!(!client.store.path().exists());
        let legacy = br#"{"session_id":"session","session_secret":"secret","expires_at":"2099-01-01T00:00:00Z"}"#;
        std::fs::write(client.store.path(), legacy).unwrap();
        assert_eq!(client.renew_existing(true, || Ok(())).unwrap().status, "unavailable");
        assert_eq!(std::fs::read(client.store.path()).unwrap(), legacy);
        std::fs::write(client.store.path(), b"{broken").unwrap();
        assert!(client.renew_existing(true, || Ok(())).is_err());
        assert_eq!(std::fs::read(client.store.path()).unwrap(), b"{broken");
        assert!(auth.pending("test").is_none());
        let state = client.scope.lock().unwrap();
        assert!(state.bootstrap.is_none());
        assert!(state.challenge.is_none());
        assert!(state.refresh.is_none());
    }

    #[test]
    fn scheduled_renewal_skips_disabled_and_missing_sessions_without_creating_record() {
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let mut config = SignedSession {
            namespace: "renewal-empty".into(),
            base_url: "https://127.0.0.1".into(),
            ..Default::default()
        };
        config.endpoints.refresh = "/refresh".into();
        let client = registry.session("test", config, network.native_session(Duration::from_secs(1))).unwrap();
        assert!(client.renew_existing(false, || Ok(())).is_ok());
        assert!(client.renew_existing(true, || Ok(())).is_ok());
        assert!(!client.store.path().exists());
    }
    #[test]
    fn scheduled_renewal_classifies_expiry_without_network_or_state_changes() {
        use crate::auth::AuthClock;
        use std::net::TcpListener;
        struct FixedClock;
        impl AuthClock for FixedClock {
            fn now_nanos(&self) -> i128 { 1_700_000_000_000_000_000 }
        }
        let directory = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::with_clock(Arc::new(FixedClock))));
        let mut config = SignedSession { namespace: "renewal-expiry".into(), base_url: format!("https://{}", listener.local_addr().unwrap()), ..Default::default() };
        config.endpoints.refresh = "/refresh".into();
        let client = registry.session("test", config, network.native_session(Duration::from_secs(1))).unwrap();
        let mut record = client.load().unwrap();
        record.session_id = "session".into();
        record.session_secret = "secret".into();
        record.mark_renewal("allowed");
        for (expiry, expected) in [
            ("", "unavailable"),
            ("not a timestamp", "unavailable"),
            ("2023-11-14T22:13:19Z", "invalid"),
            ("2023-11-14T22:13:20Z", "invalid"),
            ("2099-01-01T00:00:00Z", "valid_until"),
        ] {
            record.expires_at = expiry.into();
            client.store.save(&record).unwrap();
            let before = std::fs::read(client.store.path()).unwrap();
            let result = client.renew_existing(true, || Ok(())).unwrap();
            assert_eq!(result.status, expected, "expiry {expiry:?}");
            assert_eq!(std::fs::read(client.store.path()).unwrap(), before);
            assert!(listener.accept().is_err(), "unexpected network connection for {expiry:?}");
            let state = client.scope.lock().unwrap();
            assert!(state.refresh.is_none());
            assert!(state.bootstrap.is_none());
            assert!(state.challenge.is_none());
        }
    }
    #[test]
    fn blocked_session_is_not_refreshed() {
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let mut config = SignedSession {
            namespace: "renewal-guard".into(),
            base_url: "https://127.0.0.1".into(),
            ..Default::default()
        };
        config.endpoints.refresh = "/refresh".into();
        let client = registry.session("test", config, network.native_session(Duration::from_secs(1))).unwrap();
        let mut record = client.load().unwrap();
        record.session_id = "session".into();
        record.session_secret = "secret".into();
        // A fixed clock puts this session inside the refresh window.
        record.expires_at = chrono::Utc::now().checked_add_signed(chrono::Duration::seconds(60)).unwrap().to_rfc3339();
        client.store.save(&record).unwrap();
        client.scope.lock().unwrap().blocked_generation = record.generation();
        assert!(client.refresh(&|| Ok(())).is_ok());
        assert_eq!(client.load().unwrap().session_id, "session");
    }
}
