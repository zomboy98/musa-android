use super::protocol::{self, Record};
use crate::manifest::SignedSession;
use crate::storage::{StorageMasterKey, decrypt, encrypt};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use mornye_core::fs::OpenOptionsPortableExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use zeroize::Zeroizing;

pub(super) const LEGACY_REQUIRES_FOREGROUND: &str = "legacy signed session requires foreground migration";

const MAGIC: &[u8] = b"\x89MUSA-SESSION\x01";

#[derive(Default)]
pub struct RuntimeHints {
    default: String,
    values: BTreeMap<String, String>,
}

#[cfg(test)]
mod encrypted_tests {
    use super::*;
    use crate::storage::StorageMasterKey;
    use std::sync::Arc;

    fn config() -> SignedSession {
        protocol::defaults(SignedSession {
            namespace: "fixture".into(),
            base_url: "https://fixture.invalid".into(),
            ..Default::default()
        })
    }
    fn key(byte: u8) -> Arc<StorageMasterKey> {
        use base64::Engine;
        Arc::new(
            StorageMasterKey::from_base64(
                &base64::engine::general_purpose::STANDARD.encode([byte; 32]),
            )
            .unwrap(),
        )
    }
    #[test]
    fn existing_reader_preserves_absent_corrupt_legacy_and_encrypted_records() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let absent = dir.path().join("absent");
        assert!(RecordStore::open_existing_with_key(&absent, &cfg, Some(key(7))).unwrap().is_none());
        assert!(!absent.exists());
        let store = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
        assert!(store.load_existing().unwrap().is_none());
        assert_eq!(fs::read_dir(store.path().parent().unwrap()).unwrap().count(), 0);
        let legacy = br#"{"session_id":"existing","session_secret":"secret"}"#;
        fs::write(store.path(), legacy).unwrap();
        assert_eq!(store.load_existing().err().unwrap(), LEGACY_REQUIRES_FOREGROUND);
        assert_eq!(fs::read(store.path()).unwrap(), legacy);
        fs::write(store.path(), b"{broken").unwrap();
        assert!(store.load_existing().is_err());
        assert_eq!(fs::read(store.path()).unwrap(), b"{broken");
        let mut record = Record::default();
        record.install_id = "existing-install".into();
        record.session_id = "existing-session".into();
        record.session_secret = "existing-secret".into();
        store.save(&record).unwrap();
        let ciphertext = fs::read(store.path()).unwrap();
        let reopened = RecordStore::open_existing_with_key(dir.path(), &cfg, Some(key(7))).unwrap().unwrap();
        assert_eq!(reopened.load_existing().unwrap().unwrap().session_id, "existing-session");
        assert_eq!(fs::read(store.path()).unwrap(), ciphertext);
        let wrong = RecordStore::open_existing_with_key(dir.path(), &cfg, Some(key(8))).unwrap().unwrap();
        assert!(wrong.load_existing().is_err());
        assert_eq!(fs::read(store.path()).unwrap(), ciphertext);
        assert_eq!(fs::read_dir(store.path().parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn existing_reader_never_exposes_invalid_plaintext_in_errors() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let master = key(7);
        let store = RecordStore::open_with_key(dir.path(), &cfg, Some(Arc::clone(&master))).unwrap();
        let sentinel = "SESSION_SECRET_SENTINEL_MUST_NOT_LEAK";
        let invalid = serde_json::to_vec(sentinel).unwrap();
        for encrypted in [false, true] {
            let bytes = if encrypted {
                let ciphertext = encrypt(&invalid, &master.derive(&protocol::scope(&cfg), "signed-session-v1")).unwrap();
                [MAGIC, ciphertext.as_slice()].concat()
            } else { invalid.clone() };
            fs::write(store.path(), &bytes).unwrap();
            let error = store.load_existing().err().unwrap();
            assert_eq!(error, "invalid signed session record");
            assert!(!error.contains(sentinel));
            assert_eq!(fs::read(store.path()).unwrap(), bytes);
        }
    }

    #[test]
    fn foreground_decode_errors_are_sanitized_and_legacy_migration_still_works() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let master = key(7);
        let store = RecordStore::open_with_key(dir.path(), &cfg, Some(Arc::clone(&master))).unwrap();
        let sentinel = "FOREGROUND_SECRET_SENTINEL_MUST_NOT_LEAK";
        let invalid = serde_json::to_vec(sentinel).unwrap();
        for encrypted in [false, true] {
            let bytes = if encrypted {
                let ciphertext = encrypt(&invalid, &master.derive(&protocol::scope(&cfg), "signed-session-v1")).unwrap();
                [MAGIC, ciphertext.as_slice()].concat()
            } else { invalid.clone() };
            fs::write(store.path(), &bytes).unwrap();
            let error = store.load(&RuntimeHints::default()).err().unwrap();
            assert_eq!(error, "invalid signed session record");
            assert!(!error.contains(sentinel));
            assert_eq!(fs::read(store.path()).unwrap(), bytes);
        }
        let legacy = br#"{"install_id":"foreground-install","session_id":"foreground-session","session_secret":"foreground-secret"}"#;
        fs::write(store.path(), legacy).unwrap();
        let migrated = store.load(&RuntimeHints::default()).unwrap();
        assert_eq!(migrated.install_id, "foreground-install");
        assert_eq!(migrated.session_secret, "foreground-secret");
        assert!(fs::read(store.path()).unwrap().starts_with(MAGIC));
        assert_eq!(store.load_existing().unwrap().unwrap().session_id, "foreground-session");
    }

