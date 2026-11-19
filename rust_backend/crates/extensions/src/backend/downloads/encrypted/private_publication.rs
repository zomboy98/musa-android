//! Experimental, app-private publication. The future host must supply its
//! Android Context-owned root FD and process UID, outside extension grants.
//! The root and directories must remain private from other writers. Native
//! code sharing the app UID is trusted, including code that can alter mounts.
//! Device IDs screen out different filesystems, but cannot identify bind
//! mounts. The kernel's no-replace rename is the final same-mount check.
//! This API is for ordinary private files. SAF is outside this contract.

use mornye_core::cancellation::RequestLease;
use rustix::fs::{self, AtFlags, FileType, Mode, OFlags, RenameFlags, Stat};
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Component, Path};

const CANDIDATE: &str = "candidate";
const PRIVATE_DIR: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;

pub(super) struct PrivatePublication {
    directory: AttemptDirectory,
    attempt: OwnedFd,
    output: OwnedFd,
    candidate: File,
    published: bool,
}

/// Once committed, a directory-sync error cannot undo publication.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Published {
    pub(super) directories_synced: bool,
    pub(super) staging_removed: bool,
}

impl PrivatePublication {
    pub(super) fn new(
        trusted_app_root: &impl AsFd,
        app_uid: u32,
        staging: &Path,
        output: &Path,
    ) -> io::Result<Self> {
        let root = fs::fstat(trusted_app_root)?;
        check_private(&root, &root, app_uid, FileType::Directory, PRIVATE_DIR)?;
        #[cfg(target_os = "android")]
        if !matches!(
            fs::fstatfs(trusted_app_root)?.f_type as u32,
            0xef53 | 0xf2f52010
        ) {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "unsupported private filesystem",
            ));
        }
        let stage_parent = descend(trusted_app_root, &root, staging)?;
        let output = descend(trusted_app_root, &root, output)?;
        if same_inode(&fs::fstat(&stage_parent)?, &fs::fstat(&output)?) {
            return Err(invalid_path());
        }

        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce)
            .map_err(|_| io::Error::other("private staging entropy unavailable"))?;
        let name = format!("attempt-{:032x}", u128::from_ne_bytes(nonce));
        let directory = AttemptDirectory::create(stage_parent, name)?;
        let attempt = directory.open(|parent, name| {
            let fd = open_directory(parent, OsStr::new(name))?;
            let stat = fs::fstat(&fd)?;
            Ok((fd, stat))
        })?;
        let candidate = fs::openat(
            &attempt,
            CANDIDATE,
            OFlags::RDWR | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(PRIVATE_FILE),
        )?;
        let publication = Self {
            directory,
            attempt,
            output,
            candidate: File::from(candidate),
            published: false,
        };
        check_private(
            &fs::fstat(&publication.candidate)?,
            &root,
            app_uid,
            FileType::RegularFile,
            PRIVATE_FILE,
        )?;
        Ok(publication)
    }

    /// The callback must return only after all producer writes and extra
    /// handles have been closed. Validation must use this exact open file.
    pub(super) fn publish(
        self,
        target: &OsStr,
        lease: &RequestLease,
        prepare_and_validate: impl FnOnce(&mut File) -> io::Result<()>,
    ) -> io::Result<Published> {
        self.publish_with_sync(target, lease, prepare_and_validate, |fd| {
            fs::fsync(fd).is_ok()
        })
    }

    fn publish_with_sync(
        mut self,
        target: &OsStr,
        lease: &RequestLease,
        prepare_and_validate: impl FnOnce(&mut File) -> io::Result<()>,
        sync: impl Fn(&OwnedFd) -> bool,
    ) -> io::Result<Published> {
        let mut parts = Path::new(target).components();
        if !matches!(parts.next(), Some(Component::Normal(name)) if name == target)
            || parts.next().is_some()
        {
            return Err(invalid_path());
        }
        prepare_and_validate(&mut self.candidate)?;
        self.candidate.sync_all()?;
        let attempt = fs::fstat(&self.attempt)?;
        let candidate = fs::fstat(&self.candidate)?;
        check_private(
            &candidate,
            &attempt,
            attempt.st_uid,
            FileType::RegularFile,
            PRIVATE_FILE,
        )?;
        if candidate.st_nlink != 1 || !matches_name(&self.attempt, CANDIDATE, &candidate) {
            return Err(invalid_path());
        }

        lease
            .commit_if_active(|| {
                fs::renameat_with(
                    &self.attempt,
                    CANDIDATE,
                    &self.output,
                    target,
                    RenameFlags::NOREPLACE,
                )
            })
            .map_err(io::Error::other)??;
        Ok(self.finish_commit(sync))
    }

    fn finish_commit(&mut self, sync: impl Fn(&OwnedFd) -> bool) -> Published {
        self.published = true;
        let source_synced = sync(&self.attempt);
        let output_synced = sync(&self.output);
        let staging_removed = self.directory.remove();
        let staging_parent_synced = sync(&self.directory.parent);
        Published {
            directories_synced: source_synced && output_synced && staging_parent_synced,
            staging_removed,
        }
    }
}

