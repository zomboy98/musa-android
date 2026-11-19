use super::coordinator::SignedSessionClient;
use super::protocol::{self, ErrorContract};
use serde_json::Value;
use std::collections::BTreeMap;

impl SignedSessionClient {
    pub fn signed_fetch(
        &self,
        method: &str,
        path: &str,
        body: &str,
        headers: &BTreeMap<String, String>,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        self.check(&check)?;
        let method = method.trim().to_uppercase();
        let mut record = {
            let state = self.scope.lock().expect("signed session coordinator lock");
            let mut record = self.load()?;
            let error = if record.session_id.is_empty() || record.session_secret.is_empty() {
                Some("signed session is not authenticated")
            } else if protocol::parse_time(&record.expires_at)
                .is_some_and(|expires| self.registry.auth.now() > expires)
            {
                record.clear();
                let _ = self.store.save(&record);
                Some("signed session expired")
            } else {
                None
            };
            if let Some(error) = error {
                drop(state);
                let url = match self.bootstrap(&check) {
                    Ok(url) => url,
                    Err(_) => {
                        return on_mint_failure(
                            || self.check(&check),
                            || self.verification_required(String::new()),
                        );
                    }
                };
                if !url.is_empty() {
                    return Ok(self.verification_required(url));
                }
                let state = self.scope.lock().expect("signed session coordinator lock");
                record = self.load()?;
                if !record.usable(self.registry.auth.now()) || state.blocked(&record) {
                    return Err(error.into());
                }
            } else if state.blocked(&record) {
                drop(state);
                let url = match self.bootstrap(&check) {
                    Ok(url) => url,
                    Err(_) => {
                        return on_mint_failure(
                            || self.check(&check),
                            || self.verification_required(String::new()),
                        );
                    }
                };
                if !url.is_empty() {
                    return Ok(self.verification_required(url));
                }
                let state = self.scope.lock().expect("signed session coordinator lock");
                record = self.load()?;
                if !record.usable(self.registry.auth.now()) || state.blocked(&record) {
                    return on_mint_failure(
                        || self.check(&check),
                        || self.verification_required(String::new()),
                    );
                }
            }
            record
        };
        if record.refresh_due(&self.config, self.registry.auth.now()) {
            let _ = self.refresh(&check);
            self.check(&check)?;
            let state = self.scope.lock().expect("signed session coordinator lock");
            let latest = self.load()?;
            record = if !latest.usable(self.registry.auth.now()) || state.blocked(&latest) {
                drop(state);
                let url = self.bootstrap(&check)?;
                if !url.is_empty() {
                    return Ok(self.verification_required(url));
                }
                let state = self.scope.lock().expect("signed session coordinator lock");
                let bootstrapped = self.load()?;
                if !bootstrapped.usable(self.registry.auth.now()) || state.blocked(&bootstrapped) {
                    return Err("signed session is not authenticated".into());
                }
                bootstrapped
            } else {
                latest
            };
        }
        let mut session_retries = 0;
        let mut provider_retries = 0;
        let mut request_auth_retry = false;
        loop {
            let response = match self.signed_request(&record, &method, path, body, headers, &check) {
                Ok(response) => response,
                Err(error) if error == super::coordinator::SUPERSEDED_BEFORE_SEND => {
                    // No HTTP request was sent for the stale snapshot, so this
                    // bounded retry never repeats a request already executed.
                    if session_retries >= 1 { return Err("signed-session retry limit reached".into()); }
                    let state = self.scope.lock().expect("signed session coordinator lock");
                    let latest = self.load()?;
                    if !latest.usable(self.registry.auth.now()) || state.blocked(&latest) {
                        return Err("signed session is no longer eligible".into());
                    }
                    session_retries += 1;
                    record = latest;
                    continue;
                }
                Err(error) => return Err(error),
            };
            let contract = ErrorContract::parse(&response.body);
            if contract.provider_retry(response.status) {
                if provider_retries >= 2 {
                    return Ok(protocol::response_value(response, self.registry.auth.now()));
                }
                provider_retries += 1;
                self.wait(
                    protocol::provider_delay(&response, &contract, self.registry.auth.now()),
                    &check,
                )?;
                continue;
            }
            if contract.request_auth_invalid(response.status) {
                let _state = self.scope.lock().expect("signed session coordinator lock");
                let latest = self.load()?;
                if !request_auth_retry
                    && latest.usable(self.registry.auth.now())
                    && !latest.same_session(&record)
                {
                    request_auth_retry = true;
                    record = latest;
                    continue;
                }
                return Ok(protocol::response_value(response, self.registry.auth.now()));
            }
            let action = contract.gateway_action(response.status);
            if action.is_empty() {
                return Ok(protocol::response_value(response, self.registry.auth.now()));
            }
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let mut latest = self.load()?;
            if latest.usable(self.registry.auth.now()) && !latest.same_session(&record) {
                if session_retries >= 1 {
                    return Err("signed-session retry limit reached".into());
                }
                session_retries += 1;
                record = latest;
                continue;
            }
            if action == "bootstrap_session" && latest.same_session(&record) {
                state.blocked_generation.clear();
                latest.clear();
                self.store.save(&latest)?;
            } else if action == "verify" && latest.same_session(&record) {
                state.blocked_generation = record.generation();
            }
            drop(state);
            let url = self.bootstrap(&check)?;
            if !url.is_empty() {
                return Ok(self.verification_required(url));
            }
            let _state = self.scope.lock().expect("signed session coordinator lock");
            let bootstrapped = self.load()?;
            if bootstrapped.usable(self.registry.auth.now())
                && !bootstrapped.same_session(&record)
                && session_retries < 1
            {
                session_retries += 1;
                record = bootstrapped;
                continue;
            }
            return Ok(protocol::response_value(response, self.registry.auth.now()));
        }
    }
}

