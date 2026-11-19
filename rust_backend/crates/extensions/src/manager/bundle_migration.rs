use super::install::matches_exact_tree;
use super::*;
use sha2::{Digest, Sha256};

const ROOT: &str = ".musa-bundle-migration";
const FILES: [&str; 5] = ["manifest.json", "index.js", "LICENSE", "COPYING", "NOTICE"];
const LEGAL: [&str; 3] = [
    "da7eabb7bafdf7d3ae5e9f223aa5bdc1eece45ac569dc21b3b037520b4464768",
    "fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0",
    "24104a5727f7d23772f984663e292ab5113c2f6c4df07b8dafd68f2bf4683626",
];

struct Update {
    id: &'static str,
    old_version: &'static str,
    new_version: &'static str,
    archive: &'static [u8],
    digest: &'static str,
    old: [&'static str; 2],
    new: [&'static str; 2],
}

const UPDATES: &[Update] = &[
    Update {
        id: "amazon",
        old_version: "2.3.16",
        new_version: "2.3.19",
        archive: include_bytes!("../../../../../assets/bundled_extensions/amzn.sflx"),
        digest: "5177325613ad65b9475aa02e8befb651b68a324d465f04869f2906f5f59044ec",
        old: [
            "544271d1814788a709d0d395253452f4e95ce21b3e2687d6e982b158705fb671",
            "5a67df17dced9e755ab5686751364e03b9d83c7172d6abcf7fd38db6a65c70b7",
        ],
        new: [
            "a726d428531598e1e69ae983f06306490766a6ac086c11ed88dec05458ffe647",
            "a526dcac985989cc3b3ac02463cb15a6f0f55c880d38083215ec6c384f9da03c",
        ],
    },
    Update {
        id: "deezer",
        old_version: "1.3.10",
        new_version: "1.3.11",
        archive: include_bytes!("../../../../../assets/bundled_extensions/deezer.sflx"),
        digest: "298c44d77e04f5b29609eb2068153f23e418b9055c44b219ac5db9888e0e5c34",
        old: [
            "440967a2dd6d47c2a037a3f9f4ac97e7e32f98442b788a51b525a96933b84cfa",
            "9177c1bd24f36de26760cd1875064033e6a10159fbf9c90e296eef8a9db34d43",
        ],
        new: [
            "3a9f236737a37fa4f4584b79232ecfbc48dfd66177701ed87089c40fec694db9",
            "2dbd51395e4d70f819e915693dfd41d076215d1180da765536c0e9aec89c20db",
        ],
    },
    Update {
        id: "tidal-web",
        old_version: "1.2.12",
        new_version: "1.2.14",
        archive: include_bytes!("../../../../../assets/bundled_extensions/tidal-web.sflx"),
        digest: "0f23f034b2f38e72d07abccb974eb7d39cf409c5659735e5745380ffe2816094",
        old: [
            "66069bc16c7563087a2259f46bf1e49ed3f0208e8ba854fd37ecbf7f6b749d5c",
            "fefe79ce01e5ff6ba27197f42a31aa835f495910b456338f9be183e979c0c878",
        ],
        new: [
            "35f1e7b95546b93659767c51ecd65d7e6a349046ca2a86356eb7edf9b81dc001",
            "84dc8aef4897219e31f44da13dfde8bac10b45ae62c3c3f7ecf7f0c903c2e0a4",
        ],
    },
];

fn fingerprint([manifest, script]: [&str; 2]) -> [(&str, &str); 5] {
    [
        (FILES[0], manifest),
        (FILES[1], script),
        (FILES[2], LEGAL[0]),
        (FILES[3], LEGAL[1]),
        (FILES[4], LEGAL[2]),
    ]
}

fn path_type(path: &Path) -> std::io::Result<Option<fs::FileType>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err(std::io::Error::other("unexpected reparse point"));
                }
            }
            Ok(Some(metadata.file_type()))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn directory(path: &Path) -> std::io::Result<bool> {
    match path_type(path)? {
        None => Ok(false),
        Some(kind) if kind.is_dir() && !kind.is_symlink() => Ok(true),
        Some(_) => Err(std::io::Error::other("unexpected transaction path type")),
    }
}

fn single_link(path: &Path) -> std::io::Result<bool> {
    let file = OpenOptions::new()
        .read(true)
        .nofollow_nonblock()
        .open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(file.metadata()?.nlink() == 1)
    }
    #[cfg(windows)]
    {
        Ok(winx::winapi_util::file::information(&file)?.number_of_links() == 1)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = file;
        Ok(false)
    }
}

fn recognized(path: &Path, expected: [&str; 2]) -> bool {
    directory(path).is_ok_and(|exists| exists)
        && FILES.iter().all(|name| {
            let file = path.join(name);
            path_type(&file).is_ok_and(|kind| kind.is_some_and(|kind| kind.is_file()))
                && single_link(&file).is_ok_and(|single| single)
        })
        && matches_exact_tree(path, &fingerprint(expected))
}

