//! Signed session coordination: shared in-flight requests and per-session challenge state.

use super::{RecordStore, RuntimeHints, protocol};
use crate::auth::{AuthRegistry, PendingAuthRequest};
use crate::manifest::SignedSession;
use mornye_network::{HttpRequest, HttpResponse, NetworkSession};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

pub(super) const SUPERSEDED_BEFORE_SEND: &str = "signed session superseded before request";

pub(super) type Check<'a> = &'a dyn Fn() -> Result<(), String>;

#[derive(Default)]
pub(super) struct Flight {
    result: Mutex<Option<Result<(), String>>>,
    done: Condvar,
}

impl Flight {
    pub fn finish(&self, result: Result<(), String>) {
        *self.result.lock().expect("signed session flight lock") = Some(result);
        self.done.notify_all();
    }

    pub fn wait(&self, check: Check<'_>) -> Result<(), String> {
        let mut result = self.result.lock().expect("signed session flight lock");
        loop {
            check()?;
            if let Some(result) = &*result {
                return result.clone();
            }
            result = self
                .done
                .wait_timeout(result, Duration::from_millis(10))
                .expect("signed session flight wait")
                .0;
        }
    }
}

#[derive(Default)]
pub(super) struct State {
    pub clear_generation: u64,
    pub requests: BTreeMap<String, usize>,
    pub tainted: BTreeSet<String>,
    pub dirty_owned: BTreeSet<String>,
    pub completed_grant: String,
    pub blocked_generation: String,
    pub challenge: Option<PendingAuthRequest>,
    pub pending_ids: BTreeSet<String>,
    pub bootstrap: Option<Arc<Flight>>,
    pub refresh: Option<Arc<Flight>>,
    pub exchange: Option<Arc<Flight>>,
}

impl State {
    pub fn blocked(&self, record: &protocol::Record) -> bool {
        let generation = record.generation();
        record.renewal_blocked() || (!generation.is_empty() && self.blocked_generation == generation)
    }

    pub fn clear_challenge(&mut self, auth: &AuthRegistry) {
        for id in &self.pending_ids {
            auth.clear_pending(id);
        }
        self.pending_ids.clear();
        self.challenge = None;
    }

    pub fn remember(&mut self, pending: PendingAuthRequest) {
        self.pending_ids.insert(pending.extension_id.clone());
        self.challenge = Some(pending);
    }
}

pub struct SignedRegistry {
    root: PathBuf,
    master_key: Option<Arc<crate::storage::StorageMasterKey>>,
    pub(super) auth: Arc<AuthRegistry>,
    hints: Mutex<RuntimeHints>,
    scopes: Mutex<BTreeMap<PathBuf, Arc<Mutex<State>>>>,
    pub(super) grants: Mutex<BTreeMap<String, Arc<VerificationGrant>>>,
    closed: AtomicBool,
}

pub(crate) struct VerificationGrant {
    pub(crate) value: Zeroizing<String>,
    pub(crate) verification_id: Option<String>,
}

impl SignedRegistry {
    pub fn new(root: &Path, auth: Arc<AuthRegistry>) -> Arc<Self> {
        #[cfg(test)]
        let key = Some(Arc::new(
            crate::storage::StorageMasterKey::from_base64(
                "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=",
            )
            .expect("test key"),
        ));
        #[cfg(not(test))]
        let key = None;
        Self::with_key(root, auth, key)
    }