fn on_mint_failure<T>(
    recheck: impl FnOnce() -> Result<(), String>,
    verification: impl FnOnce() -> T,
) -> Result<T, String> {
    recheck()?;
    Ok(verification())
}

#[cfg(test)]
mod signed_session_mint_tests {
    use super::on_mint_failure;
    use crate::auth::{AuthClock, AuthRegistry};
    use crate::manifest::SignedSession;
    use crate::signed_session::SignedRegistry;
    use mornye_network::{NetworkOptions, NetworkService};
    use std::cell::Cell;
    use std::collections::BTreeMap;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    #[test]
    fn mint_failure_becomes_verification_required() {
        let out = on_mint_failure(|| Ok(()), || serde_json::json!({"needsVerification": true}));
        assert_eq!(out.unwrap()["needsVerification"], true);
    }

    #[test]
    fn mint_failure_propagates_cancellation() {
        let out = on_mint_failure(|| Err("download cancelled".to_string()), || 1);
        assert_eq!(out.unwrap_err(), "download cancelled");
    }

    #[test]
    fn signed_fetch_bootstraps_first_install_without_challenge() {
        refresh_fixture(RefreshScenario::FirstInstall);
    }

    #[test]
    fn signed_fetch_renews_session_before_expiry_without_challenge() {
        refresh_fixture(RefreshScenario::Renewed);
    }

    #[test]
    fn signed_fetch_refreshes_at_exactly_thirty_minutes_remaining() {
        refresh_fixture(RefreshScenario::AtRefreshBoundary);
    }

    #[test]
    fn signed_fetch_skips_refresh_with_more_than_thirty_minutes_remaining() {
        refresh_fixture(RefreshScenario::BeforeRefreshWindow);
    }

    #[test]
    fn signed_fetch_reuses_still_valid_session_after_refresh_503() {
        refresh_fixture(RefreshScenario::RefreshFailureWhileUsable);
    }

    #[test]
    fn signed_fetch_recovers_when_refresh_fails_as_session_expires() {
        refresh_fixture(RefreshScenario::BootstrapSession);
    }

    #[test]
    fn signed_fetch_returns_challenge_when_refresh_fails_as_session_expires() {
        refresh_fixture(RefreshScenario::BootstrapChallenge);
    }