#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
fn rename_new(source: &Path, destination: &Path) -> std::io::Result<()> {
    use rustix::fs::{CWD, RenameFlags, renameat_with};
    renameat_with(CWD, source, CWD, destination, RenameFlags::NOREPLACE).map_err(Into::into)
}

#[cfg(windows)]
#[allow(unsafe_code)]
fn rename_new(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::MoveFileExW;
    fn wide(path: &Path) -> std::io::Result<Vec<u16>> {
        let mut wide: Vec<_> = path.as_os_str().encode_wide().collect();
        if wide.contains(&0) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "NUL in path",
            ));
        }
        wide.push(0);
        Ok(wide)
    }
    let source = wide(source)?;
    let destination = wide(destination)?;
    // SAFETY: These owned, NUL-terminated buffers outlive the call. Omitting
    // replacement and copying keeps this an exclusive same-volume rename.
    if unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), 0) } == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(any(
    windows,
    target_os = "linux",
    target_os = "android",
    target_vendor = "apple"
)))]
fn rename_new(_: &Path, _: &Path) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

fn directory_identity(path: &Path) -> std::io::Result<String> {
    if !directory(path)? {
        return Err(std::io::ErrorKind::NotFound.into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.is_dir() || metadata.is_symlink() || metadata.ino() == 0 {
            return Err(std::io::Error::other("unexpected directory identity"));
        }
        Ok(format!("{:016x}:{:016x}", metadata.dev(), metadata.ino()))
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_OPEN_REPARSE_POINT,
        };
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)?;
        let metadata = winx::winapi_util::file::information(&file)?;
        let attributes = metadata.file_attributes();
        if attributes & u64::from(FILE_ATTRIBUTE_DIRECTORY) == 0
            || attributes & u64::from(FILE_ATTRIBUTE_REPARSE_POINT) != 0
            || metadata.file_index() == 0
        {
            return Err(std::io::Error::other("unexpected directory identity"));
        }
        Ok(format!(
            "{:016x}:{:016x}",
            metadata.volume_serial_number(),
            metadata.file_index()
        ))
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err(std::io::ErrorKind::Unsupported.into())
    }
}

struct Transaction {
    target: PathBuf,
    root: PathBuf,
    stage: PathBuf,
    backup: PathBuf,
    journal: PathBuf,
    source_id: PathBuf,
    committed: PathBuf,
    conflicted: PathBuf,
    removed: PathBuf,
}

impl Transaction {
    fn new(sources: &Path, update: &Update) -> Self {
        let root = sources
            .join(ROOT)
            .join(format!("{}-{}", update.id, update.new_version));
        Self {
            target: sources.join(update.id),
            stage: root.join("stage"),
            backup: root.join("backup"),
            journal: root.join("prepared"),
            source_id: root.join("source-id"),
            committed: root.join("committed"),
            conflicted: root.join("conflicted"),
            removed: root.join("removed"),
            root,
        }
    }

    fn marker(update: &Update) -> String {
        format!(
            "musa-bundle-v1\n{}\n{}\n{}\n{}\n",
            update.id, update.old_version, update.new_version, update.digest
        )
    }

    fn verify_journal(&self, update: &Update) -> std::io::Result<()> {
        Self::verify_marker(&self.journal, update)
    }

    fn verify_marker(path: &Path, update: &Update) -> std::io::Result<()> {
        let expected = Self::marker(update);
        let file = OpenOptions::new()
            .read(true)
            .nofollow_nonblock()
            .open(path)?;
        if !file.metadata()?.is_file() {
            return Err(std::io::Error::other("invalid bundle journal"));
        }
        let mut content = Vec::new();
        file.take(expected.len() as u64 + 1)
            .read_to_end(&mut content)?;
        if content != expected.as_bytes() {
            return Err(std::io::Error::other("invalid bundle journal"));
        }
        Ok(())
    }

    // Only these five flat files may be left by an interrupted extraction or
    // cleanup. No recursive deletion and no following links.
    fn discard(path: &Path) -> std::io::Result<()> {
        if !directory(path)? {
            return Ok(());
        }
        let entries = fs::read_dir(path)?.collect::<Result<Vec<_>, _>>()?;
        for entry in &entries {
            if !FILES.iter().any(|name| entry.file_name() == *name)
                || !path_type(&entry.path())?.is_some_and(|kind| kind.is_file())
            {
                return Err(std::io::Error::other("unexpected bundle transaction entry"));
            }
        }
        for entry in entries {
            fs::remove_file(entry.path())?;
        }
        fs::remove_dir(path)
    }

    fn remember_source(&self) -> std::io::Result<()> {
        let identity = directory_identity(&self.target)?;
        crate::storage::atomic_write(&self.source_id, identity.as_bytes())
            .map_err(std::io::Error::other)
    }