    #[test]
    fn cancellation_during_preparation_is_prompt_and_leaves_original_without_tempfiles() {
        use mornye_core::cancellation::{CancellationRegistry, CancellationDomain};
        use std::sync::mpsc;
        use std::time::Duration;
        let dir = tempfile::tempdir().unwrap();
        let store = RecordStore::open_with_key(dir.path(), &config(), Some(key(7))).unwrap();
        let mut original = Record::default(); original.install_id = "install".into(); original.session_id = "original".into(); original.session_secret = "original-secret".into();
        store.save(&original).unwrap();
        let path = store.path().to_owned(); let before = fs::read(&path).unwrap();
        let cancellation = Arc::new(CancellationRegistry::new(CancellationDomain::ExtensionRequest));
        let lease = Arc::new(cancellation.acquire("attempt").unwrap());
        let (preparing, preparation_seen) = mpsc::channel(); let (release, released) = mpsc::channel();
        let worker = { let lease = Arc::clone(&lease); std::thread::spawn(move || {
            let mut replacement = original.clone(); replacement.session_secret = "replacement-secret".into();
            let staged = store.prepare_save_with_checkpoint(&replacement, || {
                preparing.send(()).unwrap(); released.recv_timeout(Duration::from_secs(5)).unwrap();
            }).unwrap();
            staged.commit_with_lease(&lease)
        }) };
        preparation_seen.recv_timeout(Duration::from_secs(5)).unwrap();
        let (cancelled, cancel_seen) = mpsc::channel();
        let canceller = std::thread::spawn(move || { cancellation.cancel("attempt").unwrap(); cancelled.send(()).unwrap(); });
        // Preparation remains paused: cancel must not wait on its write/fsync.
        cancel_seen.recv_timeout(Duration::from_secs(1)).unwrap();
        release.send(()).unwrap(); canceller.join().unwrap();
        assert_eq!(worker.join().unwrap().err().unwrap(), "session renewal cancelled");
        assert!(!lease.has_committed());
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(fs::read_dir(path.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn prepared_commit_publishes_synced_ciphertext_and_marks_lease_committed() {
        use mornye_core::cancellation::{CancellationRegistry, CancellationDomain};
        let dir = tempfile::tempdir().unwrap();
        let store = RecordStore::open_with_key(dir.path(), &config(), Some(key(7))).unwrap();
        let mut record = Record::default(); record.install_id = "install".into(); record.session_id = "session".into(); record.session_secret = "original-secret".into();
        store.save(&record).unwrap();
        let before = fs::read(store.path()).unwrap(); record.session_secret = "replacement-secret".into();
        let prepared = store.prepare_save(&record).unwrap();
        assert_eq!(fs::read(store.path()).unwrap(), before);
        let cancellation = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
        let lease = cancellation.acquire("attempt").unwrap();
        prepared.commit_with_lease(&lease).unwrap();
        assert!(lease.has_committed());
        assert_eq!(store.load_existing().unwrap().unwrap().session_secret, "replacement-secret");
        assert_eq!(fs::read_dir(store.path().parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn existing_reader_rejects_oversized_file_without_modifying_it() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecordStore::open_with_key(dir.path(), &config(), Some(key(7))).unwrap();
        let oversized = vec![b' '; 1024 * 1024 + 1];
        fs::write(store.path(), &oversized).unwrap();
        assert!(store.load_existing().is_err());
        assert_eq!(fs::read(store.path()).unwrap(), oversized);
    }

    #[cfg(unix)]
    #[test]
    fn existing_reader_rejects_symlink_without_following_it() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecordStore::open_with_key(dir.path(), &config(), Some(key(7))).unwrap();
        let outside = dir.path().join("outside");
        fs::write(&outside, b"preserved").unwrap();
        std::os::unix::fs::symlink(&outside, store.path()).unwrap();
        assert!(store.load_existing().is_err());
        assert_eq!(fs::read(&outside).unwrap(), b"preserved");
        assert!(fs::symlink_metadata(store.path()).unwrap().file_type().is_symlink());
    }

    #[test]
    fn migration_persistence_and_failure_preservation() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let store = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
        let legacy = br#"{"install_id":"fixture-install","session_id":"fixture-session","session_secret":"fixture-secret","expires_at":"2099-01-01T00:00:00Z"}"#;
        fs::write(store.path(), legacy).unwrap();
        let record = store.load(&RuntimeHints::default()).unwrap();
        assert_eq!(record.install_id, "fixture-install");
        assert_eq!(record.session_secret, "fixture-secret");
        let encrypted = fs::read(store.path()).unwrap();
        assert!(
            !encrypted
                .windows(b"fixture-secret".len())
                .any(|w| w == b"fixture-secret")
        );
        assert!(Record::decode(&encrypted).is_err()); // legacy reader cannot interpret ciphertext
        assert_eq!(
            store.load(&RuntimeHints::default()).unwrap().session_id,
            "fixture-session"
        );
        let mut refreshed = record.clone();
        refreshed.session_secret = "fixture-refreshed".into();
        store.save(&refreshed).unwrap();
        assert_eq!(
            store.load(&RuntimeHints::default()).unwrap().session_secret,
            "fixture-refreshed"
        );
        let encrypted = fs::read(store.path()).unwrap();
        let wrong = RecordStore::open_with_key(dir.path(), &cfg, Some(key(8))).unwrap();
        assert!(wrong.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), encrypted);
        let mut corrupt = encrypted.clone();
        *corrupt.last_mut().unwrap() ^= 1;
        fs::write(store.path(), &corrupt).unwrap();
        assert!(store.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), corrupt);
        fs::write(store.path(), legacy).unwrap();
        let absent = RecordStore::open_with_key(dir.path(), &cfg, None).unwrap();
        assert!(absent.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), legacy);
        fs::write(store.path(), b"{broken").unwrap();
        assert!(store.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), b"{broken");
    }

    #[test]
    fn migrated_session_survives_new_store_and_reconstructed_key() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let (path, expected, ciphertext) = {
            let store = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
            let legacy = br#"{"install_id":"reopen-install","session_id":"reopen-session","session_secret":"reopen-secret","expires_at":"2099-01-01T00:00:00Z"}"#;
            fs::write(store.path(), legacy).unwrap();
            let migrated = store.load(&RuntimeHints::default()).unwrap();
            let ciphertext = fs::read(store.path()).unwrap();
            assert!(ciphertext.starts_with(MAGIC));
            (
                store.path().to_owned(),
                serde_json::to_value(&migrated).unwrap(),
                ciphertext,
            )
        }; // Drop the original store and its only master-key Arc.

        let reopened = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
        let restored = reopened.load(&RuntimeHints::default()).unwrap();
        assert_eq!(serde_json::to_value(&restored).unwrap(), expected);
        assert_eq!(fs::read(path).unwrap(), ciphertext);
    }

    #[cfg(windows)]
    #[test]
    fn migration_replace_failure_preserves_legacy_and_retry_survives_reopen() {
        use std::os::windows::fs::OpenOptionsExt;

        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let store = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
        let legacy = br#"{"install_id":"io-install","session_id":"io-session","session_secret":"io-secret","expires_at":"2099-01-01T00:00:00Z"}"#;
        fs::write(store.path(), legacy).unwrap();
        // Permit reads/writes, but deny FILE_SHARE_DELETE so only replacement
        // fails. This affects a synthetic tempfile, not filesystem permissions.
        let replacement_blocker = fs::OpenOptions::new()
            .read(true)
            .share_mode(0x1 | 0x2)
            .open(store.path())
            .unwrap();
        assert_eq!(fs::read(store.path()).unwrap(), legacy);
        assert!(store.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), legacy);
        assert_eq!(
            fs::read_dir(store.path().parent().unwrap()).unwrap().count(),
            1
        );
        drop(replacement_blocker);

        let migrated = store.load(&RuntimeHints::default()).unwrap();
        assert_eq!(migrated.install_id, "io-install");
        assert_eq!(migrated.session_id, "io-session");
        assert_eq!(migrated.session_secret, "io-secret");
        let expected = serde_json::to_value(&migrated).unwrap();
        let ciphertext = fs::read(store.path()).unwrap();
        assert!(ciphertext.starts_with(MAGIC));
        drop(store);

        let reopened = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
        let restored = reopened.load(&RuntimeHints::default()).unwrap();
        assert_eq!(serde_json::to_value(&restored).unwrap(), expected);
        assert_eq!(fs::read(reopened.path()).unwrap(), ciphertext);
    }

    #[test]
    fn scope_transplant_and_mismatch_preserve_original_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        let store = RecordStore::open_with_key(dir.path(), &cfg, Some(key(7))).unwrap();
        let legacy = br#"{"install_id":"install","session_id":"session","session_secret":"secret","namespace":"fixture"}"#;
        fs::write(store.path(), legacy).unwrap();
        let migrated = store.load(&RuntimeHints::default()).unwrap();
        assert_eq!(migrated.session_secret, "secret");
        let ciphertext = fs::read(store.path()).unwrap();
        let mut other_cfg = cfg.clone();
        other_cfg.base_url = "https://other.invalid".into();
        let other = RecordStore::open_with_key(dir.path(), &other_cfg, Some(key(7))).unwrap();
        fs::write(other.path(), &ciphertext).unwrap();
        assert!(other.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(other.path()).unwrap(), ciphertext);
        let wrong_scope = br#"{"install_id":"install","session_id":"session","session_secret":"secret","namespace":"wrong"}"#;
        fs::write(store.path(), wrong_scope).unwrap();
        assert!(store.load(&RuntimeHints::default()).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), wrong_scope);
    }

    #[test]
    fn base_url_comparison_only_folds_host_and_scheme_case() {
        assert!(same_base_url(
            "https://EXAMPLE.invalid/Case",
            "HTTPS://example.invalid/Case"
        ));
        assert!(!same_base_url(
            "https://example.invalid/Case",
            "https://example.invalid/case"
        ));
        assert!(!same_base_url(
            "https://example.invalid/Case?A=1",
            "https://example.invalid/Case?a=1"
        ));
        assert!(!same_base_url(
            "https://example.invalid/Case",
            "https://other.invalid/Case"
        ));
    }
}

