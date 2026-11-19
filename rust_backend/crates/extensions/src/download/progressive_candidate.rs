//! Experimental candidate gate. Not connected to the provider manager or FFI.
//! The caller must hold the owning operation's cancellation/commit gate when
//! accepting; a transfer finishing alone never makes EOF visible to a lease.

#![allow(dead_code)]

use super::progressive::{PrefixEvent, PrefixObserver};
use super::progressive_container::{Inspection, InspectionKind};
use super::progressive_reader::PrefixStream;
use std::fs::File;
use std::io;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

#[derive(Clone, Copy)]
enum CandidateState { Active { generation: u64 }, Transferred { generation: u64, bytes: u64 }, Accepted, Rejected }

pub(crate) struct CandidateGate {
    stream: Arc<PrefixStream>,
    state: Mutex<CandidateState>,
    identity: Mutex<Option<same_file::Handle>>,
    inspector: Mutex<Option<Inspection>>,
    kind: InspectionKind,
    /// Why inspection refused the bytes; a stable token, never media data.
    rejection: Mutex<Option<&'static str>>,
    /// Host-chosen: only the generic audio operation may decrypt CENC on the fly.
    decrypt_allowed: bool,
    /// Key offered by the provider for this download (kept only to re-arm the
    /// inspector after a retry); zeroized on drop and as soon as the gate ends.
    cenc_key: Mutex<Option<Zeroizing<Vec<u8>>>>,
}

/// Scoped to one explicit host operation, never looked up by item ID.
#[derive(Default)]
struct OperationState {
    candidate: Option<Arc<CandidateGate>>,
    sequence: u64,
    lease: Option<Weak<mornye_core::cancellation::RequestLease>>,
    closed: bool,
    finished: bool,
}

pub struct ProgressiveOperation {
    state: Mutex<OperationState>,
    changed: Condvar,
    // No extension-provided claim can set this. A trusted host adapter must
    // establish clear-media policy before any future production admission.
    admitted: bool,
    inspection: InspectionKind,
}

impl Default for ProgressiveOperation {
    fn default() -> Self { Self { state: Mutex::new(OperationState::default()), changed: Condvar::new(), admitted: false, inspection: InspectionKind::None } }
}

pub enum NextCandidate {
    Available { sequence: u64, lease: super::progressive_reader::PrefixLease, cancellation: super::progressive_reader::LeaseCancellation },
    Pending,
    Finished,
    Closed,
}

impl ProgressiveOperation {
    pub(crate) fn is_admitted(&self) -> bool { self.admitted }

    /// Explicit opt-in to provisional fMP4 inspection. This does not attest
    /// clear audio or grant permission to decrypt or retain provider media.
    pub fn provisional_fmp4() -> Self {
        Self { state: Mutex::new(OperationState::default()), changed: Condvar::new(), admitted: true, inspection: InspectionKind::Fmp4 }
    }

    /// Opt-in generic audio lease: mp3, aac/adts, flac, ogg, wav and MP4/M4A
    /// whose `moov` precedes the media. Bytes are exposed as they arrive once
    /// the container signature is recognised; anything else (including MP4
    /// with `moov` at the end or protection signals) aborts the lease with a
    /// typed reason so the caller falls back to a complete download. Like the
    /// fMP4 door this is not a DRM proof and grants no retention rights.
    pub fn generic_audio() -> Self {
        Self { state: Mutex::new(OperationState::default()), changed: Condvar::new(), admitted: true, inspection: InspectionKind::Audio }
    }

    /// Test-only capability for known local plaintext fixtures. There is no
    /// production factory until a trusted provider adapter is implemented.
    #[cfg(test)]
    pub(crate) fn clear_fixture() -> Self {
        Self { state: Mutex::new(OperationState::default()), changed: Condvar::new(), admitted: true, inspection: InspectionKind::None }
    }
    #[cfg(test)]
    pub(crate) fn fmp4_fixture() -> Self {
        Self::provisional_fmp4()
    }
    pub(crate) fn begin_candidate(&self) -> Arc<CandidateGate> {
        let mut state = self.state.lock().unwrap();
        if let Some(previous) = state.candidate.take() { previous.reject(); }
        let candidate = CandidateGate::new_inspected(self.inspection);
        if state.closed || state.finished { candidate.reject(); return candidate; }
        state.sequence += 1;
        state.candidate = Some(candidate.clone());
        self.changed.notify_all();
        candidate
    }

    pub(crate) fn current(&self) -> Option<Arc<CandidateGate>> {
        self.state.lock().unwrap().candidate.clone()
    }

    pub(crate) fn reject_current(&self) {
        if let Some(candidate) = self.state.lock().unwrap().candidate.take() { candidate.reject(); }
        self.changed.notify_all();
    }

