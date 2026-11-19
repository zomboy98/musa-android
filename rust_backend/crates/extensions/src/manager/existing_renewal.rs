//! Cold-start renewal never constructs a manager, loads JavaScript, or migrates data.
use super::*;
use crate::signed_session::{RenewalResult, RecordStore, protocol};
use crate::storage::{StorageMasterKey, decrypt, valid_extension_id};
use zeroize::Zeroizing;
use mornye_network::{NetworkService, policy::NetworkPermissions};
use std::time::Duration;

fn directory(path: &Path) -> Result<PathBuf, String> {
    let metadata = fs::symlink_metadata(path).map_err(|_| "existing directory unavailable")?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("invalid existing directory".into());
    }
    fs::canonicalize(path).map_err(|_| "existing directory unavailable".into())
}

fn existing_lock(directory: &Path) -> Result<File, String> {
    // Same lock objects and order as ExtensionManager::with_environment.
    // No create: a never-initialized root is deliberately ineligible.
    let file = OpenOptions::new().read(true).write(true).nofollow_nonblock()
        .open(directory.join(".backend-manager.lock"))
        .map_err(|_| "existing owner lock unavailable")?;
    if !file.metadata().map_err(|_| "invalid owner lock")?.is_file() {
        return Err("invalid owner lock".into());
    }
    file.try_lock().map_err(|_| "extension directories are already managed")?;
    Ok(file)
}

