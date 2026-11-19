//! Extension manager download support: request types, preflight checks, and the download engine pool.

use super::*;
use serde::Deserialize;
use zeroize::Zeroize;

/// Owns parsed provider data across all early returns. Never Debug/Serialize.
#[derive(Deserialize)]
#[serde(transparent)]
struct DownloadValue(Value);

fn wipe(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(values) => values.iter_mut().for_each(wipe),
        Value::Object(values) => values.values_mut().for_each(wipe),
        _ => (),
    }
}

impl Drop for DownloadValue {
    fn drop(&mut self) {
        wipe(&mut self.0);
    }
}

#[cfg(feature = "experimental-private-mov")]
pub(crate) struct PrivateDecryption(DownloadValue);

#[cfg(feature = "experimental-private-mov")]
impl PrivateDecryption {
    pub(crate) fn into_mov_key(self) -> Result<zeroize::Zeroizing<Vec<u8>>, ()> {
        let text = |name| {
            self.0
                .0
                .get(name)
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
        };
        if !matches!(text("strategy"), "" | "ffmpeg.mov_key")
            || !matches!(text("input_format"), "" | "mov" | "mp4")
            || !matches!(text("output_extension"), "" | ".flac" | "flac")
        {
            return Err(());
        }
        let key = text("key");
        if key.len() != 32 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(());
        }
        crate::binary::decode_string(key, "hex")
            .map(zeroize::Zeroizing::new)
            .map_err(|_| ())
    }
}

/// Internal ownership transfer, deliberately not serializable or printable.
#[cfg(feature = "experimental-private-mov")]
pub(crate) struct PrivateDownloadResult {
    pub(crate) metadata: Value,
    pub(crate) decryption: Option<PrivateDecryption>,
}

#[cfg(feature = "experimental-private-mov")]
fn adopt_private(mut value: DownloadValue) -> PrivateDownloadResult {
    let object = value.0.as_object_mut().expect("validated provider object");
    let mut descriptor = DownloadValue(object.remove("decryption").unwrap_or(Value::Null));
    let mut legacy = DownloadValue(object.remove("decryption_key").unwrap_or(Value::Null));
    let encrypted =
        !descriptor.0.is_null() || legacy.0.as_str().is_some_and(|key| !key.trim().is_empty());
    // Move the legacy string only when needed. Never clone a descriptor/key,
    // normalize it into a second field, or serialize it back to provider JSON.
    if descriptor.0.is_null() && encrypted {
        descriptor.0 = json!({});
    }
    if let Some(info) = descriptor.0.as_object_mut()
        && !info
            .get("key")
            .and_then(Value::as_str)
            .is_some_and(|key| !key.trim().is_empty())
    {
        if let Some(mut previous) = info.insert("key".into(), std::mem::take(&mut legacy.0)) {
            wipe(&mut previous);
        }
    }
    PrivateDownloadResult {
        metadata: std::mem::take(&mut value.0),
        decryption: encrypted.then_some(PrivateDecryption(descriptor)),
    }
}

#[derive(Default)]
pub(super) struct Pool {
    pub active: Vec<Arc<ExtensionRuntime>>,
    idle: Option<Arc<ExtensionRuntime>>,
    generation: u64,
    settings: Option<Map<String, Value>>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
pub struct ProviderDownloadRequest {
    pub track_id: String,
    pub quality: String,
    pub output_path: String,
    pub item_id: String,
    pub prepared_context: Option<Map<String, Value>>,
}

struct Borrowed<'a> {
    manager: &'a ExtensionManager,
    entry: Arc<Installed>,
    runtime: Arc<ExtensionRuntime>,
    generation: u64,
    healthy: bool,
    retire_without_hooks: bool,
}