    #[derive(Clone, Copy)]
    enum RefreshScenario {
        FirstInstall,
        Renewed,
        AtRefreshBoundary,
        BeforeRefreshWindow,
        RefreshFailureWhileUsable,
        BootstrapSession,
        BootstrapChallenge,
    }

    fn refresh_fixture(scenario: RefreshScenario) {
        struct Clock(AtomicBool);
        impl AuthClock for Clock {
            fn now_nanos(&self) -> i128 {
                let time = if self.0.load(Ordering::Acquire) {
                    "2026-01-01T00:02:00Z"
                } else {
                    "2026-01-01T00:00:00Z"
                };
                super::protocol::parse_time(time).unwrap()
            }
        }

        let directory = tempfile::tempdir().unwrap();
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let server_config = Arc::new(
            rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(
                    certificate.signing_key.serialize_der(),
                )
                .into(),
            )
            .unwrap(),
        );
        let network = NetworkService::with_options(NetworkOptions {
            extra_root_pem: certificate.cert.pem().into_bytes(),
            doh_upstreams: vec![],
            ..Default::default()
        })
        .unwrap();
        network.set_allow_private_network(true);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base_url = format!("https://{}", listener.local_addr().unwrap());
        let clock = Arc::new(Clock(AtomicBool::new(false)));
        let auth = Arc::new(AuthRegistry::with_clock(clock.clone()));
        let registry = SignedRegistry::new(directory.path(), auth);
        let mut config = SignedSession {
            namespace: "example-session".into(),
            base_url,
            app_version: "fixture-app".into(),
            callback_url: "mornye://session-grant".into(),
            ..Default::default()
        };
        config.endpoints.refresh = "/refresh".into();
        config.endpoints.bootstrap = "/bootstrap".into();
        let client = registry
            .session(
                "example.session",
                config,
                network.native_session(Duration::from_secs(2)),
            )
            .unwrap();
        let old_expiry = match scenario {
            RefreshScenario::AtRefreshBoundary => "2026-01-01T00:30:00Z",
            RefreshScenario::BeforeRefreshWindow => "2026-01-01T00:30:01Z",
            _ => "2026-01-01T00:01:00Z",
        };
        let reuses_session = matches!(
            scenario,
            RefreshScenario::BeforeRefreshWindow | RefreshScenario::RefreshFailureWhileUsable
        );
        if !matches!(scenario, RefreshScenario::FirstInstall) {
            let mut record = client.load().unwrap();
            record.session_id = "old-session".into();
            record.session_secret = "fixture-secret".into();
            record.expires_at = old_expiry.into();
            client.store.save(&record).unwrap();
        }