impl Drop for PrivatePublication {
    fn drop(&mut self) {
        if !self.published
            && fs::fstat(&self.candidate)
                .is_ok_and(|stat| matches_name(&self.attempt, CANDIDATE, &stat))
        {
            let _ = fs::unlinkat(&self.attempt, CANDIDATE, AtFlags::empty());
        }
    }
}

struct AttemptDirectory {
    parent: OwnedFd,
    name: String,
    identity: Option<Stat>,
}

impl AttemptDirectory {
    fn create(parent: OwnedFd, name: String) -> io::Result<Self> {
        let parent_stat = fs::fstat(&parent)?;
        fs::mkdirat(&parent, name.as_str(), Mode::from_raw_mode(PRIVATE_DIR))?;
        let mut directory = Self {
            parent,
            name,
            identity: None,
        };
        // Capture the name's identity without opening another descriptor so
        // an EMFILE on openat cannot bypass cleanup. If even this lookup
        // fails, there is no trusted identity to remove and we leave it alone.
        let identity = fs::statat(
            &directory.parent,
            directory.name.as_str(),
            AtFlags::SYMLINK_NOFOLLOW,
        )?;
        if FileType::from_raw_mode(identity.st_mode) != FileType::Directory
            || identity.st_dev != parent_stat.st_dev
            || identity.st_uid != parent_stat.st_uid
        {
            return Err(invalid_path());
        }
        directory.identity = Some(identity);
        check_private(
            &identity,
            &parent_stat,
            parent_stat.st_uid,
            FileType::Directory,
            PRIVATE_DIR,
        )?;
        Ok(directory)
    }

    fn open(
        &self,
        open_and_stat: impl FnOnce(&OwnedFd, &str) -> io::Result<(OwnedFd, Stat)>,
    ) -> io::Result<OwnedFd> {
        let (fd, stat) = open_and_stat(&self.parent, &self.name)?;
        if !self
            .identity
            .as_ref()
            .is_some_and(|expected| same_inode(expected, &stat))
        {
            return Err(invalid_path());
        }
        Ok(fd)
    }

    fn remove(&mut self) -> bool {
        self.identity.take().is_some_and(|identity| {
            matches_name(&self.parent, &self.name, &identity)
                && fs::unlinkat(&self.parent, self.name.as_str(), AtFlags::REMOVEDIR).is_ok()
        })
    }
}

impl Drop for AttemptDirectory {
    fn drop(&mut self) {
        if self.identity.is_some() {
            self.remove();
        }
    }
}
fn same_inode(left: &Stat, right: &Stat) -> bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
}

fn matches_name(parent: &impl AsFd, name: &str, expected: &Stat) -> bool {
    fs::statat(parent, name, AtFlags::SYMLINK_NOFOLLOW)
        .is_ok_and(|named| same_inode(expected, &named))
}

fn check_private(
    stat: &Stat,
    root: &Stat,
    uid: u32,
    kind: FileType,
    permissions: u32,
) -> io::Result<()> {
    if stat.st_uid != uid
        || stat.st_dev != root.st_dev
        || FileType::from_raw_mode(stat.st_mode) != kind
        || stat.st_mode & 0o7777 != permissions
    {
        return Err(invalid_path());
    }
    Ok(())
}