/// The platform must supply its existing key; no key generation is performed.
/// Only authenticated settings.enc is authoritative here. Legacy settings are
/// deliberately unavailable until foreground performs its normal migration.
/// Both existing manager locks are held across all reads.
/// Cold renewal requires an authenticated allowed guard bound to the current
/// generation; old/dirty guards remain unavailable and blocked guards remain blocked.
/// Cancellation is checked during transport and serialized with persistence.
/// Returns only scheduling metadata, never identifiers, credentials or URLs.
pub fn renew_existing_session_standalone(
    sources: &Path,
    data: &Path,
    master_key: &str,
    app_version: &str,
    id: &str,
    lease: &mornye_core::cancellation::RequestLease,
) -> Result<RenewalResult, String> {
    let check = || lease.check_active().map_err(|_| "session renewal cancelled".to_owned());
    check()?;
    if !valid_extension_id(id) { return Err("invalid extension ID".into()); }
    let sources = match directory(sources) { Ok(value) => value, Err(_) => return Ok(RenewalResult::new("unavailable", None)) };
    let data = match directory(data) { Ok(value) => value, Err(_) => return Ok(RenewalResult::new("unavailable", None)) };
    if sources.starts_with(&data) || data.starts_with(&sources) {
        return Err("extension source and data directories must be separate".into());
    }
    let (_source_lock, _data_lock) = match (|| Ok::<_, String>((existing_lock(&sources)?, existing_lock(&data)?)))() {
        Ok(locks) => locks,
        Err(_) => return Ok(RenewalResult::new("unavailable", None)),
    };
    check()?;
    let source = match directory(&sources.join(id)) { Ok(value) => value, Err(_) => return Ok(RenewalResult::new("not_applicable", None)) };
    if source.parent() != Some(sources.as_path()) { return Err("invalid extension directory".into()); }
    let raw = read_source(&source.join("manifest.json"), 1024 * 1024)
        .map_err(|_| "existing manifest unavailable")?;
    let manifest = ExtensionManifest::parse(&raw).map_err(|_| "invalid existing manifest")?;
    if manifest.name != id { return Err("extension manifest name mismatch".into()); }
    validate_gates(&manifest, app_version, &SUPPORTED_RUNTIME_FEATURES)
        .map_err(|_| "extension runtime requirements unavailable")?;
    // Installed directory contract includes index.js; inspect but never execute it.
    let index = OpenOptions::new().read(true).nofollow_nonblock().open(source.join("index.js"))
        .map_err(|_| "installed extension source unavailable")?;
    if !index.metadata().map_err(|_| "invalid extension source")?.is_file() {
        return Err("invalid extension source".into());
    }
    let Some(config) = manifest.signed_session else { return Ok(RenewalResult::new("not_applicable", None)); };
    let private = match directory(&data.join(id)) { Ok(value) => value, Err(_) => return Ok(RenewalResult::new("unavailable", None)) };
    if private.parent() != Some(data.as_path()) { return Err("invalid extension data directory".into()); }
    check()?;
    let key = Arc::new(StorageMasterKey::from_base64(master_key).map_err(|_| "existing storage key unavailable")?);
    let settings_path = private.join("settings.enc");
    let mut settings_file = match OpenOptions::new().read(true).nofollow_nonblock().open(&settings_path) {
        Ok(file) => file,
        Err(_) => return Ok(RenewalResult::new("unavailable", None)),
    };
    let metadata = settings_file.metadata().map_err(|_| "invalid existing settings")?;
    if !metadata.is_file() || metadata.len() > 1024 * 1024 { return Err("invalid existing settings".into()); }
    let mut settings = Zeroizing::new(Vec::new());
    (&mut settings_file).take(1024 * 1024 + 1).read_to_end(&mut settings).map_err(|_| "existing settings unavailable")?;
    if settings.len() > 1024 * 1024 { return Err("invalid existing settings".into()); }
    let plaintext = decrypt(&settings, &key.derive(id, "settings")).map_err(|_| "invalid existing settings")?;
    let values: Map<String, Value> = serde_json::from_slice(&plaintext).map_err(|_| "invalid existing settings")?;
    if values.get("_enabled") != Some(&Value::Bool(true)) { return Ok(RenewalResult::new("disabled", None)); }
    check()?;
    let config = protocol::defaults(config);
    let Some(store) = RecordStore::open_existing_with_key(&data, &config, Some(Arc::clone(&key)))? else {
        return Ok(RenewalResult::new("missing", None));
    };
    let record = match store.load_existing() {
        Ok(None) => return Ok(RenewalResult::new("missing", None)),
        Ok(Some(record)) => record,
        Err(error) if error == "legacy signed session requires foreground migration" =>
            return Ok(RenewalResult::new("unavailable", None)),
        Err(error) => return Err(error),
    };
    if record.renewal_blocked() { return Ok(RenewalResult::new("blocked", None)); }
    if !record.renewal_allowed() { return Ok(RenewalResult::new("unavailable", None)); }
    check()?;
    let network = NetworkService::new().map_err(|_| "session network unavailable")?;
    let session = network.session(NetworkPermissions {
        domains: manifest.permissions.network.unwrap_or_default(),
        allow_http: manifest.permissions.allow_http,
    }, Duration::from_secs(30));
    let registry = crate::signed_session::SignedRegistry::with_key(&data, Arc::new(crate::auth::AuthRegistry::default()), Some(key));
    let Some(client) = registry.existing_session(id, config, session)? else {
        return Ok(RenewalResult::new("missing", None));
    };
    client.renew_existing_with_lease(lease)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn renew_existing_session_standalone(sources: &Path, data: &Path, key: &str, version: &str, id: &str) -> Result<RenewalResult, String> {
        let registry = mornye_core::cancellation::CancellationRegistry::new(mornye_core::cancellation::CancellationDomain::ExtensionRequest);
        let lease = registry.acquire("renew").unwrap();
        super::renew_existing_session_standalone(sources, data, key, version, id, &lease)
    }
    const KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    fn fixture(root: &Path) -> (PathBuf, PathBuf) {
        let sources = root.join("sources"); let data = root.join("data");
        fs::create_dir_all(sources.join("fixture")).unwrap();
        fs::create_dir_all(data.join("fixture")).unwrap();
        for root in [&sources, &data] { fs::write(root.join(".backend-manager.lock"), []).unwrap(); }
        fs::write(sources.join("fixture/manifest.json"), serde_json::json!({
            "name":"fixture","version":"1","description":"fixture","type":["metadata_provider"],
            "permissions":{"storage":true,"network":["accounts.example.test"]},
            "signedSession":{"namespace":"fixture","baseUrl":"https://accounts.example.test","endpoints":{"refresh":"/refresh"}}
        }).to_string()).unwrap();
        fs::write(sources.join("fixture/index.js"), "throw new Error('must never execute');").unwrap();
        (sources, data)
    }
    fn settings(data: &Path, bytes: &[u8]) {
        let key = StorageMasterKey::from_base64(KEY).unwrap();
        fs::write(data.join("fixture/settings.enc"), crate::storage::encrypt(bytes, &key.derive("fixture", "settings")).unwrap()).unwrap();
    }
    fn snapshot(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
        let mut result = BTreeMap::new();
        for entry in fs::read_dir(root).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() { result.extend(snapshot(&path)); }
            else { result.insert(path.clone(), fs::read(path).unwrap()); }
        }
        result
    }
    #[test]
    fn absent_roots_and_invalid_id_have_no_effects() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(renew_existing_session_standalone(&root.path().join("sources"), &root.path().join("data"), KEY, "1", "fixture").unwrap().status, "unavailable");
        assert!(renew_existing_session_standalone(root.path(), root.path(), KEY, "1", "../fixture").is_err());
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }
    #[test]
    fn cold_guard_persists_across_reopen_and_cancellation_prevents_all_work() {
        let root = tempfile::tempdir().unwrap();
        let (sources, data) = fixture(root.path());
        settings(&data, br#"{"_enabled":true}"#);
        let manifest = ExtensionManifest::parse(&fs::read_to_string(sources.join("fixture/manifest.json")).unwrap()).unwrap();
        let config = protocol::defaults(manifest.signed_session.unwrap());
        let store = RecordStore::open_with_key(&data, &config, Some(Arc::new(StorageMasterKey::from_base64(KEY).unwrap()))).unwrap();
        let mut record = protocol::Record::default();
        record.install_id = "install".into(); record.session_id = "session".into(); record.session_secret = "secret".into();
        record.expires_at = "2099-01-01T00:00:00Z".into();
        for (guard, expected) in [("allowed", "valid_until"), ("blocked", "blocked"), ("dirty", "unavailable")] {
            record.mark_renewal(guard);
            store.save(&record).unwrap();
            let before = snapshot(root.path());
            assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, expected);
            assert_eq!(snapshot(root.path()), before);
        }
        record.mark_renewal("allowed"); record.session_secret = "replacement-secret".into();
        store.save(&record).unwrap();
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "unavailable");
        let registry = mornye_core::cancellation::CancellationRegistry::new(mornye_core::cancellation::CancellationDomain::ExtensionRequest);
        let lease = registry.acquire("attempt").unwrap(); registry.cancel("attempt").unwrap();
        let before = snapshot(root.path());
        assert_eq!(super::renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture", &lease).err().unwrap(), "session renewal cancelled");
        assert_eq!(snapshot(root.path()), before);
    }

    #[test]
    fn valid_existing_ciphertext_is_unchanged_and_corrupt_session_is_preserved() {
        let root = tempfile::tempdir().unwrap();
        let (sources, data) = fixture(root.path());
        settings(&data, br#"{"_enabled":true}"#);
        let manifest = ExtensionManifest::parse(&fs::read_to_string(sources.join("fixture/manifest.json")).unwrap()).unwrap();
        let config = crate::signed_session::protocol::defaults(manifest.signed_session.unwrap());
        let key = Arc::new(StorageMasterKey::from_base64(KEY).unwrap());
        let store = crate::signed_session::RecordStore::open_with_key(&data, &config, Some(key)).unwrap();
        let mut record = crate::signed_session::protocol::Record::default();
        record.install_id = "fixture-install".into();
        record.session_id = "fixture-session".into();
        record.session_secret = "fixture-secret".into();
        record.expires_at = "2099-01-01T00:00:00Z".into();
        store.save(&record).unwrap();
        let before = snapshot(root.path());
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "unavailable");
        assert_eq!(snapshot(root.path()), before);
        let legacy = serde_json::json!({
            "install_id":"legacy-install", "session_id":"legacy-session", "session_secret":"legacy-secret",
            "expires_at":chrono::Utc::now().checked_add_signed(chrono::Duration::seconds(60)).unwrap().to_rfc3339()
        }).to_string();
        fs::write(store.path(), legacy).unwrap();
        let before = snapshot(root.path());
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "unavailable");
        assert_eq!(snapshot(root.path()), before);
        fs::write(store.path(), b"{broken").unwrap();
        let before = snapshot(root.path());
        assert!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").is_err());
        assert_eq!(snapshot(root.path()), before);
    }

    #[test]
    fn authenticated_enablement_missing_sessions_corruption_and_live_owner_fail_closed() {
        let root = tempfile::tempdir().unwrap();
        let (sources, data) = fixture(root.path());
        fs::write(data.join("fixture/settings.json"), br#"{"_enabled":true}"#).unwrap();
        let before = snapshot(root.path());
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "unavailable");
        assert_eq!(snapshot(root.path()), before);
        settings(&data, br#"{"_enabled":false}"#);
        let before = snapshot(root.path());
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "disabled");
        assert_eq!(snapshot(root.path()), before);
        settings(&data, br#"{"_enabled":true}"#);
        let before = snapshot(root.path());
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "missing");
        assert_eq!(snapshot(root.path()), before);
        assert!(!data.join("signed_sessions").exists());
        let owner = existing_lock(&sources).unwrap();
        assert_eq!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").unwrap().status, "unavailable");
        drop(owner);
        fs::write(data.join("fixture/settings.enc"), b"corrupt").unwrap();
        let before = snapshot(root.path());
        assert!(renew_existing_session_standalone(&sources, &data, KEY, "1", "fixture").is_err());
        assert_eq!(snapshot(root.path()), before);
    }
}