    fn backup_is_moved_source(&self) -> std::io::Result<bool> {
        let identity = directory_identity(&self.backup)?;
        let file = OpenOptions::new()
            .read(true)
            .nofollow_nonblock()
            .open(&self.source_id)?;
        if !file.metadata()?.is_file() {
            return Err(std::io::Error::other("invalid bundle source identity"));
        }
        let mut recorded = Vec::new();
        file.take(identity.len() as u64 + 1)
            .read_to_end(&mut recorded)?;
        Ok(recorded == identity.as_bytes())
    }

    fn terminal(&self, update: &Update) -> bool {
        Self::verify_marker(&self.committed, update).is_ok()
            || Self::verify_marker(&self.conflicted, update).is_ok()
            || Self::verify_marker(&self.removed, update).is_ok()
    }

    fn publish_marker(path: &Path, update: &Update) -> std::io::Result<()> {
        crate::storage::atomic_write(path, Self::marker(update).as_bytes())
            .map_err(std::io::Error::other)
    }

    fn recover(&self, update: &Update) -> std::io::Result<()> {
        if self.terminal(update) {
            return Ok(());
        }
        let backup = directory(&self.backup)?;
        if directory(&self.target)? {
            if backup {
                if recognized(&self.target, update.new)
                    && recognized(&self.backup, update.old)
                    && self.backup_is_moved_source()?
                {
                    return Self::publish_marker(&self.committed, update);
                }
                // Canonical source won the race. Keep both trees, and let
                // ordinary user operations manage the canonical one later.
                Self::publish_marker(&self.conflicted, update)?;
                return Err(std::io::Error::other(
                    "bundled update conflict; backup retained",
                ));
            }
            if recognized(&self.target, update.old) {
                Self::discard(&self.stage)?;
            }
        } else if backup {
            if !self.backup_is_moved_source()? {
                return Err(std::io::Error::other(
                    "bundle recovery backup is not recognized",
                ));
            }
            if let Err(error) = rename_new(&self.backup, &self.target) {
                if directory(&self.target).is_ok_and(|exists| exists) {
                    Self::publish_marker(&self.conflicted, update)?;
                }
                return Err(error);
            }
            Self::discard(&self.stage)?;
        } else {
            return Err(std::io::Error::other(
                "bundle source and recovery backup are missing",
            ));
        }
        Ok(())
    }

    fn prepare(&self, update: &Update, app_version: &str) -> Result<(), ManagerError> {
        if crate::binary::encode(&Sha256::digest(update.archive), "hex").expect("hex encoding")
            != update.digest
            || compare_versions(update.new_version, update.old_version) != Comparison::Greater
        {
            return Err(error("bundled update checksum or version mismatch"));
        }
        use std::io::Write;
        let mut archive = tempfile::Builder::new()
            .suffix(".sflx")
            .tempfile_in(&self.root)
            .map_err(|e| cause("cannot stage bundled archive", e))?;
        archive
            .write_all(update.archive)
            .map_err(|e| cause("cannot write bundled archive", e))?;
        let mut package =
            ExtensionPackage::open(archive.path()).map_err(|e| error(e.to_string()))?;
        if package.manifest.name != update.id || package.manifest.version != update.new_version {
            return Err(error("bundled archive identity mismatch"));
        }
        validate_gates(&package.manifest, app_version, &SUPPORTED_RUNTIME_FEATURES)
            .map_err(error)?;
        fs::create_dir(&self.stage).map_err(|e| cause("cannot create bundle stage", e))?;
        package
            .extract(&self.stage, &|| Ok(()))
            .map_err(|e| error(e.to_string()))?;
        if !recognized(&self.stage, update.new) {
            return Err(error("bundled update tree mismatch"));
        }
        Ok(())
    }
}

impl ExtensionManager {
    // Called with the manager mutation mutex and directory lock. New updates
    // run at startup only. Existing journals remain visible on warm reloads.
    pub(super) fn migrate_known_bundles(&self) -> Vec<String> {
        let startup = self
            .entries
            .lock()
            .expect("extension manager lock")
            .is_empty();
        UPDATES
            .iter()
            .filter_map(|update| {
                let result = if startup {
                    self.migrate_known_bundle(update)
                } else {
                    let loaded = self
                        .entries
                        .lock()
                        .expect("extension manager lock")
                        .contains_key(update.id);
                    self.recover_known_bundle(update, loaded)
                };
                result
                    .err()
                    .map(|_| format!("{}: bundled update could not complete", update.id))
            })
            .collect()
    }

    // Do not let bootstrap recreate a missing target (or a user remove it)
    // while the pre-update source is still awaiting recovery.
    pub(super) fn check_bundle_mutation(&self, id: &str) -> Result<(), ManagerError> {
        let Some(update) = UPDATES.iter().find(|update| update.id == id) else {
            return Ok(());
        };
        let tx = Transaction::new(&self.sources, update);
        let io = |e| cause("bundled update transaction", e);
        if directory(&self.sources.join(ROOT)).map_err(io)?
            && directory(&tx.root).map_err(io)?
            && !tx.terminal(update)
            && (path_type(&tx.backup).map_err(io)?.is_some()
                || (path_type(&tx.target).map_err(io)?.is_none()
                    && tx.verify_journal(update).is_ok()))
        {
            return Err(error(
                "bundled update must recover before modifying this provider",
            ));
        }
        Ok(())
    }