impl Drop for Borrowed<'_> {
    fn drop(&mut self) {
        // Private results can leave key material in the JS heap. Retire that
        // worker without invoking more extension lifecycle code or pooling it.
        // This bounds context lifetime; QuickJS does not guarantee heap erasure.
        if self.retire_without_hooks {
            self.runtime.shutdown();
        }
        let mut pool = self.entry.downloads.lock().expect("download pool lock");
        // Environment settings access may create an absent store. Check manager
        // ownership first so a late borrower cannot resurrect uninstalled data.
        let reusable = self.healthy
            && !self.runtime.is_closed()
            && self.manager.current(&self.entry)
            && self
                .entry
                .status
                .read()
                .expect("extension status lock")
                .enabled;
        let settings_match = reusable
            && self
                .manager
                .environment
                .settings(&self.entry.manifest.name)
                .is_ok_and(|mut settings| {
                    settings.retain(|key, _| !key.starts_with('_'));
                    pool.settings.as_ref() == Some(&settings)
                });
        pool.active
            .retain(|runtime| !Arc::ptr_eq(runtime, &self.runtime));
        if reusable && pool.generation == self.generation && pool.idle.is_none() && settings_match {
            pool.idle = Some(Arc::clone(&self.runtime));
        } else if !self.runtime.is_closed() {
            self.manager.teardown_runtime(&self.runtime);
        } else {
            self.runtime.shutdown();
        }
    }
}

impl ExtensionManager {
    pub(crate) fn download_manifest(&self, id: &str) -> Result<ExtensionManifest, ManagerError> {
        let entry = self.get(id)?;
        let status = entry.status.read().expect("extension status lock");
        if !status.enabled || !status.error.is_empty() {
            return Err(error(format!("extension '{id}' is unavailable")));
        }
        Ok(entry.manifest.clone())
    }

    /// Extensions may opt into account-owned downloads using a declared setting.
    /// That mode owns authentication and must never enter shared-account fallback.
    pub(crate) fn account_download_enabled(&self, id: &str) -> Result<bool, ManagerError> {
        let Ok(entry) = self.get(id) else {
            self.check()?;
            return Ok(false);
        };
        if !entry
            .manifest
            .capabilities
            .contains_key("accountDownloadMode")
        {
            return Ok(false);
        }
        let settings = self
            .environment
            .settings(&entry.manifest.name)
            .map_err(error_from_environment)?;
        Ok(entry.manifest.account_download_enabled(&settings))
    }

    pub(crate) fn preflight_download(
        &self,
        id: &str,
        lease: Arc<RequestLease>,
    ) -> Result<bool, ManagerError> {
        self.preflight_session(id, lease, true)
            .map(Option::unwrap_or_default)
    }

    /// None when signed-session authentication is inapplicable. Otherwise,
    /// true indicates a pending challenge and false indicates a usable session.
    pub(crate) fn preflight_auth(
        &self,
        id: &str,
        lease: Arc<RequestLease>,
    ) -> Result<Option<bool>, ManagerError> {
        self.preflight_session(id, lease, false)
    }

    fn preflight_session(
        &self,
        id: &str,
        lease: Arc<RequestLease>,
        download_only: bool,
    ) -> Result<Option<bool>, ManagerError> {
        let Ok(entry) = self.get(id) else {
            self.check()?;
            return Ok(None);
        };
        if !entry.status.read().expect("extension status lock").enabled
            || (download_only && !entry.manifest.has_type("download_provider"))
            || entry.manifest.signed_session.is_none()
        {
            return Ok(None);
        }
        if self.account_download_enabled(id)? {
            return Ok(None);
        }
        let runtime = {
            let mut engine = self.download_engine(&entry, Some(&lease))?;
            if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled
            {
                return Err(error("extension is disabled or no longer installed"));
            }
            self.ready_with_lease(&entry, &mut engine, true, Some(lease.clone()))?
        };
        runtime
            .preflight_signed_session(Some(lease), 30_000)
            .map(Some)
            .map_err(|failure| error(failure.to_string()))
    }