    pub(crate) fn bind(&self, lease: &Arc<mornye_core::cancellation::RequestLease>) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.closed || state.finished || state.lease.is_some() { return false; }
        state.lease = Some(Arc::downgrade(lease));
        true
    }

    pub(crate) fn finish(&self) {
        self.state.lock().unwrap().finished = true;
        self.changed.notify_all();
    }

    pub fn next_lease(&self, after: u64, timeout: Duration) -> io::Result<NextCandidate> {
        if timeout > Duration::from_secs(1) { return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid wait bound")); }
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap();
        loop {
            if state.closed { return Ok(NextCandidate::Closed); }
            if state.sequence > after {
                if let Some(candidate) = &state.candidate {
                    let (lease, cancellation) = candidate.stream().lease();
                    return Ok(NextCandidate::Available { sequence: state.sequence, lease, cancellation });
                }
            }
            if state.finished { return Ok(NextCandidate::Finished); }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() { return Ok(NextCandidate::Pending); }
            state = self.changed.wait_timeout(state, remaining).unwrap().0;
        }
    }

    pub fn close(&self) {
        let (candidate, lease) = {
            let mut state = self.state.lock().unwrap();
            if state.closed { return; }
            state.closed = true;
            (state.candidate.take(), state.lease.as_ref().and_then(Weak::upgrade))
        };
        if let Some(candidate) = candidate { candidate.close(); }
        if let Some(lease) = lease { lease.release(); }
        self.changed.notify_all();
    }
}

impl Drop for ProgressiveOperation {
    fn drop(&mut self) {
        self.close();
    }
}

impl CandidateGate {
    pub(super) fn new() -> Arc<Self> {
        Self::new_inspected(InspectionKind::None)
    }
    pub(super) fn new_inspected(kind: InspectionKind) -> Arc<Self> {
        Arc::new(Self { stream: PrefixStream::new(), state: Mutex::new(CandidateState::Active { generation: 0 }), identity: Mutex::new(None), inspector: Mutex::new(Inspection::new(kind)), kind, rejection: Mutex::new(None), decrypt_allowed: kind == InspectionKind::Audio, cenc_key: Mutex::new(None) })
    }

    /// Hands the AES-128 `cenc` key to a generic-audio candidate before its first
    /// byte. Ignored (false) when the operation does not allow decryption, the
    /// transfer already started, or the container turns out not to be MP4. The
    /// key is never returned, logged or persisted.
    pub(crate) fn provide_cenc_key(&self, key: Zeroizing<Vec<u8>>) -> bool {
        if !self.decrypt_allowed { return false; }
        let state = self.state.lock().unwrap();
        if !matches!(*state, CandidateState::Active { generation: 0 }) { return false; }
        let mut inspection = self.inspector.lock().unwrap();
        let Some(inspector) = inspection.as_mut() else { return false };
        if !inspector.set_key(Zeroizing::new(key.to_vec())) { return false; }
        *self.cenc_key.lock().unwrap() = Some(key);
        true
    }

    fn wipe_key(&self) { self.cenc_key.lock().unwrap().take(); }
    pub(crate) fn stream(&self) -> Arc<PrefixStream> { self.stream.clone() }

    /// Call only after provider-level validation and final candidate selection.
    /// Sharing the operation's commit gate serializes acceptance and cancel.
    pub(super) fn accept(&self, lease: &mornye_core::cancellation::RequestLease, validated: &cap_std::fs::File) -> bool {
        self.publish_with_acceptance(lease, validated, || Ok(())).is_ok()
    }

    /// Publication and EOF become visible within the same cancellation gate.
    /// `publish` must be the final atomic no-replace operation, after all
    /// validation and synchronization; a failed publication never emits EOF.
    pub(crate) fn publish_with_acceptance(
        &self,
        lease: &mornye_core::cancellation::RequestLease,
        validated: &cap_std::fs::File,
        publish: impl FnOnce() -> io::Result<()>,
    ) -> io::Result<()> {
        let identity = match validated.try_clone().and_then(|file| same_file::Handle::from_file(file.into_std())) {
            Ok(identity) => identity,
            Err(error) => { self.reject(); return Err(error); }
        };
        match lease.commit_if_active(|| {
            let mut state = self.state.lock().unwrap();
            if self.identity.lock().unwrap().as_ref() != Some(&identity) {
                if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("gate_stage=identity_mismatch"); }
                return Err(io::Error::other("candidate identity mismatch"));
            }
            if let CandidateState::Transferred { generation, bytes } = *state {
                publish()?;
                self.stream.notify(PrefixEvent::Committed { generation, bytes });
                *state = CandidateState::Accepted;
                Ok(())
            } else { if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("gate_stage=not_transferable"); } Err(io::Error::other(match self.rejection.lock().unwrap().as_ref() { Some(reason) => format!("progressive_rejected:{reason}"), None => "candidate not transferable".to_owned() })) }
        }) {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => { self.reject(); Err(error) }
            Err(error) => { self.reject(); Err(io::Error::other(error)) }
        }
    }

    pub(super) fn reject(&self) {
        self.wipe_key();
        let mut state = self.state.lock().unwrap();
        match *state {
            CandidateState::Active { generation } => {
                // A rejected active transfer is aborted by its producer; the
                // owner must also cancel that transfer before selecting next.
                self.stream.notify(PrefixEvent::Aborted { generation });
                *state = CandidateState::Rejected;
            }
            CandidateState::Transferred { generation, .. } => {
                self.stream.notify(PrefixEvent::Invalidate { generation });
                self.stream.notify(PrefixEvent::Aborted { generation: generation + 1 });
                *state = CandidateState::Rejected;
            }
            CandidateState::Accepted | CandidateState::Rejected => {}
        }
    }

    fn close(&self) { self.stream.close(); }

    /// Stable token explaining why inspection refused this candidate.
    pub(crate) fn rejection(&self) -> Option<&'static str> { *self.rejection.lock().unwrap() }
}