    // Persist the user's removal decision before the source can disappear.
    // A crash before deletion leaves the existing source usable and removable.
    pub(super) fn mark_bundle_removal(&self, id: &str) -> Result<(), ManagerError> {
        let Some(update) = UPDATES.iter().find(|update| update.id == id) else {
            return Ok(());
        };
        let tx = Transaction::new(&self.sources, update);
        let io = |e| cause("bundled update transaction", e);
        if !directory(&self.sources.join(ROOT)).map_err(io)? || !directory(&tx.root).map_err(io)? {
            return Ok(());
        }
        if tx.verify_journal(update).is_ok() && !tx.terminal(update) {
            Transaction::publish_marker(&tx.removed, update)
                .map_err(|e| cause("cannot record bundled extension removal", e))?;
        }
        Ok(())
    }

    fn recover_known_bundle(&self, update: &Update, loaded: bool) -> Result<(), ManagerError> {
        let tx = Transaction::new(&self.sources, update);
        let io = |e| cause("bundled update transaction", e);
        if !directory(&self.sources.join(ROOT)).map_err(io)? || !directory(&tx.root).map_err(io)? {
            return Ok(());
        }
        if path_type(&tx.journal).map_err(io)?.is_none() {
            if directory(&tx.backup).map_err(io)? || directory(&tx.stage).map_err(io)? {
                return Err(error("bundle transaction is missing its journal"));
            }
            return Ok(());
        }
        tx.verify_journal(update).map_err(io)?;
        if loaded {
            return self.check_bundle_mutation(update.id);
        }
        tx.recover(update).map_err(io)
    }

    fn migrate_known_bundle(&self, update: &Update) -> Result<(), ManagerError> {
        let tx = Transaction::new(&self.sources, update);
        let parent = self.sources.join(ROOT);
        let io = |e| cause("bundled update transaction", e);
        self.recover_known_bundle(update, false)?;
        if tx.terminal(update) {
            return Ok(());
        }
        if !recognized(&tx.target, update.old) || directory(&tx.backup).map_err(io)? {
            return Ok(());
        }
        self.check()?;
        if !directory(&parent).map_err(io)? {
            fs::DirBuilder::new()
                .unix_mode(0o700)
                .create(&parent)
                .map_err(io)?;
        }
        if !directory(&tx.root).map_err(io)? {
            fs::DirBuilder::new()
                .unix_mode(0o700)
                .create(&tx.root)
                .map_err(io)?;
        }
        if path_type(&tx.journal).map_err(io)?.is_none() {
            crate::storage::atomic_write(&tx.journal, Transaction::marker(update).as_bytes())
                .map_err(|e| cause("cannot publish bundle journal", e))?;
        }
        let version = self
            .environment
            .get_app_version()
            .map_err(error_from_environment)?;
        tx.prepare(update, &version)?;
        self.check()?;
        if !recognized(&tx.target, update.old) {
            return Err(error("bundle tree changed during migration"));
        }
        tx.remember_source().map_err(io)?;
        Self::activate(&tx, update, rename_new)
    }