        const CHALLENGE_URL: &str = "https://example.invalid/verify?state=fixture-state";
        const NEW_EXPIRY: &str = "2026-01-02T00:00:00Z";
        let renewed = serde_json::json!({
            "session_id": "new-session",
            "session_secret": "new-fixture-secret",
            "expires_at": NEW_EXPIRY
        });
        let server = std::thread::spawn(move || {
            let mut steps = match scenario {
                RefreshScenario::FirstInstall => {
                    vec![("GET /bootstrap?", "200 OK", renewed.to_string())]
                }
                RefreshScenario::Renewed | RefreshScenario::AtRefreshBoundary => {
                    vec![("POST /refresh ", "200 OK", renewed.to_string())]
                }
                RefreshScenario::BeforeRefreshWindow => vec![],
                RefreshScenario::RefreshFailureWhileUsable => {
                    vec![("POST /refresh ", "503 Service Unavailable", "{}".into())]
                }
                RefreshScenario::BootstrapSession | RefreshScenario::BootstrapChallenge => {
                    let bootstrap = if matches!(scenario, RefreshScenario::BootstrapChallenge) {
                        serde_json::json!({"auth_url": CHALLENGE_URL})
                    } else {
                        renewed
                    };
                    vec![
                        ("POST /refresh ", "503 Service Unavailable", "{}".into()),
                        ("GET /bootstrap?", "200 OK", bootstrap.to_string()),
                    ]
                }
            };
            if !matches!(scenario, RefreshScenario::BootstrapChallenge) {
                steps.push(("GET /track ", "200 OK", r#"{"track":"fixture"}"#.into()));
            }
            for (path, status, body) in steps {
                let deadline = Instant::now() + Duration::from_secs(3);
                let stream = loop {
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            if Instant::now() >= deadline {
                                return false;
                            }
                            std::thread::sleep(Duration::from_millis(1));
                        }
                        Err(error) => panic!("session fixture accept: {error}"),
                    }
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut tls = rustls::StreamOwned::new(
                    rustls::ServerConnection::new(Arc::clone(&server_config)).unwrap(),
                    stream,
                );
                let mut line = String::new();
                let mut request = BufReader::new(&mut tls);
                request.read_line(&mut line).unwrap();
                assert!(line.starts_with(path), "{line}");
                if matches!(scenario, RefreshScenario::FirstInstall) && path == "GET /bootstrap?" {
                    let query = line
                        .split_whitespace()
                        .nth(1)
                        .unwrap()
                        .strip_prefix("/bootstrap?")
                        .unwrap();
                    assert!(
                        query
                            .split('&')
                            .any(|pair| pair == "app_version=fixture-app")
                    );
                    assert!(query.split('&').any(|pair| {
                        pair.strip_prefix("install_id=")
                            .is_some_and(|id| !id.is_empty())
                    }));
                    loop {
                        line.clear();
                        assert_ne!(request.read_line(&mut line).unwrap(), 0);
                        if line == "\r\n" {
                            break;
                        }
                        let (name, _) = line.split_once(':').unwrap();
                        assert!(!name.eq_ignore_ascii_case("authorization"));
                        assert!(!name.to_ascii_lowercase().starts_with("x-sig-"));
                    }
                }
                if let Some(expected_session) = match path {
                    "POST /refresh " => Some("old-session"),
                    "GET /track " if reuses_session => Some("old-session"),
                    "GET /track " => Some("new-session"),
                    _ => None,
                } {
                    let mut saw_session = false;
                    let mut saw_signature = false;
                    loop {
                        line.clear();
                        assert_ne!(request.read_line(&mut line).unwrap(), 0);
                        if line == "\r\n" {
                            break;
                        }
                        if let Some((name, value)) = line.split_once(':') {
                            if name.eq_ignore_ascii_case("X-Sig-Session") {
                                assert!(
                                    value.trim() == expected_session,
                                    "unexpected fixture session"
                                );
                                saw_session = true;
                            }
                            if name.eq_ignore_ascii_case("X-Sig-Signature") {
                                saw_signature = !value.trim().is_empty();
                            }
                        }
                    }
                    assert!(saw_session, "missing fixture session header");
                    assert!(saw_signature, "missing fixture signature header");
                }
                if status.starts_with("503") && !reuses_session {
                    clock.0.store(true, Ordering::Release);
                }
                write!(
                    tls,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            true
        });
        let result = client.signed_fetch("GET", "/track", "", &BTreeMap::new(), || Ok(()));
        let saw_all_requests = server.join().unwrap();
        let result = result.unwrap();
        assert!(saw_all_requests);
        if matches!(scenario, RefreshScenario::BootstrapChallenge) {
            assert_eq!(result["needsVerification"], true);
            assert_eq!(result["auth_url"], CHALLENGE_URL);
        } else {
            assert_eq!(result["ok"], true);
            assert_eq!(result["body"], r#"{"track":"fixture"}"#);
            assert!(client.take_verification_url().is_empty());
            assert!(registry.auth.pending("example.session").is_none());
            let persisted = client.load().unwrap();
            if reuses_session {
                assert_eq!(persisted.expires_at, old_expiry);
                assert_eq!(persisted.session_id, "old-session");
                assert_eq!(persisted.session_secret, "fixture-secret");
            } else {
                assert_eq!(persisted.expires_at, NEW_EXPIRY);
                assert_eq!(persisted.session_id, "new-session");
                assert_eq!(persisted.session_secret, "new-fixture-secret");
            }
            assert!(persisted.usable(registry.auth.now()));
        }
    }

    #[test]
    fn signed_fetch_reuses_session_saved_during_bootstrap() {
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry
            .session(
                "example.session",
                SignedSession {
                    namespace: "example-session".into(),
                    base_url: "https://127.0.0.1".into(),
                    ..Default::default()
                },
                network.native_session(Duration::from_secs(2)),
            )
            .unwrap();
        let checks = Cell::new(0);
        let result = client.signed_fetch("GET", "", "", &BTreeMap::new(), || {
            checks.set(checks.get() + 1);
            if checks.get() == 2 {
                // Simulate a grant exchange finishing after the initial read
                // and before bootstrap acquires the scope lock.
                let _scope = client.scope.lock().unwrap();
                let mut record = client.load().unwrap();
                record.session_id = "fixture-session".into();
                record.session_secret = "fixture-secret".into();
                record.expires_at = "2099-01-01T00:00:00Z".into();
                client.store.save(&record).unwrap();
            }
            Ok(())
        });
        // The request should reach endpoint validation without doing any I/O
        // against the network or returning the stale unauthenticated error.
        assert_eq!(result.unwrap_err(), "signed session endpoint is empty");
    }

    #[test]
    fn signed_fetch_preserves_verification_for_missing_expired_and_blocked_sessions() {
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry
            .session(
                "example.session",
                SignedSession {
                    namespace: "example-session".into(),
                    base_url: "https://127.0.0.1".into(),
                    ..Default::default()
                },
                network.native_session(Duration::from_secs(2)),
            )
            .unwrap();
        // Private network access stays denied, so bootstrap fails without
        // contacting a real gateway or depending on an external service.
        for state in ["missing", "expired", "blocked"] {
            let mut record = client.load().unwrap();
            if state != "missing" {
                record.session_id = "example-session-id".into();
                record.session_secret = "example-session-secret".into();
                record.expires_at = if state == "expired" {
                    "2000-01-01T00:00:00Z"
                } else {
                    "2099-01-01T00:00:00Z"
                }
                .into();
                client.store.save(&record).unwrap();
            }
            if state == "blocked" {
                client.scope.lock().unwrap().blocked_generation = record.generation();
            }
            let result = client
                .signed_fetch("GET", "/track", "", &BTreeMap::new(), || Ok(()))
                .unwrap();
            assert_eq!(result["ok"], false, "{state}");
            assert_eq!(result["needsVerification"], true, "{state}");
            assert_eq!(result["error"], "VERIFY_REQUIRED", "{state}");
            assert_eq!(result["auth_url"], "", "{state}");
            assert_eq!(result["open_auth_url"], "", "{state}");
            assert!(client.take_verification_url().is_empty());
        }
    }

    const EXPIRY_NOW: &str = "2026-01-01T00:00:00Z";

    /// Synthetic client with a fixed clock at `EXPIRY_NOW` and a stored record
    /// whose only variable is `expires_at`. No network is contacted: the fetch
    /// path is driven with an empty path so it stops at endpoint validation.
    fn expiry_fixture(
        expires_at: &str,
    ) -> (tempfile::TempDir, Arc<crate::signed_session::SignedSessionClient>, i128) {
        struct Fixed;
        impl AuthClock for Fixed {
            fn now_nanos(&self) -> i128 {
                super::protocol::parse_time(EXPIRY_NOW).unwrap()
            }
        }
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let auth = Arc::new(AuthRegistry::with_clock(Arc::new(Fixed)));
        let registry = SignedRegistry::new(directory.path(), auth);
        let mut config = SignedSession {
            namespace: "example-session".into(),
            base_url: "https://127.0.0.1".into(),
            ..Default::default()
        };
        config.endpoints.refresh = "/refresh".into();
        let client = registry
            .session("example.session", config, network.native_session(Duration::from_secs(1)))
            .unwrap();
        let mut record = client.load().unwrap();
        record.session_id = "synthetic-session".into();
        record.session_secret = "synthetic-secret".into();
        record.expires_at = expires_at.into();
        client.store.save(&record).unwrap();
        let now = super::protocol::parse_time(EXPIRY_NOW).unwrap();
        (directory, client, now)
    }

    /// CHARACTERIZATION (passes today): pins the current, inconsistent handling
    /// of a missing / unparseable / exactly-now `expires_at`. See the ignored
    /// test below for the consistent behavior this contradicts.
    ///
    /// | expires_at | usable | signed_fetch                | renew_existing |
    /// |------------|--------|-----------------------------|----------------|
    /// | ""         | true   | signs (not expired)         | "invalid"      |
    /// | "garbage"  | true   | signs (not expired)         | "invalid"      |
    /// | == now     | false  | signs (not cleared/verified)| "invalid"      |
    ///
    /// `usable` treats an unparseable expiry as valid (`is_none_or`), `signed_fetch`
    /// only expires when `now > expires` (strict) and otherwise proceeds even if
    /// `usable` is false, while renewal requires a parseable `expires > now`.
    /// Credentials are preserved in every case.
    #[test]
    fn session_expiry_edge_cases_are_currently_inconsistent_across_usable_fetch_and_renewal() {
        for (expires_at, expect_usable) in [("", true), ("not-a-time", true), (EXPIRY_NOW, false)] {
            let (_directory, client, now) = expiry_fixture(expires_at);
            let record = client.load().unwrap();
            assert_eq!(record.usable(now), expect_usable, "usable: {expires_at:?}");

            // Reaching endpoint validation proves fetch neither cleared the
            // session nor demanded verification for this record.
            let fetched = client.signed_fetch("GET", "", "", &BTreeMap::new(), || Ok(()));
            assert_eq!(
                fetched.unwrap_err(),
                "signed session endpoint is empty",
                "fetch: {expires_at:?}"
            );

            assert_eq!(
                client.renew_existing(true, || Ok(())).unwrap().status,
                "invalid",
                "renewal: {expires_at:?}"
            );

            let latest = client.load().unwrap();
            assert_eq!(latest.session_id, "synthetic-session", "{expires_at:?}");
            assert_eq!(latest.session_secret, "synthetic-secret", "{expires_at:?}");
            assert_eq!(latest.expires_at, expires_at, "{expires_at:?}");
        }
    }

    /// DEFECT DEMONSTRATION (fails today, therefore `#[ignore]`): `usable` should
    /// agree with the rule renewal applies (`expires` parseable and `> now`).
    /// Fails for "" and "not-a-time" (usable = true). Run explicitly with
    /// `-- --ignored`; remove `#[ignore]` once production is aligned.
    #[test]
    #[ignore = "documents defect: usable() accepts missing/unparseable expires_at, renewal rejects it"]
    fn usable_should_agree_with_renewal_on_missing_unparseable_and_exact_expiry() {
        for expires_at in ["", "not-a-time", EXPIRY_NOW] {
            let (_directory, client, now) = expiry_fixture(expires_at);
            let record = client.load().unwrap();
            let renewal_rule = super::protocol::parse_time(expires_at).is_some_and(|e| e > now);
            assert_eq!(record.usable(now), renewal_rule, "expires_at: {expires_at:?}");
        }
    }

    #[test]
    fn signed_fetch_does_not_turn_in_flight_cancellation_into_verification() {
        let directory = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base_url = format!("https://{}", listener.local_addr().unwrap());
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = Arc::clone(&cancelled);
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                match listener.accept() {
                    Ok((stream, _)) => {
                        cancel.store(true, Ordering::Release);
                        drop(stream);
                        return;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("session fixture accept: {error}"),
                }
            }
            panic!("bootstrap did not contact the session fixture");
        });
        let network = NetworkService::new().unwrap();
        network.set_allow_private_network(true);
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry
            .session(
                "example.session",
                SignedSession {
                    namespace: "example-session".into(),
                    base_url,
                    ..Default::default()
                },
                network.native_session(Duration::from_secs(2)),
            )
            .unwrap();
        let result = client.signed_fetch("GET", "/track", "", &BTreeMap::new(), || {
            if cancelled.load(Ordering::Acquire) {
                Err("download cancelled".into())
            } else {
                Ok(())
            }
        });
        server.join().unwrap();
        assert_eq!(result.unwrap_err(), "download cancelled");
    }
}
