use super::info::summary;
use super::*;
use sha2::{Digest, Sha256};

const LEGACY_SOUNDCLOUD: &[(&str, &str)] = &[
    (
        "manifest.json",
        "2fcf810436da35ae193a13e70761d602fccb0a2bff843e9cfdfdae657620088b",
    ),
    (
        "index.js",
        "aad22a7718d88bbc07fd7dcf6c812898eb63ebb8a824372675795f2041dc2d85",
    ),
    (
        "LICENSE",
        "da7eabb7bafdf7d3ae5e9f223aa5bdc1eece45ac569dc21b3b037520b4464768",
    ),
    (
        "COPYING",
        "fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0",
    ),
    (
        "NOTICE",
        "24104a5727f7d23772f984663e292ab5113c2f6c4df07b8dafd68f2bf4683626",
    ),
];
fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub(super) fn matches_exact_tree(path: &Path, expected: &[(&str, &str)]) -> bool {
    let Ok(root) = fs::symlink_metadata(path) else {
        return false;
    };
    if !root.file_type().is_dir() || root.file_type().is_symlink() {
        return false;
    }
    let Ok(entries) = fs::read_dir(path) else {
        return false;
    };
    let entries: Vec<_> = match entries.collect::<Result<_, _>>() {
        Ok(v) => v,
        Err(_) => return false,
    };
    if entries.len() != expected.len() {
        return false;
    }
    for entry in entries {
        let name = entry.file_name();
        let Some((_, hash)) = expected.iter().find(|(n, _)| name == *n) else {
            return false;
        };
        let Ok(meta) = fs::symlink_metadata(entry.path()) else {
            return false;
        };
        if !meta.file_type().is_file()
            || meta.file_type().is_symlink()
            || meta.len() > 8 * 1024 * 1024
        {
            return false;
        }
        let Ok(mut file) = OpenOptions::new()
            .read(true)
            .nofollow_nonblock()
            .open(entry.path())
        else {
            return false;
        };
        if !file.metadata().is_ok_and(|m| m.is_file()) {
            return false;
        }
        let mut bytes = Vec::new();
        if (&mut file)
            .take(8 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .is_err()
            || bytes.len() > 8 * 1024 * 1024
            || sha256_hex(&bytes) != *hash
        {
            return false;
        }
    }
    true
}

pub(super) fn soundcloud_override(
    entry: &Installed,
    sources: &Path,
    loaded_source: &str,
) -> Option<Arc<str>> {
    if entry.manifest.name != "soundcloud"
        || entry.manifest.version != "1.0.14"
        || entry.source != sources.join("soundcloud")
        || sha256_hex(entry.manifest_json.as_bytes()) != LEGACY_SOUNDCLOUD[0].1
        || sha256_hex(loaded_source.as_bytes()) != LEGACY_SOUNDCLOUD[1].1
        || !matches_exact_tree(&entry.source, LEGACY_SOUNDCLOUD)
    {
        return None;
    }
    static SOURCE: std::sync::OnceLock<Option<Arc<str>>> = std::sync::OnceLock::new();
    SOURCE
        .get_or_init(|| {
            let archive =
                include_bytes!("../../../../../assets/bundled_extensions/soundcloud.sflx");
            if sha256_hex(archive)
                != "0734a8f4868cbe5e70d5ec11edc70a50103acb107b20509978e3f51e03c68afa"
            {
                return None;
            }
            let mut zip = zip::ZipArchive::new(std::io::Cursor::new(archive)).ok()?;
            let mut manifest = String::new();
            zip.by_name("manifest.json")
                .ok()?
                .read_to_string(&mut manifest)
                .ok()?;
            let parsed = ExtensionManifest::parse(&manifest).ok()?;
            if parsed.name != "soundcloud" || parsed.version != "1.0.18" {
                return None;
            }
            let mut old_manifest: Value = serde_json::from_str(&entry.manifest_json).ok()?;
            let mut new_manifest: Value = serde_json::from_str(&manifest).ok()?;
            old_manifest.as_object_mut()?.remove("version");
            new_manifest.as_object_mut()?.remove("version");
            if old_manifest != new_manifest {
                return None;
            }
            let mut source = String::new();
            zip.by_name("index.js")
                .ok()?
                .take(8 * 1024 * 1024 + 1)
                .read_to_string(&mut source)
                .ok()?;
            if source.len() > 8 * 1024 * 1024 {
                return None;
            }
            Some(Arc::<str>::from(source))
        })
        .clone()
}

impl ExtensionManager {
    pub fn install(&self, path: &Path) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| error(e.to_string()))?;
        self.install_or_upgrade(package)
    }

    pub(super) fn install_or_upgrade(
        &self,
        package: ExtensionPackage,
    ) -> Result<String, ManagerError> {
        self.check_bundle_mutation(&package.manifest.name)?;
        let existing = self
            .entries
            .lock()
            .expect("extension manager lock")
            .get(&package.manifest.name)
            .cloned();
        if let Some(existing) = existing {
            match compare_versions(&package.manifest.version, &existing.manifest.version) {
                Comparison::Greater => return self.upgrade_package(package, existing),
                Comparison::Equal => {
                    return Err(error(format!(
                        "extension '{}' v{} is already installed",
                        existing.manifest.display_name, existing.manifest.version
                    )));
                }
                Comparison::Less => {
                    return Err(error(format!(
                        "cannot downgrade '{}' from v{} to v{}",
                        existing.manifest.display_name,
                        existing.manifest.version,
                        package.manifest.version
                    )));
                }
            }
        }
        self.install_package(package)
    }

    fn stage(
        &self,
        package: &mut ExtensionPackage,
        kind: &str,
    ) -> Result<tempfile::TempDir, ManagerError> {
        let stage = tempfile::Builder::new()
            .prefix(&format!(".{}-{kind}-", package.manifest.name))
            .tempdir_in(&self.sources)
            .map_err(|e| cause("failed to create extension staging directory", e))?;
        package
            .extract(stage.path(), &|| self.check().map_err(|e| e.to_string()))
            .map_err(|e| error(e.to_string()))?;
        Ok(stage)
    }

    fn candidate(&self, package: &ExtensionPackage, path: &Path, enabled: bool) -> Arc<Installed> {
        Arc::new(Installed {
            manifest: package.manifest.clone(),
            manifest_json: package.manifest_json.clone(),
            source: path.to_owned(),
            status: RwLock::new(Status {
                enabled,
                error: String::new(),
            }),
            engine: Mutex::default(),
            downloads: Mutex::default(),
        })
    }

    fn install_package(&self, mut package: ExtensionPackage) -> Result<String, ManagerError> {
        let target = self.sources.join(&package.manifest.name);
        if fs::symlink_metadata(&target).is_ok() {
            return Err(error(format!(
                "extension directory already exists for {:?}",
                package.manifest.name
            )));
        }
        let stage = self.stage(&mut package, "install")?;
        let mut candidate = self.candidate(&package, stage.path(), true);
        if let Err(error) = self.validate(&candidate) {
            self.failed(&candidate, &error);
        }
        self.check()?;
        fs::rename(stage.path(), &target).map_err(|e| cause("failed to activate extension", e))?;
        Arc::get_mut(&mut candidate)
            .expect("unpublished extension")
            .source = target;
        let enabled = candidate
            .status
            .read()
            .expect("extension status lock")
            .enabled;
        if let Err(error) =
            self.environment
                .set_setting(&candidate.manifest.name, "_enabled", enabled.into())
        {
            self.failed(&candidate, &cause("failed to persist enabled state", error));
        }
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(candidate.manifest.name.clone(), Arc::clone(&candidate));
        Ok(summary(&candidate))
    }

    pub fn remove(&self, id: &str) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check_bundle_mutation(id)?;
        let entry = self.get(id)?;
        if entry.source != self.sources.join(id) {
            return Err(error(
                "refusing to remove extension outside the managed source directory",
            ));
        }
        self.mark_bundle_removal(id)?;
        self.unload_locked(id)?;
        // Attempt both roots even if one fails. Keep a disabled registry entry
        // on partial removal so the native caller can retry the same operation.
        let source =
            remove_directory(&entry.source).map_err(|e| cause("failed to remove source dir", e));
        let data = self
            .environment
            .remove_data(id)
            .map_err(error_from_environment);
        let failures: Vec<_> = [source, data].into_iter().filter_map(Result::err).collect();
        if failures.is_empty() {
            Ok(())
        } else {
            let failure = error(
                failures
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("; "),
            );
            self.failed(&entry, &failure);
            self.entries
                .lock()
                .expect("extension manager lock")
                .insert(id.to_owned(), entry);
            Err(failure)
        }
    }

    pub fn upgrade(&self, path: &Path) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| error(e.to_string()))?;
        self.check_bundle_mutation(&package.manifest.name)?;
        let existing = self.get(&package.manifest.name).map_err(|_| {
            error(format!(
                "extension '{}' is not installed; use install instead of upgrade",
                package.manifest.display_name
            ))
        })?;
        self.upgrade_package(package, existing)
    }

    fn upgrade_package(
        &self,
        mut package: ExtensionPackage,
        existing: Arc<Installed>,
    ) -> Result<String, ManagerError> {
        match compare_versions(&package.manifest.version, &existing.manifest.version) {
            Comparison::Less => {
                return Err(error(format!(
                    "cannot downgrade extension: current version: {}, new version: {}",
                    existing.manifest.version, package.manifest.version
                )));
            }
            Comparison::Equal => {
                return Err(error(format!(
                    "extension is already at version {}",
                    existing.manifest.version
                )));
            }
            Comparison::Greater => {}
        }
        let target = self.sources.join(&existing.manifest.name);
        let stage = self.stage(&mut package, "upgrade")?;
        let enabled = existing
            .status
            .read()
            .expect("extension status lock")
            .enabled;
        let mut candidate = self.candidate(&package, stage.path(), enabled);
        let valid = if enabled {
            self.ready(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
                true,
            )
            .map(|_| ())
        } else {
            self.validate(&candidate)
        };
        if let Err(error) = valid {
            return Err(cause("upgraded extension failed validation", error));
        }
        let backup = (|| {
            self.check()?;
            let backup = tempfile::Builder::new()
                .prefix(&format!(".{}-backup-", existing.manifest.name))
                .tempdir_in(&self.sources)
                .map_err(|e| cause("failed to prepare upgrade backup", e))?;
            fs::remove_dir(backup.path())
                .map_err(|e| cause("failed to prepare upgrade backup", e))?;
            Ok(backup)
        })()
        .inspect_err(|_: &ManagerError| {
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
        })?;
        if let Err(error) = fs::rename(&target, backup.path()) {
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
            return Err(cause("failed to preserve current extension", error));
        }
        if let Err(error) = fs::rename(stage.path(), &target) {
            let restored = fs::rename(backup.path(), &target);
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
            if let Err(rollback) = restored {
                let path = backup.keep();
                return Err(error_from_rollback(error, rollback, &path));
            }
            return Err(cause("failed to activate upgraded extension", error));
        }
        Arc::get_mut(&mut candidate)
            .expect("unpublished extension")
            .source = target;
        existing
            .status
            .write()
            .expect("extension status lock")
            .enabled = false;
        self.teardown(
            &existing,
            &mut existing.engine.lock().expect("extension engine lock"),
        );
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(candidate.manifest.name.clone(), Arc::clone(&candidate));
        Ok(summary(&candidate))
    }

    pub fn check_upgrade(&self, path: &Path) -> Result<String, ManagerError> {
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| {
            if e.0.starts_with("cannot open extension file:") {
                error("cannot open extension file")
            } else {
                error(e.to_string())
            }
        })?;
        let entries = self.entries.lock().expect("extension manager lock");
        let existing = entries.get(&package.manifest.name);
        Ok(json!({"extension_id":package.manifest.name,"current_version":existing.map_or("", |entry| entry.manifest.version.as_str()),"new_version":package.manifest.version,"is_installed":existing.is_some(),"can_upgrade":existing.is_some_and(|entry| compare_versions(&package.manifest.version, &entry.manifest.version)==Comparison::Greater)}).to_string())
    }
}