fn descend(root_fd: &impl AsFd, root: &Stat, path: &Path) -> io::Result<OwnedFd> {
    let mut dir = None;
    for component in path.components() {
        let Component::Normal(name) = component else {
            return Err(invalid_path());
        };
        let parent = dir.as_ref().map_or_else(|| root_fd.as_fd(), AsFd::as_fd);
        let next = open_directory(parent, name)?;
        check_private(
            &fs::fstat(&next)?,
            root,
            root.st_uid,
            FileType::Directory,
            PRIVATE_DIR,
        )?;
        dir = Some(next);
    }
    dir.ok_or_else(invalid_path)
}

fn open_directory(parent: impl AsFd, name: &OsStr) -> io::Result<OwnedFd> {
    Ok(fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?)
}

fn invalid_path() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "invalid private publication path",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};

    fn fixture() -> (tempfile::TempDir, File, u32) {
        let temp = tempfile::Builder::new()
            .permissions(std::fs::Permissions::from_mode(PRIVATE_DIR))
            .tempdir()
            .unwrap();
        let mut dirs = std::fs::DirBuilder::new();
        dirs.mode(PRIVATE_DIR);
        dirs.create(temp.path().join("stage")).unwrap();
        dirs.create(temp.path().join("output")).unwrap();
        let root = File::open(temp.path()).unwrap();
        let uid = fs::fstat(&root).unwrap().st_uid;
        (temp, root, uid)
    }

    fn stage(root: &File, uid: u32) -> PrivatePublication {
        PrivatePublication::new(root, uid, Path::new("stage"), Path::new("output")).unwrap()
    }

    #[test]
    fn private_publication_preserves_validated_inode_and_does_not_replace() {
        let (temp, root, uid) = fixture();
        let registry = CancellationRegistry::new(CancellationDomain::Download);
        let lease = registry.acquire("publish").unwrap();
        let publication = stage(&root, uid);
        let candidate = fs::fstat(&publication.candidate).unwrap();
        let result = publication
            .publish(OsStr::new("track.flac"), &lease, |file| {
                file.write_all(b"synthetic audio")?;
                file.seek(SeekFrom::Start(0))?;
                let mut bytes = Vec::new();
                file.read_to_end(&mut bytes)?;
                assert_eq!(bytes, b"synthetic audio");
                Ok(())
            })
            .unwrap();
        assert!(result.directories_synced);
        assert!(result.staging_removed);
        let target = temp.path().join("output/track.flac");
        let published = fs::fstat(File::open(&target).unwrap()).unwrap();
        assert!(same_inode(&candidate, &published));
        assert_eq!(std::fs::read(&target).unwrap(), b"synthetic audio");

        let lease = registry.acquire("collision").unwrap();
        let error = stage(&root, uid)
            .publish(OsStr::new("track.flac"), &lease, |file| {
                file.write_all(b"other")
            })
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read(&target).unwrap(), b"synthetic audio");
        assert_eq!(
            std::fs::read_dir(temp.path().join("stage"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn private_publication_rejects_symlinks_modes_traversal_and_cancelled_commit() {
        let (temp, root, uid) = fixture();
        symlink("output", temp.path().join("alias")).unwrap();
        for output in ["alias", "stage", "../output", "/output"] {
            assert!(
                PrivatePublication::new(&root, uid, Path::new("stage"), Path::new(output)).is_err()
            );
        }
        assert!(
            PrivatePublication::new(&root, uid ^ 1, Path::new("stage"), Path::new("output"))
                .is_err()
        );
        let output = temp.path().join("output");
        std::fs::set_permissions(&output, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(
            PrivatePublication::new(&root, uid, Path::new("stage"), Path::new("output")).is_err()
        );
        std::fs::set_permissions(&output, std::fs::Permissions::from_mode(PRIVATE_DIR)).unwrap();

        let registry = CancellationRegistry::new(CancellationDomain::Download);
        let lease = registry.acquire("cancel").unwrap();
        let error = stage(&root, uid)
            .publish(OsStr::new("track.flac"), &lease, |file| {
                file.write_all(b"unpublished")?;
                registry.cancel("cancel").unwrap();
                Ok(())
            })
            .unwrap_err();
        assert_eq!(error.to_string(), "download cancelled");
        assert_eq!(std::fs::read_dir(output).unwrap().count(), 0);
        assert_eq!(
            std::fs::read_dir(temp.path().join("stage"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn private_publication_refuses_replaced_candidate_and_does_not_unlink_it() {
        let (temp, root, uid) = fixture();
        let registry = CancellationRegistry::new(CancellationDomain::Download);
        let lease = registry.acquire("replace").unwrap();
        let publication = stage(&root, uid);
        let attempt = temp.path().join("stage").join(&publication.directory.name);
        let name = attempt.join(CANDIDATE);
        let error = publication
            .publish(OsStr::new("track.flac"), &lease, |file| {
                file.write_all(b"validated")?;
                std::fs::rename(&name, attempt.join("retained"))?;
                std::fs::write(&name, b"replacement")?;
                Ok(())
            })
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(std::fs::read(&name).unwrap(), b"replacement");
        assert!(!temp.path().join("output/track.flac").exists());
    }

    #[test]
    fn attempt_guard_cleans_open_and_stat_failures_but_preserves_replacement() {
        let (temp, root, _) = fixture();
        let staging = temp.path().join("stage");
        for (name, fail_after_open) in [("open-failure", false), ("stat-failure", true)] {
            let parent = open_directory(&root, OsStr::new("stage")).unwrap();
            let attempt = AttemptDirectory::create(parent, name.to_owned()).unwrap();
            let error = attempt
                .open(|parent, name| {
                    let _opened = if fail_after_open {
                        Some(open_directory(parent, OsStr::new(name))?)
                    } else {
                        None
                    };
                    Err(rustix::io::Errno::MFILE.into())
                })
                .unwrap_err();
            assert_eq!(
                error.raw_os_error(),
                Some(rustix::io::Errno::MFILE.raw_os_error())
            );
            drop(attempt);
            assert!(!staging.join(name).exists());
        }

        let parent = open_directory(&root, OsStr::new("stage")).unwrap();
        let attempt = AttemptDirectory::create(parent, "replace".to_owned()).unwrap();
        let original = staging.join("replace");
        std::fs::rename(&original, staging.join("retained")).unwrap();
        std::fs::DirBuilder::new()
            .mode(PRIVATE_DIR)
            .create(&original)
            .unwrap();
        assert!(
            attempt
                .open(|parent, name| {
                    let fd = open_directory(parent, OsStr::new(name))?;
                    let stat = fs::fstat(&fd)?;
                    Ok((fd, stat))
                })
                .is_err()
        );
        drop(attempt);
        assert!(original.is_dir());
        assert!(staging.join("retained").is_dir());
    }

    #[test]
    fn committed_result_retains_sync_and_cleanup_failures() {
        use std::cell::Cell;

        let (temp, root, uid) = fixture();
        let registry = CancellationRegistry::new(CancellationDomain::Download);
        let lease = registry.acquire("finish").unwrap();
        let publication = stage(&root, uid);
        let attempt = temp.path().join("stage").join(&publication.directory.name);
        let obstruction = attempt.join("obstruction");
        let calls = Cell::new(0);
        let result = publication
            .publish_with_sync(
                OsStr::new("track.flac"),
                &lease,
                |file| {
                    std::fs::write(&obstruction, b"prevent directory removal")?;
                    file.write_all(b"committed audio")
                },
                |fd| {
                    let call = calls.get();
                    calls.set(call + 1);
                    if call == 2 {
                        // Cleanup has failed, but the directory is empty by the
                        // time Drop runs. Drop must not silently remove it.
                        std::fs::remove_file(&obstruction).unwrap();
                    }
                    call != 1 && fs::fsync(fd).is_ok()
                },
            )
            .unwrap();
        assert_eq!(calls.get(), 3);
        assert!(!result.directories_synced);
        assert!(!result.staging_removed);
        assert!(attempt.is_dir());
        assert_eq!(
            std::fs::read(temp.path().join("output/track.flac")).unwrap(),
            b"committed audio"
        );
    }
}