impl<'de> Deserialize<'de> for RuntimeHints {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        struct Fields;
        impl<'de> serde::de::Visitor<'de> for Fields {
            type Value = RuntimeHints;
            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a runtime state object")
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                Ok(RuntimeHints::default())
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> Result<Self::Value, A::Error> {
                let mut result = RuntimeHints::default();
                while let Some(key) = map.next_key::<String>()? {
                    if key.eq_ignore_ascii_case("d") {
                        if let Some(value) = map.next_value::<Option<String>>()? {
                            result.default = value;
                        }
                    } else if key.eq_ignore_ascii_case("s") {
                        match map.next_value::<Option<BTreeMap<String, Option<String>>>>()? {
                            Some(values) => result.values.extend(
                                values
                                    .into_iter()
                                    .map(|(key, value)| (key, value.unwrap_or_default())),
                            ),
                            None => result.values.clear(),
                        }
                    } else {
                        map.next_value::<serde::de::IgnoredAny>()?;
                    }
                }
                Ok(result)
            }
        }
        decoder.deserialize_any(Fields)
    }
}

impl RuntimeHints {
    pub fn parse(raw: &str) -> Self {
        let mut hints: Self = serde_json::from_str(raw).unwrap_or_default();
        hints.default = normalize_hint(&hints.default);
        hints.values = hints
            .values
            .into_iter()
            .filter_map(|(path, value)| {
                let key = path
                    .trim()
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
                    .to_owned();
                let value = normalize_hint(&value);
                (!key.is_empty() && key != "." && !value.is_empty()).then_some((key, value))
            })
            .collect();
        hints
    }