impl PrefixObserver for CandidateGate {
    fn attach(&self, file: File) -> io::Result<()> {
        let identity = same_file::Handle::from_file(file.try_clone()?)?;
        let mut slot = self.identity.lock().unwrap();
        if slot.is_some() { return Err(io::Error::new(io::ErrorKind::AlreadyExists, "candidate already attached")); }
        self.stream.attach(file)?;
        *slot = Some(identity);
        Ok(())
    }
    fn notify(&self, event: PrefixEvent) {
        let mut state = self.state.lock().unwrap();
        match (*state, event) {
            (CandidateState::Active { .. }, PrefixEvent::Committed { generation, bytes }) => {
                self.wipe_key();
                if self.inspector.lock().unwrap().as_ref().is_some_and(|inspection| !inspection.complete(bytes)) {
                    if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("gate_stage=inspection_incomplete"); }
                    *self.rejection.lock().unwrap() = Some("incomplete_media");
                    self.stream.notify(PrefixEvent::Aborted { generation });
                    *state = CandidateState::Rejected;
                } else {
                    *state = CandidateState::Transferred { generation, bytes };
                }
            }
            (CandidateState::Active { .. }, PrefixEvent::Invalidate { generation }) => {
                self.stream.notify(event);
                if let Some(inspection) = self.inspector.lock().unwrap().as_mut() {
                    if let Some(fresh) = Inspection::new(self.kind) { *inspection = fresh; }
                    if let Some(key) = self.cenc_key.lock().unwrap().as_ref() { inspection.set_key(Zeroizing::new(key.to_vec())); }
                }
                *state = CandidateState::Active { generation: generation + 1 };
            }
            (CandidateState::Active { .. }, PrefixEvent::Available { generation, bytes }) => {
                let mut inspection = self.inspector.lock().unwrap();
                let mut available = match inspection.as_mut() {
                    Some(inspector) => inspector.advance(bytes, |offset, len| self.stream.inspect_staged(offset, len)),
                    None => Ok(bytes),
                };
                // On-the-fly decryption: clear bytes are published to the lease's
                // spool before the prefix is announced; ciphertext is never exposed.
                let mut spool_full = false;
                if available.is_ok() {
                    if let Some(clear) = inspection.as_mut().and_then(Inspection::take_clear) {
                        if self.stream.append_clear(&clear).is_err() { available = Err(()); spool_full = true; }
                    }
                }
                match available {
                    Ok(bytes) => self.stream.notify(PrefixEvent::Available { generation, bytes }),
                    Err(()) => {
                        *self.rejection.lock().unwrap() = Some(if spool_full { "cenc_spool_limit" } else { inspection.as_ref().and_then(Inspection::reason).unwrap_or("unsupported_container") });
                        self.wipe_key();
                        if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("gate_stage=inspection_rejected"); }
                        self.stream.notify(PrefixEvent::Aborted { generation });
                        *state = CandidateState::Rejected;
                    }
                }
            }
            (CandidateState::Active { .. }, event) => self.stream.notify(event),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::download::{download, DownloadOptions};
    use crate::download::progress::ItemProgressTarget;
    use crate::download::progressive_reader::{LeaseState, ReadAtError, ReadAtResult};
    use crate::files::FileRegistry;
    use crate::transfer_policy::DownloadTransferPolicy;
    use mornye_core::app_version::AppVersion;
    use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
    use mornye_core::progress::ProgressRegistry;
    use mornye_network::NetworkService;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::time::Duration;