    fn activate(
        tx: &Transaction,
        update: &Update,
        promote: impl FnOnce(&Path, &Path) -> std::io::Result<()>,
    ) -> Result<(), ManagerError> {
        let io = |e| cause("bundled update transaction", e);
        rename_new(&tx.target, &tx.backup).map_err(io)?;
        if !recognized(&tx.backup, update.old) || !tx.backup_is_moved_source().unwrap_or(false) {
            if let Err(error) = rename_new(&tx.backup, &tx.target) {
                tx.recover(update).map_err(io)?;
                return Err(io(error));
            }
            return Err(error("bundle source changed before migration"));
        }
        if let Err(error) = promote(&tx.stage, &tx.target) {
            tx.recover(update).map_err(io)?;
            return Err(io(error));
        }
        tx.recover(update).map_err(io)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_update_corpus_matches_embedded_assets() {
        for update in UPDATES {
            let root = tempfile::tempdir().unwrap();
            let tx = Transaction::new(root.path(), update);
            fs::create_dir_all(&tx.root).unwrap();
            tx.prepare(update, "5.3.1").unwrap();
            assert!(matches_exact_tree(&tx.stage, &fingerprint(update.new)));
        }
    }

    fn old_fixture(sources: &Path) -> (Update, Transaction) {
        let original = &UPDATES[0];
        let mut update = Update { ..*original };
        let tx = Transaction::new(sources, &update);
        fs::create_dir_all(&tx.root).unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        fs::rename(&tx.stage, &tx.target).unwrap();
        let manifest = fs::read_to_string(tx.target.join("manifest.json"))
            .unwrap()
            .replace(update.new_version, update.old_version);
        // If migration ran JS even in validation mode, this fixture would fail.
        let script = b"throw new Error('migration must never run JS')";
        fs::write(tx.target.join("manifest.json"), &manifest).unwrap();
        fs::write(tx.target.join("index.js"), script).unwrap();
        update.old = [
            Box::leak(
                crate::binary::encode(&Sha256::digest(manifest.as_bytes()), "hex")
                    .unwrap()
                    .into_boxed_str(),
            ),
            Box::leak(
                crate::binary::encode(&Sha256::digest(script), "hex")
                    .unwrap()
                    .into_boxed_str(),
            ),
        ];
        (update, tx)
    }

    #[test]
    fn recovery_handles_interruption_on_both_sides_of_each_rename() {
        for renames in 0..=2 {
            let root = tempfile::tempdir().unwrap();
            let (update, tx) = old_fixture(root.path());
            fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
            tx.remember_source().unwrap();
            tx.prepare(&update, "5.3.1").unwrap();
            if renames >= 1 {
                fs::rename(&tx.target, &tx.backup).unwrap();
            }
            if renames == 2 {
                fs::rename(&tx.stage, &tx.target).unwrap();
            }
            let tx = Transaction::new(root.path(), &update);
            tx.verify_journal(&update).unwrap();
            tx.recover(&update).unwrap();
            tx.recover(&update).unwrap();
            assert!(matches_exact_tree(
                &tx.target,
                &fingerprint(if renames == 2 { update.new } else { update.old })
            ));
            assert_eq!(tx.backup.exists(), renames == 2);
            assert!(!tx.stage.exists());
            if renames == 2 {
                Transaction::discard(&tx.target).unwrap();
                tx.recover(&update).unwrap();
                assert!(!tx.target.exists(), "removal must not resurrect the bundle");
            }
        }
    }

    #[test]
    fn failed_promotion_restores_original_package() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        assert!(
            ExtensionManager::activate(&tx, &update, |_, _| Err(std::io::Error::other(
                "injected promotion failure"
            )))
            .is_err()
        );
        assert!(recognized(&tx.target, update.old));
        assert!(!tx.backup.exists());
        assert!(!tx.stage.exists());
    }

    #[test]
    fn migration_preserves_settings_and_does_not_touch_custom_or_removed_packages() {
        for scenario in ["old", "disabled", "custom", "removed", "newer"] {
            let root = tempfile::tempdir().unwrap();
            let manager = ExtensionManager::new(
                &root.path().join("sources"),
                &root.path().join("data"),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "5.3.1",
                RuntimeLimits::default(),
            )
            .unwrap();
            let (update, tx) = old_fixture(&manager.sources);
            let settings = json!({"_enabled":scenario != "disabled","fixture":"keep"});
            manager
                .environment
                .replace_settings(update.id, settings.as_object().unwrap().clone())
                .unwrap();
            match scenario {
                "custom" => fs::write(tx.target.join("index.js"), "custom source").unwrap(),
                "removed" => Transaction::discard(&tx.target).unwrap(),
                "newer" => fs::write(
                    tx.target.join("manifest.json"),
                    r#"{"name":"amazon","version":"99"}"#,
                )
                .unwrap(),
                _ => {}
            }
            manager.migrate_known_bundle(&update).unwrap();
            manager.migrate_known_bundle(&update).unwrap();
            let read = manager.environment.settings(update.id).unwrap();
            assert_eq!(Value::Object(read), settings);
            match scenario {
                "old" | "disabled" => {
                    assert!(matches_exact_tree(&tx.target, &fingerprint(update.new)))
                }
                "custom" => assert_eq!(
                    fs::read_to_string(tx.target.join("index.js")).unwrap(),
                    "custom source"
                ),
                "removed" => assert!(!tx.target.exists()),
                "newer" => assert!(
                    fs::read_to_string(tx.target.join("manifest.json"))
                        .unwrap()
                        .contains("99")
                ),
                _ => unreachable!(),
            }
        }
    }

    #[test]
    fn untrusted_archive_and_journal_do_not_replace_an_installed_tree() {
        let root = tempfile::tempdir().unwrap();
        let (mut update, tx) = old_fixture(root.path());
        update.digest = "wrong";
        assert!(tx.prepare(&update, "5.3.1").is_err());
        assert!(!tx.stage.exists());
        fs::write(&tx.journal, "untrusted").unwrap();
        assert!(tx.verify_journal(&update).is_err());
        assert!(recognized(&tx.target, update.old));
    }