    pub(super) fn download_engine<'a>(
        &self,
        entry: &'a Installed,
        lease: Option<&Arc<RequestLease>>,
    ) -> Result<std::sync::MutexGuard<'a, Engine>, ManagerError> {
        loop {
            self.check()?;
            if let Some(lease) = lease {
                lease
                    .check_active()
                    .map_err(|failure| error(failure.to_string()))?;
            }
            match entry.engine.try_lock() {
                Ok(engine) => return Ok(engine),
                Err(std::sync::TryLockError::WouldBlock) => {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err(error("extension engine lock poisoned"));
                }
            }
        }
    }

    pub(super) fn invalidate_download_pool(&self, pool: &mut Pool) -> u64 {
        pool.generation = pool.generation.wrapping_add(1);
        pool.settings = None;
        if let Some(runtime) = pool.idle.take() {
            self.teardown_runtime(&runtime);
            1
        } else {
            0
        }
    }

    /// Memory pressure releases idle heaps. Borrowed workers may finish but
    /// cannot repopulate the pool created before this request.
    pub fn release_idle_download_runtimes(&self) -> Result<u64, ManagerError> {
        self.check()?;
        let entries: Vec<_> = self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .cloned()
            .collect();
        let mut released = 0;
        for entry in entries {
            let mut pool = entry.downloads.lock().expect("download pool lock");
            released += self.invalidate_download_pool(&mut pool);
        }
        Ok(released)
    }

    fn borrow_download(
        &self,
        entry: Arc<Installed>,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<Borrowed<'_>, ManagerError> {
        let mut engine = self.download_engine(&entry, lease.as_ref())?;
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let primary = self.ready_with_lease(&entry, &mut engine, true, lease)?;
        let mut settings = self
            .environment
            .settings(&entry.manifest.name)
            .map_err(error_from_environment)?;
        settings.retain(|key, _| !key.starts_with('_'));
        let mut pool = entry.downloads.lock().expect("download pool lock");
        if pool.settings.as_ref() != Some(&settings) {
            self.invalidate_download_pool(&mut pool);
            pool.settings = Some(settings.clone());
        }
        let idle = pool.idle.take();
        let generation = pool.generation;
        // Initialization runs extension code. Pressure may invalidate this
        // borrow while it initializes, without cancelling the operation.
        drop(pool);
        let runtime = match idle {
            Some(runtime) if !runtime.is_closed() => runtime,
            _ => {
                let runtime = self
                    .environment
                    .load_isolated(
                        &entry.manifest_json,
                        engine.source.as_ref().expect("initialized source"),
                        self.limits.clone(),
                        &primary,
                    )
                    .map_err(error_from_environment)?;
                if !settings.is_empty()
                    && let Err(error) =
                        self.lifecycle(&runtime, "initialize", &json!([settings]).to_string())
                {
                    self.teardown_runtime(&runtime);
                    return Err(error);
                }
                runtime
            }
        };
        entry
            .downloads
            .lock()
            .expect("download pool lock")
            .active
            .push(Arc::clone(&runtime));
        drop(engine);
        Ok(Borrowed {
            manager: self,
            entry,
            runtime,
            generation,
            healthy: false,
            retire_without_hooks: false,
        })
    }

    /// Execute the installed provider's download contract in an isolated worker.
    /// File placement, post-processing and finalization remain caller-owned.
    pub fn download(
        &self,
        id: &str,
        request: ProviderDownloadRequest,
        resolution_timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        self.download_with_lease(id, request, resolution_timeout_ms, None)
    }

    pub(crate) fn download_with_lease(
        &self,
        id: &str,
        request: ProviderDownloadRequest,
        resolution_timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ManagerError> {
        #[cfg(feature = "experimental-private-mov")]
        let private_mode = self
            .private_downloads
            .read()
            .expect("private download mode lock");
        #[cfg(feature = "experimental-private-mov")]
        if *private_mode {
            return Err(error("private downloads require the host transaction API"));
        }
        let mut value =
            self.download_value_with_lease(id, request, resolution_timeout_ms, lease, false,
                #[cfg(feature = "experimental-progressive-reader")] None)?;
        // The mode read guard lasts through serialization; registration waits
        // for existing legacy invocations before enabling private-only calls.
        normalize_decryption(&mut value.0);
        Ok(value.0.to_string())
    }

    #[cfg(feature = "experimental-private-mov")]
    pub(crate) fn enable_private_downloads(&self) {
        *self
            .private_downloads
            .write()
            .expect("private download mode lock") = true;
    }

    #[cfg(feature = "experimental-private-mov")]
    pub(crate) fn download_private_with_lease(
        &self,
        id: &str,
        request: ProviderDownloadRequest,
        resolution_timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<PrivateDownloadResult, ManagerError> {
        if !*self
            .private_downloads
            .read()
            .expect("private download mode lock")
        {
            return Err(error("private download capability is unavailable"));
        }
        self.download_value_with_lease(id, request, resolution_timeout_ms, lease, true,
            #[cfg(feature = "experimental-progressive-reader")] None)
            .map(adopt_private)
    }

    #[cfg(feature = "experimental-progressive-reader")]
    pub(crate) fn download_with_progressive_lease(
        &self, id: &str, request: ProviderDownloadRequest, resolution_timeout_ms: u64,
        lease: Arc<RequestLease>, progressive: Arc<crate::download::progressive_candidate::ProgressiveOperation>,
    ) -> Result<String, ManagerError> {
        #[cfg(feature = "experimental-private-mov")]
        if *self.private_downloads.read().expect("private download mode lock") {
            return Err(error("private downloads require the host transaction API"));
        }
        let mut value = self.download_value_with_lease(id, request, resolution_timeout_ms, Some(lease), false, Some(progressive))?;
        normalize_decryption(&mut value.0);
        Ok(value.0.to_string())
    }

    fn download_value_with_lease(
        &self,
        id: &str,
        request: ProviderDownloadRequest,
        resolution_timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
        private_result: bool,
        #[cfg(feature = "experimental-progressive-reader")]
        progressive: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>,
    ) -> Result<DownloadValue, ManagerError> {
        let entry = self.get(id)?;
        if !entry.manifest.has_type("download_provider") {
            return Err(error(format!(
                "extension '{id}' is not a download provider"
            )));
        }
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error(format!("extension '{id}' is disabled")));
        }
        let mut borrowed = match self.borrow_download(entry, lease.clone()) {
            Ok(borrowed) => borrowed,
            Err(error) => return Ok(value_failure("init_error", &error.to_string())),
        };
        borrowed.retire_without_hooks = private_result;
        let allowance = if resolution_timeout_ms == 0 {
            60_000
        } else {
            resolution_timeout_ms.min(300_000)
        };
        let mut options = json!({"resolutionTimeoutMs":allowance});
        if let Some(context) = request
            .prepared_context
            .filter(|context| !context.is_empty())
        {
            options["preparedContext"] = context.into();
        }
        // This marker belongs to one VM and one invocation, never to a previous
        // download that returned its worker to the idle pool.
        borrowed.runtime.take_verification_url();
        let response = borrowed.runtime.call_download_provider(
            &json!([
                request.track_id,
                request.quality,
                request.output_path,
                options
            ])
            .to_string(),
            &request.item_id,
            allowance,
            lease,
            #[cfg(feature = "experimental-progressive-reader")]
            progressive,
        );
        let response = match response {
            Ok(response) => response,
            Err((ExtensionError::Cancelled(cause), _)) => return Err(error(cause.to_string())),
            Err((ExtensionError::Timeout, resolution)) => {
                return Ok(value_failure(
                    "timeout",
                    if resolution {
                        "stream resolution timeout: extension took too long to resolve an audio stream"
                    } else {
                        "download timeout: extension took too long to complete"
                    },
                ));
            }
            Err((error, _)) => return Ok(value_failure("script_error", &error.to_string())),
        };
        let mut response: DownloadValue =
            serde_json::from_str(&response).map_err(|_| error("invalid download result"))?;
        if let Some(error) = response.0.get("parseError").and_then(Value::as_str) {
            return Ok(value_failure("script_error", error));
        }
        borrowed.healthy = !private_result;
        let mut owned = DownloadValue(response.0["value"].take());
        let value = &mut owned.0;
        if value.is_null() {
            return Ok(value_failure("not_implemented", "download returned null"));
        }
        if !value.is_object() {
            return Ok(value_failure(
                "script_error",
                "download returned invalid object",
            ));
        }
        if value["success"] != true
            && !borrowed.runtime.take_verification_url().is_empty()
            && !value["error_type"]
                .as_str()
                .unwrap_or("")
                .eq_ignore_ascii_case("verification_required")
        {
            value["error_type"] = "verification_required".into();
            if value["error_message"].as_str().unwrap_or("").is_empty() {
                value["error_message"] = "Verification required".into();
            }
        }
        Ok(owned)
    }
}

fn value_failure(kind: &str, message: &str) -> DownloadValue {
    DownloadValue(json!({"success":false,"error_type":kind,"error_message":message}))
}

fn normalize_decryption(value: &mut Value) {
    const MOV: &str = "ffmpeg.mov_key";
    let legacy = zeroize::Zeroizing::new(
        value["decryption_key"]
            .as_str()
            .unwrap_or("")
            .trim()
            .to_owned(),
    );
    let mut descriptor = DownloadValue(
        value
            .as_object_mut()
            .unwrap()
            .remove("decryption")
            .unwrap_or(Value::Null),
    );
    if !descriptor.0.is_object() {
        wipe(&mut descriptor.0);
        descriptor.0 = Value::Null;
    }
    if descriptor.0.is_null() && !legacy.is_empty() {
        descriptor.0 = json!({});
    }
    if let Some(info) = descriptor.0.as_object_mut() {
        for key in ["strategy", "key", "iv", "input_format", "output_extension"] {
            if let Some(value) = info.get_mut(key) {
                let mut normalized =
                    zeroize::Zeroizing::new(value.as_str().unwrap_or("").trim().to_owned());
                wipe(value);
                *value = Value::String(std::mem::take(&mut *normalized));
            }
        }
        let strategy = info.get("strategy").and_then(Value::as_str).unwrap_or("");
        let lower = zeroize::Zeroizing::new(mornye_core::matching::lowercase(strategy));
        let mut strategy = zeroize::Zeroizing::new(match lower.as_str() {
            ""
            | MOV
            | "ffmpeg_mov_key"
            | "mov_decryption_key"
            | "mp4_decryption_key"
            | "ffmpeg.mp4_decryption_key" => MOV.to_owned(),
            _ => strategy.to_owned(),
        });
        let mov = strategy.as_str() == MOV;
        if let Some(mut previous) = info.insert(
            "strategy".into(),
            Value::String(std::mem::take(&mut *strategy)),
        ) {
            wipe(&mut previous);
        }
        if info
            .get("key")
            .and_then(Value::as_str)
            .unwrap_or("")
            .is_empty()
            && !legacy.is_empty()
        {
            if let Some(mut previous) = info.insert("key".into(), Value::String(legacy.to_string()))
            {
                wipe(&mut previous);
            }
        }
        if mov
            && info
                .get("input_format")
                .and_then(Value::as_str)
                .unwrap_or("")
                .is_empty()
        {
            if let Some(mut previous) = info.insert("input_format".into(), "mov".into()) {
                wipe(&mut previous);
            }
        }
        info.retain(|_, value| value != "");
    }
    if descriptor.0.as_object().is_some_and(|info| {
        info.get("strategy").and_then(Value::as_str) == Some(MOV)
            && info
                .get("key")
                .and_then(Value::as_str)
                .unwrap_or("")
                .is_empty()
    }) {
        wipe(&mut descriptor.0);
        descriptor.0 = Value::Null;
    }
    let mut key = zeroize::Zeroizing::new(
        descriptor
            .0
            .as_object()
            .filter(|info| info.get("strategy").and_then(Value::as_str) == Some(MOV))
            .and_then(|info| info.get("key"))
            .and_then(Value::as_str)
            .unwrap_or(&legacy)
            .to_owned(),
    );
    let value = value.as_object_mut().unwrap();
    if let Some(mut previous) = value.remove("decryption_key") {
        wipe(&mut previous);
    }
    if !key.is_empty() {
        value.insert(
            "decryption_key".into(),
            Value::String(std::mem::take(&mut *key)),
        );
    }
    if !descriptor.0.is_null() {
        value.insert("decryption".into(), std::mem::take(&mut descriptor.0));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_decryption_normalization_preserves_public_compatibility() {
        let key = zeroize::Zeroizing::new(crate::binary::encode(&[19; 16], "hex").unwrap());
        for legacy_only in [false, true] {
            let mut result = DownloadValue(
                json!({"success":true,"decryption_key":format!("  {}  ", key.as_str())}),
            );
            if !legacy_only {
                result.0["decryption"] = json!({"strategy":" mov_decryption_key ","key":" ","input_format":" ","output_extension":" .flac "});
            }
            normalize_decryption(&mut result.0);
            assert!(
                result.0["decryption_key"].as_str() == Some(key.as_str()),
                "legacy key normalization changed"
            );
            assert!(
                result.0["decryption"]["key"].as_str() == Some(key.as_str()),
                "descriptor key normalization changed"
            );
            assert_eq!(result.0["decryption"]["strategy"], "ffmpeg.mov_key");
            assert_eq!(result.0["decryption"]["input_format"], "mov");
            if !legacy_only {
                assert_eq!(result.0["decryption"]["output_extension"], ".flac");
            }
        }
        let mut missing =
            DownloadValue(json!({"decryption":{"strategy":"ffmpeg.mov_key","key":" "}}));
        normalize_decryption(&mut missing.0);
        assert!(missing.0.get("decryption").is_none());
        assert!(missing.0.get("decryption_key").is_none());
    }

    #[cfg(feature = "experimental-private-mov")]
    #[test]
    fn private_download_workers_retire_without_pooling_or_cleanup_hooks() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let manager = ExtensionManager::new(
            &sources,
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let source = sources.join("example.private");
        fs::create_dir(&source).unwrap();
        fs::write(
            source.join("manifest.json"),
            json!({"name":"example.private","version":"1",
            "description":"Private worker lifetime fixture","type":["download_provider"],
            "permissions":{"storage":true}})
            .to_string(),
        )
        .unwrap();
        fs::write(source.join("index.js"),
            "let visits=0; registerExtension({download(){ visits++; return {success:true,track_number:visits,decryption:{strategy:'ffmpeg.mov_key',key:Array(16).fill(19).map(x=>x.toString(16).padStart(2,'0')).join('')}}; },cleanup(){storage.set('private_cleanup_called',true);},inspect(){return storage.get('private_cleanup_called')===true;}});").unwrap();
        manager.load_all().unwrap();
        manager.set_enabled("example.private", true).unwrap();
        manager.enable_private_downloads();
        for _ in 0..2 {
            let result = manager
                .download_private_with_lease(
                    "example.private",
                    ProviderDownloadRequest::default(),
                    1000,
                    None,
                )
                .unwrap();
            assert_eq!(result.metadata["track_number"], 1);
            assert!(result.decryption.is_some());
            let entry = manager.get("example.private").unwrap();
            let pool = entry.downloads.lock().unwrap();
            assert!(pool.active.is_empty());
            assert!(pool.idle.is_none());
        }
        let entry = manager.get("example.private").unwrap();
        let primary = entry
            .engine
            .lock()
            .unwrap()
            .runtime
            .as_ref()
            .unwrap()
            .clone();
        assert_eq!(primary.call("inspect", "[]", None, 1000).unwrap(), "false");
    }

    #[cfg(feature = "experimental-private-mov")]
    #[test]
    fn private_descriptor_adoption_moves_keys_without_public_json_copies() {
        for legacy in [false, true] {
            let key = crate::binary::encode(&[19; 16], "hex").unwrap();
            let address = key.as_ptr();
            let mut value = json!({"success":true,"file_path":"owned.mp4"});
            if legacy {
                value["decryption_key"] = Value::String(key);
            } else {
                value["decryption"] = json!({"strategy":"ffmpeg.mov_key","input_format":"mov"});
                value["decryption"]["key"] = Value::String(key);
            }
            let result = adopt_private(DownloadValue(value));
            assert!(result.metadata.get("decryption").is_none());
            assert!(result.metadata.get("decryption_key").is_none());
            let descriptor = result.decryption.unwrap();
            assert!(
                descriptor.0.0["key"].as_str().unwrap().as_ptr() == address,
                "descriptor adoption copied key allocation"
            );
            let bytes = descriptor.into_mov_key().unwrap();
            assert!(bytes.as_slice() == [19; 16], "private key decode failed");
        }
    }

    #[test]
    fn account_download_mode_is_declared_and_selected_by_settings() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let manager = ExtensionManager::new(
            &sources,
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let source = sources.join("example.account");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("manifest.json"), json!({"name":"example.account","version":"1",
            "description":"Generic account mode fixture","type":["download_provider"],
            "permissions":{"storage":true,"network":["accounts.example.test"]},
            "signedSession":{"namespace":"example-account","baseUrl":"https://accounts.example.test","appVersion":"1","platform":"extension",
                "endpoints":{"bootstrap":"/bootstrap","challenge":"/challenge","exchange":"/exchange","refresh":"/refresh"}},
            "capabilities":{"accountDownloadMode":{"setting":"accountMode","value":"personal"}}}).to_string()).unwrap();
        fs::write(
            source.join("index.js"),
            "registerExtension({download(){return {success:false}}});",
        )
        .unwrap();
        manager.load_all().unwrap();
        manager.set_enabled("example.account", true).unwrap();
        assert!(!manager.account_download_enabled("example.account").unwrap());
        manager
            .update_settings(
                "example.account",
                serde_json::from_value(json!({"accountMode":"personal"})).unwrap(),
            )
            .unwrap();
        assert!(manager.account_download_enabled("example.account").unwrap());
        // No signed-session service is contacted in personal account mode.
        let lease = Arc::new(
            manager
                .environment
                .download_state()
                .acquire("test-account")
                .unwrap(),
        );
        assert!(
            !manager
                .preflight_download("example.account", lease)
                .unwrap()
        );
        manager
            .update_settings(
                "example.account",
                serde_json::from_value(json!({"accountMode":"community"})).unwrap(),
            )
            .unwrap();
        assert!(!manager.account_download_enabled("example.account").unwrap());
    }

    #[test]
    fn returning_a_borrow_after_uninstall_cannot_recreate_extension_data() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let data = directory.path().join("data");
        let manager = ExtensionManager::new(
            &sources,
            &data,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let source = sources.join("example.pool");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("manifest.json"), json!({"name":"example.pool","version":"1","description":"Generic pool ownership test","type":["download_provider"],"permissions":{"storage":true}}).to_string()).unwrap();
        fs::write(
            source.join("index.js"),
            "registerExtension({download(){return {success:true}}});",
        )
        .unwrap();
        manager.load_all().unwrap();
        manager.set_enabled("example.pool", true).unwrap();
        let mut borrowed = manager
            .borrow_download(manager.get("example.pool").unwrap(), None)
            .unwrap();
        borrowed.healthy = true;
        manager.remove("example.pool").unwrap();
        assert!(!data.join("example.pool").exists());
        drop(borrowed);
        assert!(!data.join("example.pool").exists());
    }
}