fn error_from_rollback(
    error: std::io::Error,
    rollback: std::io::Error,
    path: &Path,
) -> ManagerError {
    cause(
        "failed to activate upgraded extension",
        format!(
            "{error}; restore failed: {rollback}; previous source preserved at {}",
            path.display()
        ),
    )
}
fn remove_directory(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod bundled_tests {
    use super::*;

    #[test]
    fn embedded_soundcloud_bundle_matches_verified_release() {
        let archive = include_bytes!("../../../../../assets/bundled_extensions/soundcloud.sflx");
        assert_eq!(
            sha256_hex(archive),
            "0734a8f4868cbe5e70d5ec11edc70a50103acb107b20509978e3f51e03c68afa"
        );
    }

    fn fixture_manager(dir: &Path) -> ExtensionManager {
        ExtensionManager::new(
            &dir.join("sources"),
            &dir.join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "9.0.0",
            RuntimeLimits::default(),
        )
        .unwrap()
    }

    #[test]
    #[ignore = "requires explicitly supplied release APK fixture"]
    fn legacy_startup_validation_preserves_preexisting_state() {
        use crate::storage::{ExtensionStore, StorageMasterKey, StoreKind};
        let old = PathBuf::from(std::env::var_os("MUSA_LEGACY_SOUNDCLOUD_FIXTURE").unwrap());
        assert_eq!(
            sha256_hex(&fs::read(&old).unwrap()),
            "1f0d062fcd604c226655104d494a5efeded60545e4db6c8c0ae10ed66656b72d"
        );
        let mut changed_after_cleanup = 0;
        for (enabled, settings, cached) in
            [(true, true), (true, false), (false, true), (false, false)]
                .into_iter()
                .flat_map(|(enabled, settings)| {
                    [
                r#"{"clientId":"fixture","clientIdExpiry":4102444800000,"scVersion":"saved"}"#,
                r#"{"clientId":"fixture","clientIdExpiry":1}"#,
                "malformed",
            ].into_iter().map(move |cached| (enabled, settings, cached))
                })
        {
            let dir = tempfile::tempdir().unwrap();
            let source = dir.path().join("sources/soundcloud");
            fs::create_dir_all(&source).unwrap();
            let mut archive = zip::ZipArchive::new(File::open(&old).unwrap()).unwrap();
            for (name, _) in LEGACY_SOUNDCLOUD {
                let mut entry = archive.by_name(name).unwrap();
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes).unwrap();
                fs::write(source.join(name), bytes).unwrap();
            }
            assert!(matches_exact_tree(&source, LEGACY_SOUNDCLOUD));
            let key = StorageMasterKey::from_base64("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
                .unwrap();
            let store = ExtensionStore::open(
                &dir.path().join("data/soundcloud"),
                "soundcloud",
                Some(Arc::new(key)),
            )
            .unwrap();
            let original = json!(cached);
            store
                .set(StoreKind::Storage, "sc_state", original.clone())
                .unwrap();
            store
                .set(StoreKind::Settings, "_enabled", json!(enabled))
                .unwrap();
            if settings {
                store
                    .set(StoreKind::Settings, "fixture", json!("retained"))
                    .unwrap();
            }
            let manager = fixture_manager(dir.path());
            manager.load_all().unwrap();
            let entry = manager.get("soundcloud").unwrap();
            assert_eq!(entry.status.read().unwrap().enabled, enabled);
            assert!(entry.status.read().unwrap().error.is_empty());
            assert_eq!(
                store.get(StoreKind::Storage, "sc_state").unwrap(),
                Some(original.clone()),
                "validation modified cached state"
            );
            manager.set_enabled("soundcloud", true).unwrap();
            assert_eq!(
                store.get(StoreKind::Storage, "sc_state").unwrap(),
                Some(original.clone()),
                "enabling modified cached state"
            );
            manager.set_enabled("soundcloud", false).unwrap();
            if store.get(StoreKind::Storage, "sc_state").unwrap() != Some(original) {
                changed_after_cleanup += 1;
            }
        }
        assert_eq!(changed_after_cleanup, 0);
    }

    #[test]
    #[ignore = "requires explicitly supplied release APK fixture"]
    fn legacy_source_override_requires_exact_registered_tree() {
        let old = PathBuf::from(std::env::var_os("MUSA_LEGACY_SOUNDCLOUD_FIXTURE").unwrap());
        for custom in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().join("sources/soundcloud");
            fs::create_dir_all(&root).unwrap();
            let mut archive = zip::ZipArchive::new(File::open(&old).unwrap()).unwrap();
            for (name, _) in LEGACY_SOUNDCLOUD {
                let mut entry = archive.by_name(name).unwrap();
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes).unwrap();
                fs::write(root.join(name), bytes).unwrap();
            }
            if custom {
                fs::write(root.join("custom"), b"user").unwrap();
            }
            let manager = fixture_manager(dir.path());
            manager.load_all().unwrap();
            let entry = manager.get("soundcloud").unwrap();
            let old_source = fs::read_to_string(root.join("index.js")).unwrap();
            assert!(!entry.status.read().unwrap().enabled);
            manager.update_settings("soundcloud", Map::new()).unwrap();
            assert!(!entry.status.read().unwrap().enabled);
            manager.set_enabled("soundcloud", true).unwrap();
            let entry = manager.get("soundcloud").unwrap();
            let engine = entry.engine.lock().unwrap();
            let actual = engine.source.as_ref().unwrap();
            if custom {
                assert_eq!(&**actual, old_source);
            } else {
                assert_ne!(&**actual, old_source);
                let mut bundle = zip::ZipArchive::new(std::io::Cursor::new(include_bytes!(
                    "../../../../../assets/bundled_extensions/soundcloud.sflx"
                )))
                .unwrap();
                let mut expected = String::new();
                bundle
                    .by_name("index.js")
                    .unwrap()
                    .read_to_string(&mut expected)
                    .unwrap();
                assert_eq!(&**actual, expected);
                let primary = engine.runtime.as_ref().unwrap();
                let isolated = manager
                    .environment
                    .load_isolated(
                        &entry.manifest_json,
                        actual,
                        RuntimeLimits::default(),
                        primary,
                    )
                    .unwrap();
                assert_eq!(&*isolated.shared_source(), expected);
                isolated.shutdown();
            }
            assert_eq!(entry.manifest.version, "1.0.14");
            drop(engine);
            if !custom {
                let response = manager
                    .call(
                        "soundcloud",
                        "checkAvailability",
                        r#"[null,"","",{"track":{"id":"12345","provider_id":"spotify"}}]"#,
                        None,
                        0,
                    )
                    .unwrap();
                assert!(response.contains("No search query"));
            }
        }
    }

    #[test]
    fn exact_tree_rejects_extras_and_changed_files() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("one"), b"expected").unwrap();
        let digest = sha256_hex(b"expected");
        let expected = [("one", digest.as_str())];
        assert!(matches_exact_tree(dir.path(), &expected));
        fs::write(dir.path().join("extra"), b"x").unwrap();
        assert!(!matches_exact_tree(dir.path(), &expected));
        fs::remove_file(dir.path().join("extra")).unwrap();
        fs::write(dir.path().join("one"), b"changed").unwrap();
        assert!(!matches_exact_tree(dir.path(), &expected));
    }

    #[cfg(unix)]
    #[test]
    fn exact_tree_rejects_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::NamedTempFile::new().unwrap();
        std::os::unix::fs::symlink(outside.path(), dir.path().join("one")).unwrap();
        let digest = sha256_hex(b"");
        assert!(!matches_exact_tree(dir.path(), &[("one", digest.as_str())]));
    }
}