    pub fn with_key(
        root: &Path,
        auth: Arc<AuthRegistry>,
        master_key: Option<Arc<crate::storage::StorageMasterKey>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            root: root.to_owned(),
            master_key,
            auth,
            hints: Mutex::default(),
            scopes: Mutex::default(),
            grants: Mutex::default(),
            closed: AtomicBool::new(false),
        })
    }

    pub fn set_runtime_state(&self, raw: &str) -> Result<(), String> {
        self.check()?;
        *self.hints.lock().expect("session hints lock") = RuntimeHints::parse(raw);
        Ok(())
    }

    pub fn set_grant(&self, id: &str, grant: &str) -> Result<(), String> {
        self.select_grant(id, grant).map(|_| ())
    }

    pub(super) fn select_grant(
        &self,
        id: &str,
        grant: &str,
    ) -> Result<Option<Arc<VerificationGrant>>, String> {
        let id = id.trim();
        let grant = grant.trim();
        let replacement = (!id.is_empty() && !grant.is_empty()).then(|| {
            Arc::new(VerificationGrant {
                value: Zeroizing::new(grant.to_owned()),
                verification_id: self.auth.pending(id).map(|pending| pending.verification_id),
            })
        });
        let mut grants = self.grants.lock().expect("session grants lock");
        self.check()?;
        if let Some(grant) = replacement {
            grants.insert(id.to_owned(), Arc::clone(&grant));
            Ok(Some(grant))
        } else {
            Ok(grants.get(id).cloned())
        }
    }

    pub fn session(
        self: &Arc<Self>,
        id: &str,
        config: SignedSession,
        network: Arc<NetworkSession>,
    ) -> Result<Arc<SignedSessionClient>, String> {
        self.check()?;
        let config = protocol::defaults(config);
        let store = RecordStore::open_with_key(&self.root, &config, self.master_key.clone())?;
        let mut scopes = self.scopes.lock().expect("signed session scopes lock");
        self.check()?;
        let scope = Arc::clone(scopes.entry(store.path().to_owned()).or_default());
        Ok(Arc::new(SignedSessionClient {
            id: id.to_owned(),
            registry: Arc::clone(self),
            config,
            store,
            scope,
            network,
            verification_url: Mutex::new(String::new()),
        }))
    }

    /// Builds a client for an existing scope without touching disk or bootstrap.
    /// The caller supplies an already authenticated platform key and manifest.
    pub fn existing_session(
        self: &Arc<Self>,
        id: &str,
        config: SignedSession,
        network: Arc<NetworkSession>,
    ) -> Result<Option<Arc<SignedSessionClient>>, String> {
        self.check()?;
        let config = protocol::defaults(config);
        let Some(store) = RecordStore::open_existing_with_key(&self.root, &config, self.master_key.clone())? else {
            return Ok(None);
        };
        let mut scopes = self.scopes.lock().expect("signed session scopes lock");
        self.check()?;
        let scope = Arc::clone(scopes.entry(store.path().to_owned()).or_default());
        Ok(Some(Arc::new(SignedSessionClient {
            id: id.to_owned(), registry: Arc::clone(self), config, store, scope, network,
            verification_url: Mutex::new(String::new()),
        })))
    }

    pub(super) fn check(&self) -> Result<(), String> {
        if self.closed.load(Ordering::Acquire) {
            Err("extension environment closed".into())
        } else {
            Ok(())
        }
    }

    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        self.grants.lock().expect("session grants lock").clear();
        for state in self
            .scopes
            .lock()
            .expect("signed session scopes lock")
            .values()
        {
            state
                .lock()
                .expect("signed session coordinator lock")
                .clear_challenge(&self.auth);
        }
    }

    pub(crate) fn forget_extension(&self, id: &str) {
        self.grants.lock().expect("session grants lock").remove(id);
        // Session records can be shared by multiple extensions through their
        // manifest namespace. Only remove this extension's pending challenge.
        for scope in self
            .scopes
            .lock()
            .expect("signed session scopes lock")
            .values()
        {
            let mut state = scope.lock().expect("signed session coordinator lock");
            state.pending_ids.remove(id);
            if state
                .challenge
                .as_ref()
                .is_some_and(|pending| pending.extension_id == id)
            {
                state.challenge = None;
            }
        }
    }
}

pub struct SignedSessionClient {
    pub(super) id: String,
    pub(super) registry: Arc<SignedRegistry>,
    pub(super) config: SignedSession,
    pub(super) store: RecordStore,
    pub(super) scope: Arc<Mutex<State>>,
    pub(super) network: Arc<NetworkSession>,
    verification_url: Mutex<String>,
}

impl SignedSessionClient {
    pub(super) fn check(&self, check: Check<'_>) -> Result<(), String> {
        self.registry.check()?;
        check()
    }

    pub(super) fn load(&self) -> Result<protocol::Record, String> {
        self.store
            .load(&self.registry.hints.lock().expect("session hints lock"))
    }

    pub fn status(&self) -> Result<Value, String> {
        self.registry.check()?;
        let state = self.scope.lock().expect("signed session coordinator lock");
        let record = self.load()?;
        let blocked = state.blocked(&record);
        Ok(
            json!({"authenticated":record.usable(self.registry.auth.now()) && !blocked, "verification_required":blocked,
            "expires_at":record.expires_at,"install_id":record.install_id,"session_id":record.session_id,
            "app_version":self.config.app_version,"platform":self.config.platform}),
        )
    }

    pub fn clear(&self) -> Result<(), String> {
        self.registry.check()?;
        let mut state = self.scope.lock().expect("signed session coordinator lock");
        let mut record = self.load()?;
        record.clear();
        self.store.save(&record)?;
        state.clear_generation = state.clear_generation.wrapping_add(1);
        state.completed_grant.clear();
        state.blocked_generation.clear();
        state.clear_challenge(&self.registry.auth);
        self.registry.auth.clear_pending(&self.id);
        Ok(())
    }

    pub fn take_verification_url(&self) -> String {
        std::mem::take(
            &mut self
                .verification_url
                .lock()
                .expect("signed session verification URL lock"),
        )
    }

    pub(super) fn verification_required(&self, url: String) -> Value {
        if !url.is_empty() {
            *self
                .verification_url
                .lock()
                .expect("signed session verification URL lock") = url.clone();
        }
        json!({"ok":false,"needsVerification":true,"error":"VERIFY_REQUIRED","open_auth_url":url,"auth_url":url})
    }