    fn get(&self, path: &Path) -> &str {
        path.file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| self.values.get(name))
            .map_or(&self.default, String::as_str)
    }
}

fn normalize_hint(value: &str) -> String {
    let value = value.trim().to_lowercase();
    if value.len() == 32 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        value
    } else {
        String::new()
    }
}

fn same_base_url(left: &str, right: &str) -> bool {
    if left == right {
        return true;
    }
    let (Some(a), Some(b)) = (
        mornye_network::url::UrlParts::parse(left),
        mornye_network::url::UrlParts::parse(right),
    ) else {
        return false;
    };
    !a.has_credentials
        && !b.has_credentials
        && !a.hostname.is_empty()
        && a.scheme == b.scheme
        && a.hostname.eq_ignore_ascii_case(&b.hostname)
        && a.port == b.port
        && a.raw_path == b.raw_path
        && a.raw_query == b.raw_query
        && a.force_query == b.force_query
        && a.fragment == b.fragment
}

pub struct RecordStore {
    path: PathBuf,
    config: SignedSession,
    key: Option<Arc<StorageMasterKey>>,
}

/// Ciphertext is prepared and synced before acquiring a cancellation gate.
/// Callers keep the scope/owner locks through preparation and publication.
pub(super) struct PreparedRecordWrite {
    path: PathBuf,
    directory: PathBuf,
    file: Option<tempfile::NamedTempFile>,
}