    #[test]
    fn partial_stage_is_discarded_without_touching_original_or_unexpected_files() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        fs::create_dir(&tx.stage).unwrap();
        fs::write(tx.stage.join("manifest.json"), "interrupted").unwrap();
        let unexpected = tx.stage.join("custom.dat");
        fs::write(&unexpected, "preserve").unwrap();
        assert!(tx.recover(&update).is_err());
        assert_eq!(fs::read_to_string(&unexpected).unwrap(), "preserve");
        fs::remove_file(unexpected).unwrap();
        tx.recover(&update).unwrap();
        assert!(!tx.stage.exists());
        assert!(recognized(&tx.target, update.old));
    }

    #[test]
    fn unfinished_recovery_reserves_only_the_affected_provider() {
        let root = tempfile::tempdir().unwrap();
        let manager = ExtensionManager::new(
            &root.path().join("sources"),
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "5.3.1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let update = &UPDATES[0];
        let tx = Transaction::new(&manager.sources, update);
        fs::create_dir_all(&tx.backup).unwrap();
        fs::write(&tx.journal, Transaction::marker(update)).unwrap();
        assert!(manager.check_bundle_mutation(update.id).is_err());
        assert!(manager.check_bundle_mutation(UPDATES[1].id).is_ok());
        assert!(manager.check_bundle_mutation("custom").is_ok());
        fs::write(&tx.committed, Transaction::marker(update)).unwrap();
        assert!(manager.check_bundle_mutation(update.id).is_ok());
    }

    #[test]
    fn racing_empty_custom_target_is_never_replaced_or_locked_permanently() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        assert!(
            ExtensionManager::activate(&tx, &update, |source, target| {
                fs::create_dir(target)?;
                rename_new(source, target)
            })
            .is_err()
        );
        assert_eq!(fs::read_dir(&tx.target).unwrap().count(), 0);
        assert!(recognized(&tx.backup, update.old));
        assert!(tx.terminal(&update));
        fs::remove_dir(&tx.target).unwrap();
        tx.recover(&update).unwrap();
        assert!(!tx.target.exists());
        assert!(recognized(&tx.backup, update.old));
    }

    #[test]
    fn source_changed_after_hash_is_restored_without_replacing_its_contents() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        assert!(recognized(&tx.target, update.old));
        fs::write(tx.target.join("index.js"), "custom source").unwrap();
        assert!(
            ExtensionManager::activate(&tx, &update, |_, _| panic!("must not promote")).is_err()
        );
        assert_eq!(
            fs::read_to_string(tx.target.join("index.js")).unwrap(),
            "custom source"
        );
        assert!(!tx.backup.exists());
    }

    #[test]
    fn changed_backup_is_not_deleted_or_committed() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        rename_new(&tx.target, &tx.backup).unwrap();
        fs::write(tx.backup.join("index.js"), "custom backup").unwrap();
        rename_new(&tx.stage, &tx.target).unwrap();
        assert!(tx.recover(&update).is_err());
        assert!(!tx.committed.exists());
        assert!(tx.terminal(&update));
        assert_eq!(
            fs::read_to_string(tx.backup.join("index.js")).unwrap(),
            "custom backup"
        );
    }

    #[test]
    fn exact_hash_with_extra_hardlink_is_not_eligible() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        assert!(recognized(&tx.target, update.old));
        fs::hard_link(tx.target.join("index.js"), root.path().join("alias")).unwrap();
        assert!(!recognized(&tx.target, update.old));
    }

    #[test]
    fn conflicted_custom_package_still_loads_and_can_be_removed() {
        let root = tempfile::tempdir().unwrap();
        let manager = ExtensionManager::new(
            &root.path().join("sources"),
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "5.3.1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let (update, tx) = old_fixture(&manager.sources);
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        assert!(ExtensionManager::activate(&tx, &update, |source, target| {
            fs::create_dir(target)?;
            fs::write(target.join("manifest.json"), r#"{"name":"amazon","displayName":"Custom","version":"99","description":"fixture","type":["metadata_provider"]}"#)?;
            fs::write(target.join("index.js"), "registerExtension({});")?;
            rename_new(source, target)
        }).is_err());
        manager.load_all().unwrap();
        assert_eq!(
            manager
                .installed_versions()
                .unwrap()
                .get("amazon")
                .map(String::as_str),
            Some("99")
        );
        manager.remove("amazon").unwrap();
        assert!(!tx.target.exists());
        assert!(recognized(&tx.backup, update.old));
        manager.load_all().unwrap();
        assert!(!tx.target.exists());
        assert!(recognized(&tx.backup, update.old));
    }

    #[test]
    fn interrupted_move_restores_same_directory_even_if_edited_after_hash() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        tx.prepare(&update, "5.3.1").unwrap();
        assert!(recognized(&tx.target, update.old));
        fs::write(tx.target.join("index.js"), "custom source").unwrap();
        rename_new(&tx.target, &tx.backup).unwrap();
        let reopened = Transaction::new(root.path(), &update);
        reopened.verify_journal(&update).unwrap();
        reopened.recover(&update).unwrap();
        assert_eq!(
            fs::read_to_string(tx.target.join("index.js")).unwrap(),
            "custom source"
        );
        assert!(!tx.backup.exists());
        assert!(!tx.stage.exists());
    }

    #[test]
    fn interrupted_recovery_never_restores_an_unknown_directory_identity() {
        let root = tempfile::tempdir().unwrap();
        let (update, tx) = old_fixture(root.path());
        fs::write(&tx.journal, Transaction::marker(&update)).unwrap();
        tx.remember_source().unwrap();
        rename_new(&tx.target, &tx.backup).unwrap();
        fs::write(&tx.source_id, "unknown directory identity").unwrap();
        assert!(tx.recover(&update).is_err());
        assert!(!tx.target.exists());
        assert!(recognized(&tx.backup, update.old));
        assert!(!tx.terminal(&update));
    }

    #[test]
    fn repeated_load_reports_pending_recovery_until_missing_provider_is_restored() {
        let root = tempfile::tempdir().unwrap();
        let manager = ExtensionManager::new(
            &root.path().join("sources"),
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "5.3.1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let update = &UPDATES[0];
        let tx = Transaction::new(&manager.sources, update);
        fs::create_dir_all(&tx.root).unwrap();
        fs::create_dir(&tx.target).unwrap();
        let manifest = r#"{"name":"amazon","displayName":"Fixture","version":"2.3.16","description":"fixture","type":["metadata_provider"]}"#;
        fs::write(tx.target.join("manifest.json"), manifest).unwrap();
        fs::write(tx.target.join("index.js"), "registerExtension({});").unwrap();
        fs::write(&tx.journal, Transaction::marker(update)).unwrap();
        tx.remember_source().unwrap();
        let identity = fs::read(&tx.source_id).unwrap();
        rename_new(&tx.target, &tx.backup).unwrap();
        fs::write(&tx.source_id, "unknown identity").unwrap();

        let other = manager.sources.join("fixture");
        fs::create_dir(&other).unwrap();
        fs::write(
            other.join("manifest.json"),
            manifest.replace("amazon", "fixture"),
        )
        .unwrap();
        fs::write(other.join("index.js"), "registerExtension({});").unwrap();

        let load = || serde_json::from_str::<Value>(&manager.load_all().unwrap()).unwrap();
        let first = load();
        let existing = manager.get("fixture").unwrap();
        assert!(first["errors"][0].as_str().unwrap().starts_with("amazon:"));
        let repeat = load();
        assert_eq!(repeat["errors"], first["errors"]);
        assert!(Arc::ptr_eq(&manager.get("fixture").unwrap(), &existing));
        assert!(manager.get("amazon").is_err());

        fs::write(&tx.source_id, identity).unwrap();
        let recovered = load();
        assert_eq!(recovered["errors"], json!([]));
        assert!(manager.get("amazon").is_ok());
        assert!(Arc::ptr_eq(&manager.get("fixture").unwrap(), &existing));
        assert_eq!(load()["errors"], json!([]));
    }

    #[test]
    fn missing_canonical_and_backup_remain_pending_with_or_without_stage() {
        for has_stage in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let manager = ExtensionManager::new(
                &root.path().join("sources"),
                &root.path().join("data"),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "5.3.1",
                RuntimeLimits::default(),
            )
            .unwrap();
            let update = &UPDATES[0];
            let tx = Transaction::new(&manager.sources, update);
            fs::create_dir_all(&tx.root).unwrap();
            fs::write(&tx.journal, Transaction::marker(update)).unwrap();
            if has_stage {
                tx.prepare(update, "5.3.1").unwrap();
            }
            let other = manager.sources.join("fixture");
            fs::create_dir(&other).unwrap();
            fs::write(other.join("manifest.json"), r#"{"name":"fixture","displayName":"Fixture","version":"1","description":"fixture","type":["metadata_provider"]}"#).unwrap();
            fs::write(other.join("index.js"), "registerExtension({});").unwrap();
            let settings = json!({"_enabled":false,"fixture":"keep"});
            manager
                .environment
                .replace_settings(update.id, settings.as_object().unwrap().clone())
                .unwrap();
            for _ in 0..2 {
                let result: Value = serde_json::from_str(&manager.load_all().unwrap()).unwrap();
                assert!(result["errors"][0].as_str().unwrap().starts_with("amazon:"));
                assert!(manager.get("fixture").is_ok());
                assert!(manager.get(update.id).is_err());
            }
            assert!(manager.check_bundle_mutation(update.id).is_err());
            assert_eq!(
                Value::Object(manager.environment.settings(update.id).unwrap()),
                settings
            );
            assert!(!tx.target.exists());
            assert!(!tx.backup.exists());
            assert_eq!(tx.stage.exists(), has_stage);
            if has_stage {
                assert!(recognized(&tx.stage, update.new));
            }
        }
    }

    #[test]
    fn intentional_removal_after_rollback_does_not_leave_pending_recovery() {
        let root = tempfile::tempdir().unwrap();
        let manager = ExtensionManager::new(
            &root.path().join("sources"),
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "5.3.1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let update = &UPDATES[0];
        let tx = Transaction::new(&manager.sources, update);
        fs::create_dir_all(&tx.root).unwrap();
        fs::create_dir(&tx.target).unwrap();
        fs::write(tx.target.join("manifest.json"), r#"{"name":"amazon","displayName":"Fixture","version":"2.3.16","description":"fixture","type":["metadata_provider"]}"#).unwrap();
        fs::write(tx.target.join("index.js"), "registerExtension({});").unwrap();
        fs::write(&tx.journal, Transaction::marker(update)).unwrap();
        tx.remember_source().unwrap();
        rename_new(&tx.target, &tx.backup).unwrap();
        manager.load_all().unwrap();
        assert!(manager.get(update.id).is_ok());
        manager.remove(update.id).unwrap();
        assert!(tx.terminal(update));
        assert!(!tx.target.exists());
        let result: Value = serde_json::from_str(&manager.load_all().unwrap()).unwrap();
        assert_eq!(result["errors"], json!([]));
        assert!(manager.get(update.id).is_err());
    }

    #[cfg(any(unix, windows))]
    #[test]
    fn bundle_removal_does_not_follow_linked_transaction_parents() {
        fn link_directory(link: &Path, target: &Path) {
            #[cfg(unix)]
            std::os::unix::fs::symlink(target, link).unwrap();
            #[cfg(windows)]
            {
                let status = std::process::Command::new("cmd")
                    .args(["/C", "mklink", "/J"])
                    .arg(link)
                    .arg(target)
                    .stdout(std::process::Stdio::null())
                    .status()
                    .unwrap();
                assert!(status.success());
            }
        }

        for linked_root in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let outside = tempfile::tempdir().unwrap();
            let manager = ExtensionManager::new(
                &root.path().join("sources"),
                &root.path().join("data"),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "5.3.1",
                RuntimeLimits::default(),
            )
            .unwrap();
            let update = &UPDATES[0];
            let tx = Transaction::new(&manager.sources, update);
            let parent = manager.sources.join(ROOT);
            let outside_tx = if linked_root {
                let outside_tx = outside.path().join(tx.root.file_name().unwrap());
                fs::create_dir(&outside_tx).unwrap();
                link_directory(&parent, outside.path());
                outside_tx
            } else {
                fs::create_dir(&parent).unwrap();
                link_directory(&tx.root, outside.path());
                outside.path().to_owned()
            };
            let marker = Transaction::marker(update);
            fs::write(outside_tx.join("prepared"), &marker).unwrap();

            assert!(manager.mark_bundle_removal(update.id).is_err());
            assert!(!outside_tx.join("removed").exists());
            assert_eq!(
                fs::read_to_string(outside_tx.join("prepared")).unwrap(),
                marker
            );
            assert_eq!(fs::read_dir(outside_tx).unwrap().count(), 1);
        }
    }

    #[test]
    fn recorded_removal_can_be_retried_after_interruption_and_then_reinstalled() {
        use std::io::Write;
        let root = tempfile::tempdir().unwrap();
        let sources = root.path().join("sources");
        let data = root.path().join("data");
        let open = || {
            ExtensionManager::new(
                &sources,
                &data,
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "5.3.1",
                RuntimeLimits::default(),
            )
            .unwrap()
        };
        let manager = open();
        let update = &UPDATES[0];
        let tx = Transaction::new(&sources, update);
        fs::create_dir_all(&tx.root).unwrap();
        fs::create_dir(&tx.target).unwrap();
        let manifest = r#"{"name":"amazon","displayName":"Fixture","version":"2.3.16","description":"fixture","type":["metadata_provider"]}"#;
        let script = "registerExtension({});";
        fs::write(tx.target.join("manifest.json"), manifest).unwrap();
        fs::write(tx.target.join("index.js"), script).unwrap();
        fs::write(&tx.journal, Transaction::marker(update)).unwrap();
        manager.load_all().unwrap();
        manager.mark_bundle_removal(update.id).unwrap();
        assert!(tx.terminal(update));
        drop(manager);

        let manager = open();
        manager.load_all().unwrap();
        assert!(manager.get(update.id).is_ok());
        assert_eq!(
            fs::read_to_string(tx.target.join("index.js")).unwrap(),
            script
        );
        manager.remove(update.id).unwrap();
        assert!(!tx.target.exists());
        assert!(manager.check_bundle_mutation(update.id).is_ok());

        let path = root.path().join("fixture.sflx");
        let mut zip = zip::ZipWriter::new(File::create(&path).unwrap());
        for (name, bytes) in [("manifest.json", manifest), ("index.js", script)] {
            zip.start_file(name, zip::write::SimpleFileOptions::default())
                .unwrap();
            zip.write_all(bytes.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
        manager.install(&path).unwrap();
        assert!(manager.get(update.id).is_ok());
        assert_eq!(
            fs::read_to_string(tx.target.join("index.js")).unwrap(),
            script
        );
        let status: Value = serde_json::from_str(&manager.load_all().unwrap()).unwrap();
        assert_eq!(status["errors"], json!([]));
    }
}