    pub(super) fn request(
        &self,
        method: &str,
        url: String,
        body: String,
        mut headers: BTreeMap<String, String>,
        check: Check<'_>,
    ) -> Result<HttpResponse, String> {
        self.check(check)?;
        // Header matching is case-insensitive on the wire. Normalize before
        // applying extension overrides so a lowercase override cannot coexist.
        headers = headers
            .into_iter()
            .map(|(key, value)| (key.to_ascii_lowercase(), value))
            .collect();
        headers
            .entry("accept".into())
            .or_insert_with(|| "application/json".into());
        self.network.request(
            HttpRequest {
                url,
                method: method.into(),
                body,
                headers,
                default_json: false,
                user_agent: format!("Mornye/{}", self.config.app_version),
            },
            || self.check(check),
        )
    }

    pub(super) fn signed_request(
        &self,
        record: &protocol::Record,
        method: &str,
        path: &str,
        body: &str,
        extras: &BTreeMap<String, String>,
        check: Check<'_>,
    ) -> Result<HttpResponse, String> {
        self.signed_request_with_lease(record, method, path, body, extras, check, None)
    }

    pub(super) fn save_with_lease(&self, record: &protocol::Record, lease: Option<&mornye_core::cancellation::RequestLease>) -> Result<(), String> {
        if let Some(lease) = lease {
            lease.check_active().map_err(|_| "session renewal cancelled")?;
            self.store.prepare_save(record)?.commit_with_lease(lease)
        } else { self.store.save(record) }
    }

    pub(super) fn signed_request_with_lease(
        &self, record: &protocol::Record, method: &str, path: &str, body: &str,
        extras: &BTreeMap<String, String>, check: Check<'_>,
        lease: Option<&mornye_core::cancellation::RequestLease>,
    ) -> Result<HttpResponse, String> {
        let url = protocol::endpoint(&self.config, path)?;
        let mut headers: BTreeMap<_, _> = protocol::signed_headers(
            &self.config,
            record,
            method,
            &url,
            body.as_bytes(),
            self.registry.auth.now(),
            &protocol::random_hex(12)?,
        )?
        .into_iter()
        .map(|(key, value)| (key.to_ascii_lowercase(), value))
        .collect();
        if !body.is_empty() {
            headers.insert("content-type".into(), "application/json".into());
        }
        for (key, value) in extras {
            headers.insert(key.to_ascii_lowercase(), value.clone());
        }
        let generation = record.generation();
        {
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            self.check(check)?;
            let mut latest = if lease.is_some() { self.store.load_existing()?.ok_or("signed session disappeared")? } else { self.load()? };
            if !latest.same_session(record) {
                return Err(SUPERSEDED_BEFORE_SEND.into());
            }
            if state.blocked(&latest) { return Err("signed session generation is no longer eligible".into()); }
            // A dirty/unknown guard with no live request accounting came from
            // an older process or an unproven record. A successful fetch alone
            // cannot discharge that uncertainty; require explicit establishment.
            if state.requests.is_empty() && !latest.renewal_allowed() && !state.dirty_owned.contains(&latest.generation()) {
                state.tainted.insert(generation.clone());
            }
            // Pessimistic durable invalidation BEFORE any request can reveal verify.
            // Failure here means no network request is sent.
            latest.mark_renewal("dirty");
            self.save_with_lease(&latest, lease)?;
            state.dirty_owned.insert(generation.clone());
            *state.requests.entry(generation.clone()).or_default() += 1;
        }
        let response = self.request(method, url, body.into(), headers, check);
        let mut state = self.scope.lock().expect("signed session coordinator lock");
        let remaining = state.requests.get_mut(&generation).expect("signed request count");
        *remaining -= 1;
        let last = *remaining == 0;
        if last { state.requests.remove(&generation); }
        let action = response.as_ref().ok().map(|response| protocol::ErrorContract::parse(&response.body).gateway_action(response.status).to_owned());
        if response.is_err() || action.as_deref().is_some_and(|action| !action.is_empty()) {
            state.tainted.insert(generation.clone());
        }
        let mut latest = if lease.is_some() { self.store.load_existing()?.ok_or("signed session disappeared")? } else { self.load()? };
        if latest.same_session(record) && action.as_deref() == Some("verify") {
            state.blocked_generation = generation.clone();
            latest.mark_renewal("blocked");
            // Failed persistence still leaves the pre-request dirty guard.
            self.save_with_lease(&latest, lease)?;
        } else if state.requests.is_empty() && state.tainted.is_empty()
            && !state.blocked(&latest) && latest.usable(self.registry.auth.now())
            && (latest.same_session(record) || state.dirty_owned.contains(&latest.generation())) {
            // Clean drain may be completed by an ancestor generation after a
            // successful refresh rotation. Only process-owned dirty lineage can
            // recover; an orphan dirty guard was tainted at request admission.
            self.check(check)?;
            latest.mark_renewal("allowed");
            self.save_with_lease(&latest, lease)?;
        }
        response
    }

    pub(super) fn wait(&self, delay: Duration, check: Check<'_>) -> Result<(), String> {
        let end = Instant::now() + delay;
        loop {
            self.check(check)?;
            let Some(remaining) = end.checked_duration_since(Instant::now()) else {
                return Ok(());
            };
            std::thread::sleep(remaining.min(Duration::from_millis(10)));
        }
    }
}