impl PreparedRecordWrite {
    pub(super) fn commit_with_lease(mut self, lease: &mornye_core::cancellation::RequestLease) -> Result<(), String> {
        // Borrow the Option so cancellation leaves ownership here: neither
        // temporary-file cleanup nor directory sync runs under the lease mutex.
        let published = lease.commit_if_active(|| {
            self.file.take().expect("prepared session ciphertext").persist(&self.path)
        });
        match published {
            Err(_) => Err("session renewal cancelled".into()),
            Ok(Err(_error)) => Err("cannot persist signed session".into()),
            Ok(Ok(file)) => {
                drop(file);
                // Preserve the existing best-effort directory durability policy,
                // outside cancellation's publication critical section.
                if let Ok(directory) = fs::File::open(&self.directory) {
                    let _ = directory.sync_all();
                }
                Ok(())
            }
        }
    }
}

impl RecordStore {
    pub fn open_with_key(
        root: &Path,
        config: &SignedSession,
        key: Option<Arc<StorageMasterKey>>,
    ) -> Result<Self, String> {
        let directory = root.join("signed_sessions");
        if directory
            .symlink_metadata()
            .is_ok_and(|metadata| !metadata.is_dir())
        {
            return Err("invalid signed session directory".into());
        }
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(&directory)
            .map_err(|error| error.to_string())?;
        let directory = fs::canonicalize(directory).map_err(|error| error.to_string())?;
        Ok(Self {
            path: directory.join(protocol::filename(config)?),
            config: config.clone(),
            key,
        })
    }