    #[test]
    fn two_real_candidates_cannot_publish_eof_until_owner_accepts() {
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            for body in [b"candidate-one".as_slice(), b"candidate-two".as_slice()] {
                let (mut client, _) = listener.accept().unwrap();
                client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut request = [0; 4096];
                let _ = client.read(&mut request).unwrap();
                write!(client, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
                client.write_all(body).unwrap();
            }
        });
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(root.path()).unwrap();
        let service = NetworkService::new().unwrap();
        service.set_allow_private_network(true);
        let network = service.native_media_session(Duration::from_secs(5));
        let first = CandidateGate::new();
        let second = CandidateGate::new();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("test-operation").unwrap();
        for (index, gate) in [first.clone(), second.clone()].iter().enumerate() {
            let path = files.resolve(&format!("candidate{index}.bin")).unwrap();
            let result = download(&files, &path, &network, &url, DownloadOptions {
                item: ItemProgressTarget::new(Arc::new(ProgressRegistry::new()), String::new(), false),
                headers: Default::default(), app_version: AppVersion::default(), resume: false,
                persistent: false, policy: DownloadTransferPolicy::default(), budget: None,
                chunk_size: None, prefix_observer: Some(gate.clone()),
            }, &|| Ok(()), &|_| Ok(()), &mut |_, _| {});
            assert!(result.is_ok());
            let validated = path.open_native_read().unwrap();
            let (lease, _) = gate.stream().lease();
            let expected = if index == 0 { b"candidate-one" } else { b"candidate-two" };
            assert!(matches!(lease.read_at(0, 64, Duration::ZERO).unwrap(), ReadAtResult::Bytes(bytes) if bytes == expected));
            assert!(matches!(lease.read_at(expected.len() as u64, 1, Duration::ZERO).unwrap(), ReadAtResult::Pending));
            // The server announced Content-Length, so the lease reports it before commit.
            assert_eq!(lease.size().unwrap(), Some(expected.len() as u64));
            if index == 0 {
                gate.reject();
                assert!(!gate.accept(&operation, &validated));
                assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
                assert_eq!(lease.wait_terminal(Duration::ZERO).unwrap(), LeaseState::Invalidated);
            } else {
                let destination = files.resolve("published.bin").unwrap();
                let mut staged = destination.stage().unwrap();
                staged.file.write_all(expected).unwrap();
                staged.publish_new_with_candidate(&operation, gate, &validated).unwrap();
                assert!(matches!(lease.read_at(expected.len() as u64, 1, Duration::ZERO).unwrap(), ReadAtResult::End));
                assert_eq!(lease.size().unwrap(), Some(expected.len() as u64));
                assert_eq!(std::fs::read(root.path().join("published.bin")).unwrap(), expected);
            }
        }
        server.join().unwrap();
    }

    #[test]
    fn cancelled_candidate_never_accepts_or_returns_eof() {
        let gate = CandidateGate::new();
        let (lease, _) = gate.stream().lease();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("cancelled").unwrap();
        let root = tempfile::tempdir().unwrap();
        let file = cap_std::fs::File::from_std(File::create(root.path().join("other")).unwrap());
        gate.reject();
        assert!(!gate.accept(&operation, &file));
        assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
    }

    #[test]
    fn cancelled_operation_cannot_accept_a_transferred_candidate() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("data");
        std::fs::write(&path, b"audio").unwrap();
        let gate = CandidateGate::new();
        gate.attach(File::open(&path).unwrap()).unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: 5 });
        gate.notify(PrefixEvent::Committed { generation: 0, bytes: 5 });
        let (reader, _) = gate.stream().lease();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("cancelled-after-transfer").unwrap();
        cancellations.cancel("cancelled-after-transfer").unwrap();
        let verified = cap_std::fs::File::from_std(File::open(path).unwrap());
        assert!(!gate.accept(&operation, &verified));
        assert!(matches!(reader.read_at(5, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
    }

    #[test]
    fn replacement_at_same_path_does_not_match_observed_file() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("audio");
        std::fs::write(&path, b"original").unwrap();
        let gate = CandidateGate::new();
        gate.attach(File::open(&path).unwrap()).unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: 8 });
        gate.notify(PrefixEvent::Committed { generation: 0, bytes: 8 });
        let (reader, _) = gate.stream().lease();
        std::fs::rename(&path, root.path().join("old")).unwrap();
        std::fs::write(&path, b"replaced").unwrap();
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(root.path()).unwrap();
        let replaced = files.resolve("audio").unwrap().open_native_read().unwrap();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("replaced").unwrap();
        assert!(!gate.accept(&operation, &replaced));
        assert!(matches!(reader.read_at(8, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
    }

    #[test]
    fn returned_other_candidate_invalidates_observed_lease() {
        let root = tempfile::tempdir().unwrap();
        let observed = root.path().join("first");
        let returned = root.path().join("second");
        std::fs::write(&observed, b"first").unwrap();
        std::fs::write(&returned, b"other").unwrap();
        let gate = CandidateGate::new();
        gate.attach(File::open(observed).unwrap()).unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: 5 });
        gate.notify(PrefixEvent::Committed { generation: 0, bytes: 5 });
        let (reader, _) = gate.stream().lease();
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(root.path()).unwrap();
        let validated = files.resolve("second").unwrap().open_native_read().unwrap();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("wrong-candidate").unwrap();
        assert!(!gate.accept(&operation, &validated));
        assert!(matches!(reader.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
    }

    #[test]
    fn publication_collision_rejects_candidate_without_eof() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source");
        std::fs::write(&source, b"audio").unwrap();
        let gate = CandidateGate::new();
        gate.attach(File::open(&source).unwrap()).unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: 5 });
        gate.notify(PrefixEvent::Committed { generation: 0, bytes: 5 });
        let (reader, _) = gate.stream().lease();
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(root.path()).unwrap();
        let validated = files.resolve("source").unwrap().open_native_read().unwrap();
        let destination = files.resolve("published").unwrap();
        let mut staged = destination.stage().unwrap();
        staged.file.write_all(b"audio").unwrap();
        std::fs::write(root.path().join("published"), b"existing").unwrap();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("collision").unwrap();
        assert!(staged.publish_new_with_candidate(&operation, &gate, &validated).is_err());
        assert!(!operation.has_committed());
        assert!(matches!(reader.read_at(5, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
        assert_eq!(std::fs::read(root.path().join("published")).unwrap(), b"existing");
    }

    #[test]
    fn cancellation_prevents_both_atomic_publication_and_eof() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source");
        std::fs::write(&source, b"audio").unwrap();
        let gate = CandidateGate::new();
        gate.attach(File::open(&source).unwrap()).unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: 5 });
        gate.notify(PrefixEvent::Committed { generation: 0, bytes: 5 });
        let (reader, _) = gate.stream().lease();
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(root.path()).unwrap();
        let validated = files.resolve("source").unwrap().open_native_read().unwrap();
        let mut staged = files.resolve("published").unwrap().stage().unwrap();
        staged.file.write_all(b"audio").unwrap();
        let cancellations = CancellationRegistry::new(CancellationDomain::Download);
        let operation = cancellations.acquire("cancel-before-publication").unwrap();
        cancellations.cancel("cancel-before-publication").unwrap();
        assert!(staged.publish_new_with_candidate(&operation, &gate, &validated).is_err());
        assert!(!root.path().join("published").exists());
        assert!(matches!(reader.read_at(5, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
    }

    #[test]
    fn explicit_runtime_operation_isolates_two_host_download_calls() {
        use crate::environment::ExtensionEnvironment;
        use crate::RuntimeLimits;
        use std::sync::mpsc;
        use std::time::Instant;

        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let (ready_tx, ready_rx) = mpsc::channel();
        let (continue_tx, continue_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            for index in 0..2 {
                let (mut client, _) = listener.accept().unwrap();
                client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut request = [0; 4096];
                let _ = client.read(&mut request).unwrap();
                write!(client, "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n").unwrap();
                client.write_all(&[if index == 0 { 0x11 } else { 0x22 }; 4096]).unwrap();
                client.flush().unwrap();
                ready_tx.send(index).unwrap();
                continue_rx.recv_timeout(Duration::from_secs(10)).unwrap();
                client.write_all(&[if index == 0 { 0x11 } else { 0x22 }; 4096]).unwrap();
            }
        });
        let scope = Arc::new(ProgressiveOperation::default());
        let worker_scope = scope.clone();
        let worker_root = root.path().to_path_buf();
        let worker = std::thread::spawn(move || {
            let env = ExtensionEnvironment::new(&worker_root, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1").unwrap();
            env.set_allow_private_network(true).unwrap();
            let manifest = serde_json::json!({"name":"progressive.runtime","version":"1","description":"local fixture", "type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true}}).to_string();
            let runtime = env.load(&manifest, r#"registerExtension({run(url){let first=file.download(url,'one.bin',{maxAttempts:1,resume:false});if(!first.success)return first;return file.download(url,'two.bin',{maxAttempts:1,resume:false});}});"#, RuntimeLimits::default()).unwrap();
            let result = runtime.call_download_progressive("run", &serde_json::json!([url]).to_string(), None, worker_scope);
            env.shutdown();
            result
        });
        assert_eq!(ready_rx.recv_timeout(Duration::from_secs(10)).unwrap(), 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        let first = loop { if let Some(candidate) = scope.current() { break candidate; } assert!(Instant::now() < deadline); std::thread::sleep(Duration::from_millis(5)); };
        let (first_lease, _) = first.stream().lease();
        assert!(matches!(first_lease.read_at(0, 4096, Duration::from_secs(1)).unwrap(), ReadAtResult::Bytes(bytes) if bytes.iter().all(|b| *b == 0x11)));
        continue_tx.send(()).unwrap();
        assert_eq!(ready_rx.recv_timeout(Duration::from_secs(10)).unwrap(), 1);
        assert!(matches!(first_lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
        let second = scope.current().unwrap();
        assert!(!Arc::ptr_eq(&first, &second));
        let (second_lease, _) = second.stream().lease();
        assert!(matches!(second_lease.read_at(0, 4096, Duration::from_secs(1)).unwrap(), ReadAtResult::Bytes(bytes) if bytes.iter().all(|b| *b == 0x22)));
        continue_tx.send(()).unwrap();
        let result = worker.join().unwrap().unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&result).unwrap()["success"], true);
        assert!(matches!(second_lease.read_at(8192, 1, Duration::ZERO).unwrap(), ReadAtResult::Pending));
        server.join().unwrap();
    }

    mod tidal_aac {
        use super::*;

        fn atom(name: &[u8; 4], payload: &[u8]) -> Vec<u8> {
            let mut out = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
            out.extend_from_slice(name); out.extend_from_slice(payload); out
        }

        /// Rebuilds the shape of a real Tidal AAC download: ftyp, moov first with
        /// edts/elst and sample tables plus `roll` sample groups, a `free` box and
        /// one large mdat; no mvex, no protection.
        fn tidal_like(mdat_len: usize) -> Vec<u8> {
            let mut entry = vec![0u8; 28]; entry.extend(atom(b"esds", &[0; 4]));
            let mut stsd = vec![0u8; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
            let mut stbl = atom(b"stsd", &stsd);
            for name in [b"stts", b"stsc", b"stsz", b"stco"] { stbl.extend(atom(name, &[0; 8])); }
            let mut roll = vec![0u8, 0, 0, 1]; roll.extend_from_slice(b"roll"); roll.extend_from_slice(&[0; 8]);
            stbl.extend(atom(b"sgpd", &roll));
            let mut sbgp = vec![0u8; 4]; sbgp.extend_from_slice(b"roll"); sbgp.extend_from_slice(&[0; 8]);
            stbl.extend(atom(b"sbgp", &sbgp));
            let mut minf = atom(b"smhd", &[0; 8]); minf.extend(atom(b"dinf", &[0; 8])); minf.extend(atom(b"stbl", &stbl));
            let mut mdia = atom(b"mdhd", &[0; 24]); mdia.extend(atom(b"hdlr", &[0; 24])); mdia.extend(atom(b"minf", &minf));
            let mut trak = atom(b"tkhd", &[0; 84]); trak.extend(atom(b"edts", &atom(b"elst", &[0; 16]))); trak.extend(atom(b"mdia", &mdia));
            let mut moov = atom(b"mvhd", &[0; 100]); moov.extend(atom(b"trak", &trak));
            let mut file = atom(b"ftyp", b"M4A     M4A isom"); file.extend(atom(b"moov", &moov));
            file.extend(atom(b"free", &[0; 200]));
            file.extend(atom(b"mdat", &(0..mdat_len).map(|i| (i % 251) as u8).collect::<Vec<_>>()));
            file
        }

        #[test]
        fn aac_with_roll_groups_and_leading_moov_streams_while_it_arrives() {
            let file = tidal_like(300_000);
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("staged");
            std::fs::write(&path, &file).unwrap();
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            gate.attach(File::open(&path).unwrap()).unwrap();
            let (lease, _) = gate.stream().lease();
            let total = file.len() as u64;
            let mut written = 0u64;
            let mut exposed_mid = 0u64;
            while written < total {
                written = (written + 4099).min(total);
                gate.notify(PrefixEvent::Available { generation: 0, bytes: written });
                let mut offset = 0u64;
                while let ReadAtResult::Bytes(bytes) = lease.read_at(offset, 4096, Duration::ZERO).unwrap() {
                    assert_eq!(bytes[..], file[offset as usize..offset as usize + bytes.len()]);
                    offset += bytes.len() as u64;
                }
                assert!(offset <= written);
                if written < total / 2 { exposed_mid = offset; }
            }
            assert!(gate.rejection().is_none(), "{:?}", gate.rejection());
            assert!(exposed_mid > 1000, "the prefix must be published while the file is still arriving");
            gate.notify(PrefixEvent::Committed { generation: 0, bytes: total });
            let cancellations = CancellationRegistry::new(CancellationDomain::Download);
            let operation = cancellations.acquire("tidal-accept").unwrap();
            let validated = cap_std::fs::File::from_std(File::open(&path).unwrap());
            assert!(gate.accept(&operation, &validated));
            assert!(matches!(lease.read_at(total, 1, Duration::ZERO).unwrap(), ReadAtResult::End));
        }

        /// Real downloads captured from the phone (WISS_REAL_SAMPLES/crudo-*.bin):
        /// the lease must publish a prefix while arriving and serve identical bytes.
        #[test]
        #[ignore = "needs captured real files (WISS_REAL_SAMPLES)"]
        fn real_captured_aac_files_stream_with_identical_content() {
            let dir = std::path::PathBuf::from(std::env::var("WISS_REAL_SAMPLES").expect("WISS_REAL_SAMPLES"));
            let mut checked = 0;
            for entry in std::fs::read_dir(&dir).unwrap() {
                let path = entry.unwrap().path();
                let name = path.file_name().unwrap().to_string_lossy().to_string();
                if !(name.starts_with("crudo-") && name.ends_with(".bin")) { continue; }
                let file = std::fs::read(&path).unwrap();
                let gate = CandidateGate::new_inspected(InspectionKind::Audio);
                gate.attach(File::open(&path).unwrap()).unwrap();
                let (lease, _) = gate.stream().lease();
                let total = file.len() as u64;
                let (mut written, mut served, mut mid) = (0u64, 0u64, 0u64);
                while written < total {
                    written = (written + 131_072).min(total);
                    gate.notify(PrefixEvent::Available { generation: 0, bytes: written });
                    while let ReadAtResult::Bytes(bytes) = lease.read_at(served, 65_536, Duration::ZERO).unwrap() {
                        assert_eq!(bytes[..], file[served as usize..served as usize + bytes.len()], "{name}");
                        served += bytes.len() as u64;
                    }
                    assert!(served <= written);
                    if written * 10 < total * 3 { mid = served; }
                }
                assert!(gate.rejection().is_none(), "{name}: rejected as {:?}", gate.rejection());
                assert!(mid > 0, "{name}: nothing published during the first 30 percent");
                assert_eq!(served, total, "{name}");
                gate.notify(PrefixEvent::Committed { generation: 0, bytes: total });
                let cancellations = CancellationRegistry::new(CancellationDomain::Download);
                let operation = cancellations.acquire("real-accept").unwrap();
                let validated = cap_std::fs::File::from_std(File::open(&path).unwrap());
                assert!(gate.accept(&operation, &validated), "{name}");
                println!("{name}: ok, {total} bytes, {mid} published by 30 percent");
                checked += 1;
            }
            assert!(checked > 0, "no crudo-*.bin files");
        }

        #[test]
        fn the_same_file_with_a_seig_group_is_still_refused() {
            let mut file = tidal_like(10_000);
            let at = file.windows(4).position(|w| w == b"roll").unwrap();
            file[at..at + 4].copy_from_slice(b"seig");
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("staged");
            std::fs::write(&path, &file).unwrap();
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            gate.attach(File::open(&path).unwrap()).unwrap();
            let (lease, _) = gate.stream().lease();
            gate.notify(PrefixEvent::Available { generation: 0, bytes: file.len() as u64 });
            assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
            assert_eq!(gate.rejection(), Some("protected_media"));
        }
    }

    mod cenc {
        use super::*;
        use crate::download::progressive_cenc::tests::{build, plain_fragments, Built, FragmentOptions, Spec, KEY};

        fn staged(built: &Built) -> (tempfile::TempDir, std::path::PathBuf) {
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("staged");
            std::fs::write(&path, &built.encrypted).unwrap();
            (root, path)
        }

        /// Reads whatever the lease offers; every byte must be the expected clear byte.
        fn drain(lease: &crate::download::progressive_reader::PrefixLease, built: &Built) -> u64 {
            let mut offset = 0u64;
            loop {
                match lease.read_at(offset, 4096, Duration::ZERO).unwrap() {
                    ReadAtResult::Bytes(bytes) => {
                        assert_eq!(bytes[..], built.expected[offset as usize..offset as usize + bytes.len()]);
                        offset += bytes.len() as u64;
                    }
                    ReadAtResult::Pending => return offset,
                    ReadAtResult::End => panic!("end before commit"),
                }
            }
        }

        #[test]
        fn decrypting_candidate_exposes_only_the_clear_prefix_and_commits_the_clear_file() {
            let built = build(&Spec::default(), &plain_fragments(3, 5), &FragmentOptions::default());
            let (root, path) = staged(&built);
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            assert!(gate.provide_cenc_key(Zeroizing::new(KEY.to_vec())));
            gate.attach(File::open(&path).unwrap()).unwrap();
            let (lease, _) = gate.stream().lease();
            let total = built.encrypted.len() as u64;
            let (mut written, mut exposed_before_total) = (0u64, 0u64);
            while written < total {
                written = (written + 37).min(total);
                gate.notify(PrefixEvent::Available { generation: 0, bytes: written });
                let offset = drain(&lease, &built);
                assert!(offset <= written);
                if written < total { exposed_before_total = exposed_before_total.max(offset); }
            }
            assert!(exposed_before_total > built.samples[0].0 as u64, "streaming must start before the transfer ends");
            assert_eq!(drain(&lease, &built), total);
            gate.notify(PrefixEvent::Committed { generation: 0, bytes: total });
            let cancellations = CancellationRegistry::new(CancellationDomain::Download);
            let operation = cancellations.acquire("cenc-accept").unwrap();
            let validated = cap_std::fs::File::from_std(File::open(&path).unwrap());
            assert!(gate.accept(&operation, &validated));
            assert!(matches!(lease.read_at(total, 1, Duration::ZERO).unwrap(), ReadAtResult::End));
            assert_eq!(lease.size().unwrap(), Some(total));
            assert!(gate.cenc_key.lock().unwrap().is_none(), "the key must not outlive the transfer");
            drop(root);
        }

        #[test]
        fn wrong_key_or_unsupported_layout_aborts_without_exposing_a_single_sample() {
            let built = build(&Spec::default(), &plain_fragments(2, 4), &FragmentOptions::default());
            let (_root, path) = staged(&built);
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            assert!(gate.provide_cenc_key(Zeroizing::new(vec![0xa5; 16])));
            gate.attach(File::open(&path).unwrap()).unwrap();
            let (lease, _) = gate.stream().lease();
            gate.notify(PrefixEvent::Available { generation: 0, bytes: built.encrypted.len() as u64 });
            assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
            assert_eq!(gate.rejection(), Some("cenc_key_rejected"));
            assert!(gate.cenc_key.lock().unwrap().is_none());

            let cbcs = build(&Spec { scheme: *b"cbcs", ..Spec::default() }, &plain_fragments(1, 2), &FragmentOptions::default());
            let (_other, cbcs_path) = staged(&cbcs);
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            assert!(gate.provide_cenc_key(Zeroizing::new(KEY.to_vec())));
            gate.attach(File::open(&cbcs_path).unwrap()).unwrap();
            let (lease, _) = gate.stream().lease();
            gate.notify(PrefixEvent::Available { generation: 0, bytes: cbcs.encrypted.len() as u64 });
            assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
            assert_eq!(gate.rejection(), Some("cenc_unsupported_scheme"));
        }

        #[test]
        fn without_a_key_protected_media_is_still_refused_and_only_audio_operations_take_a_key() {
            let built = build(&Spec::default(), &plain_fragments(1, 2), &FragmentOptions::default());
            let (_root, path) = staged(&built);
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            gate.attach(File::open(&path).unwrap()).unwrap();
            let (lease, _) = gate.stream().lease();
            gate.notify(PrefixEvent::Available { generation: 0, bytes: built.encrypted.len() as u64 });
            assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
            assert!(gate.rejection().is_some());
            for kind in [InspectionKind::None, InspectionKind::Fmp4] {
                assert!(!CandidateGate::new_inspected(kind).provide_cenc_key(Zeroizing::new(KEY.to_vec())));
            }
            let late = CandidateGate::new_inspected(InspectionKind::Audio);
            late.notify(PrefixEvent::Invalidate { generation: 0 });
            assert!(!late.provide_cenc_key(Zeroizing::new(KEY.to_vec())), "a key arriving after the transfer started is ignored");
        }

        #[test]
        fn a_retry_rearms_the_decryptor_and_old_clear_bytes_are_revoked() {
            let built = build(&Spec::default(), &plain_fragments(2, 4), &FragmentOptions::default());
            let (_root, path) = staged(&built);
            let gate = CandidateGate::new_inspected(InspectionKind::Audio);
            assert!(gate.provide_cenc_key(Zeroizing::new(KEY.to_vec())));
            gate.attach(File::open(&path).unwrap()).unwrap();
            let (first, _) = gate.stream().lease();
            gate.notify(PrefixEvent::Available { generation: 0, bytes: (built.samples[1].0 + 3) as u64 });
            assert!(drain(&first, &built) > 0);
            gate.notify(PrefixEvent::Invalidate { generation: 0 });
            assert!(matches!(first.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
            let (second, _) = gate.stream().lease();
            assert_eq!(drain(&second, &built), 0, "nothing from the old generation may remain");
            let total = built.encrypted.len() as u64;
            gate.notify(PrefixEvent::Available { generation: 1, bytes: total });
            assert_eq!(drain(&second, &built), total);
        }
    }

    #[cfg(unix)]
    #[test]
    fn returned_symlink_cannot_be_opened_as_validated_capability() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("audio"), b"audio").unwrap();
        std::os::unix::fs::symlink("audio", root.path().join("link")).unwrap();
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(root.path()).unwrap();
        assert!(files.resolve("link").unwrap().open_native_read().is_err());
    }
}