    /// Opens an existing directory only. Never creates a directory or record.
    pub fn open_existing_with_key(
        root: &Path,
        config: &SignedSession,
        key: Option<Arc<StorageMasterKey>>,
    ) -> Result<Option<Self>, String> {
        let directory = root.join("signed_sessions");
        match fs::symlink_metadata(&directory) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.to_string()),
            Ok(metadata) if !metadata.is_dir() || metadata.file_type().is_symlink() =>
                return Err("invalid signed session directory".into()),
            Ok(_) => (),
        }
        let directory = fs::canonicalize(directory).map_err(|error| error.to_string())?;
        Ok(Some(Self {
            path: directory.join(protocol::filename(config)?),
            config: config.clone(),
            key,
        }))
    }

    /// Reads a session without migration, hints, identity generation or writes.
    /// Legacy plaintext is ineligible and requires an explicit foreground migration.
    pub fn load_existing(&self) -> Result<Option<Record>, String> {
        // Open once with NOFOLLOW/NONBLOCK (or OPEN_REPARSE_POINT on Windows),
        // inspect this handle, then cap the read even if the file grows.
        let mut file = match fs::OpenOptions::new().read(true).nofollow_nonblock().open(&self.path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.to_string()),
            Ok(file) => file,
        };
        let metadata = file.metadata().map_err(|error| error.to_string())?;
        if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 1024 * 1024 {
            return Err("invalid signed session file".into());
        }
        let mut bytes = Zeroizing::new(Vec::new());
        (&mut file).take(1024 * 1024 + 1).read_to_end(&mut bytes).map_err(|error| error.to_string())?;
        if bytes.len() > 1024 * 1024 { return Err("invalid signed session file".into()); }
        if !bytes.starts_with(MAGIC) {
            // Validate only to distinguish corruption, never use or rewrite
            // plaintext credentials on the background renewal path.
            Record::decode(&bytes).map_err(|_| "invalid signed session record")?;
            return Err(LEGACY_REQUIRES_FOREGROUND.into());
        }
        let key = self.key.as_ref().ok_or("signed session master key is not configured")?
            .derive(&protocol::scope(&self.config), "signed-session-v1");
        let plaintext = decrypt(&bytes[MAGIC.len()..], &key)
            .map_err(|_| "invalid or unauthenticated signed session")?;
        let record = Record::decode(&plaintext)
            .map_err(|_| "invalid signed session record")?;
        if (!record.namespace.is_empty() && record.namespace != protocol::namespace(&self.config.namespace))
            || (!record.base_url.is_empty() && !same_base_url(&record.base_url, self.config.base_url.trim()))
            || (!record.app_version.is_empty() && record.app_version != self.config.app_version.trim())
            || (!record.platform.is_empty() && record.platform != self.config.platform.trim()) {
            return Err("signed session scope mismatch".into());
        }
        Ok(Some(record))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Call while holding this scope's coordinator lock. Preserve the legacy
    /// private record format. Existing JSON is migrated only after validation.
    pub fn load(&self, hints: &RuntimeHints) -> Result<Record, String> {
        let key = self
            .key
            .as_ref()
            .ok_or("signed session master key is not configured")?
            .derive(&protocol::scope(&self.config), "signed-session-v1");
        let mut legacy = false;
        let mut record = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => {
                if !metadata.is_file() || metadata.len() > 1024 * 1024 {
                    return Err("invalid signed session file".into());
                }
                let bytes =
                    Zeroizing::new(fs::read(&self.path).map_err(|error| error.to_string())?);
                let plaintext = if bytes.starts_with(MAGIC) {
                    decrypt(&bytes[MAGIC.len()..], &key)
                        .map_err(|_| "invalid or unauthenticated signed session")?
                } else {
                    legacy = true;
                    bytes
                };
                Record::decode(&plaintext)
                    .map_err(|_| "invalid signed session record")?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Record::default(),
            Err(error) => return Err(error.to_string()),
        };
        let mut changed = false;
        if record.install_id.trim().is_empty() {
            record.install_id = hints.get(&self.path).to_owned();
            if record.install_id.is_empty() {
                record.install_id = protocol::random_hex(16)?;
            }
            changed = true;
        }
        // A mismatched legacy scope must never silently clear a live session.
        if (!record.namespace.is_empty()
            && record.namespace != protocol::namespace(&self.config.namespace))
            || (!record.base_url.is_empty()
                && !same_base_url(&record.base_url, self.config.base_url.trim()))
            || (!record.app_version.is_empty()
                && record.app_version != self.config.app_version.trim())
            || (!record.platform.is_empty() && record.platform != self.config.platform.trim())
        {
            return Err("signed session scope mismatch".into());
        }
        // Fill missing legacy scope fields individually without clearing credentials.
        for (field, expected) in [
            (
                &mut record.namespace,
                protocol::namespace(&self.config.namespace),
            ),
            (&mut record.base_url, self.config.base_url.trim().to_owned()),
            (
                &mut record.app_version,
                self.config.app_version.trim().to_owned(),
            ),
            (&mut record.platform, self.config.platform.trim().to_owned()),
        ] {
            if field.is_empty() {
                *field = expected;
                changed = true;
            }
        }
        if changed || legacy {
            self.save(&record)?;
        }
        Ok(record)
    }

    pub fn save(&self, record: &Record) -> Result<(), String> {
        let encoded = self.encode(record)?;
        crate::storage::atomic_write(&self.path, &encoded).map_err(|error| error.to_string())
    }

    pub(super) fn prepare_save(&self, record: &Record) -> Result<PreparedRecordWrite, String> {
        self.prepare_save_with_checkpoint(record, || {})
    }

    fn prepare_save_with_checkpoint(&self, record: &Record, prepared: impl FnOnce()) -> Result<PreparedRecordWrite, String> {
        // A scheduled renewal may replace only an existing regular record.
        let existing = fs::OpenOptions::new().read(true).nofollow_nonblock().open(&self.path)
            .map_err(|_| "existing signed session unavailable")?;
        let metadata = existing.metadata().map_err(|_| "invalid signed session file")?;
        if !metadata.is_file() || metadata.file_type().is_symlink() { return Err("invalid signed session file".into()); }
        let encoded = self.encode(record)?;
        let directory = self.path.parent().ok_or("invalid signed session directory")?.to_owned();
        let mut file = tempfile::Builder::new().prefix(".mornye-").tempfile_in(&directory)
            .map_err(|_| "cannot prepare signed session")?;
        file.write_all(&encoded).map_err(|_| "cannot prepare signed session")?;
        prepared();
        file.as_file().sync_all().map_err(|_| "cannot sync signed session")?;
        Ok(PreparedRecordWrite { path: self.path.clone(), directory, file: Some(file) })
    }

    fn encode(&self, record: &Record) -> Result<Vec<u8>, String> {
        let key = self
            .key
            .as_ref()
            .ok_or("signed session master key is not configured")?
            .derive(&protocol::scope(&self.config), "signed-session-v1");
        let bytes =
            Zeroizing::new(serde_json::to_vec_pretty(record).map_err(|error| error.to_string())?);
        let ciphertext = encrypt(&bytes, &key).map_err(|_| "cannot encrypt signed session")?;
        let mut encoded = Vec::with_capacity(MAGIC.len() + ciphertext.len());
        encoded.extend_from_slice(MAGIC);
        encoded.extend_from_slice(&ciphertext);
        Ok(encoded)
    }
}
