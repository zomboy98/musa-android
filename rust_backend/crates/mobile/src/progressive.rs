//! Experimental type adapter only. There is deliberately no exported factory
//! until a session is bound to an authorized download operation.

use mornye_extensions::{LeaseCancellation, LeaseState, NextCandidate, PrefixLease, ProgressiveOperation, ReadAtError, ReadAtResult};
use crate::manager::ExtensionManager;
use std::sync::{Arc, Weak};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

#[derive(uniffi::Enum)]
pub enum ProgressiveRead {
    Bytes { bytes: Vec<u8> },
    Pending,
    End,
}

#[derive(uniffi::Enum)]
pub enum ProgressiveLeaseState { Pending, Invalidated, Committed, Aborted }

#[derive(uniffi::Enum)]
pub enum ProgressiveNext {
    Available { sequence: u64, lease: Arc<ProgressiveLease> },
    Pending,
    Finished,
    Closed,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ProgressiveReadError {
    #[error("lease cancelled")]
    Cancelled,
    #[error("lease invalidated")]
    Invalidated,
    #[error("transfer aborted")]
    Aborted,
    #[error("invalid read bounds")]
    InvalidInput,
    #[error("progressive reader unavailable")]
    Unavailable,
}

impl From<ReadAtError> for ProgressiveReadError {
    fn from(value: ReadAtError) -> Self {
        match value {
            ReadAtError::Cancelled => Self::Cancelled,
            ReadAtError::Invalidated => Self::Invalidated,
            ReadAtError::Aborted => Self::Aborted,
            ReadAtError::InvalidInput => Self::InvalidInput,
            ReadAtError::NotAttached | ReadAtError::Io(_) => Self::Unavailable,
        }
    }
}

#[derive(uniffi::Object)]
pub struct ProgressiveLease {
    lease: PrefixLease,
    cancellation: LeaseCancellation,
}

#[derive(uniffi::Object)]
pub struct ProgressiveSession {
    owner: Weak<()>,
    operation: Arc<ProgressiveOperation>,
    claimed: AtomicBool,
}

impl ProgressiveSession {
    /// Generic audio session: mp3, aac/adts, flac, ogg, wav, fMP4 and M4A with
    /// a leading moov are exposed while they arrive. Unrecognised or
    /// non-streamable media aborts the lease so the caller can fall back.
    pub(crate) fn new(owner: &Arc<()>) -> Arc<Self> {
        Arc::new(Self { owner: Arc::downgrade(owner), operation: Arc::new(ProgressiveOperation::generic_audio()), claimed: AtomicBool::new(false) })
    }

    fn provisional_fmp4(owner: &Arc<()>) -> Arc<Self> {
        Arc::new(Self { owner: Arc::downgrade(owner), operation: Arc::new(ProgressiveOperation::provisional_fmp4()), claimed: AtomicBool::new(false) })
    }

    pub(crate) fn claim(&self, owner: &Arc<()>) -> Result<Arc<ProgressiveOperation>, ProgressiveReadError> {
        if !self.owner.upgrade().is_some_and(|expected| Arc::ptr_eq(&expected, owner)) ||
            self.claimed.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
            return Err(ProgressiveReadError::Unavailable);
        }
        Ok(self.operation.clone())
    }
}

impl Drop for ProgressiveSession {
    fn drop(&mut self) { self.operation.close(); }
}

#[uniffi::export]
impl ProgressiveSession {
    /// Call on an IO thread. Sequence is an opaque per-session generation.
    pub fn next_lease(&self, after_sequence: u64, timeout_ms: u32) -> Result<ProgressiveNext, ProgressiveReadError> {
        if self.owner.upgrade().is_none() { self.operation.close(); return Ok(ProgressiveNext::Closed); }
        Ok(match self.operation.next_lease(after_sequence, Duration::from_millis(timeout_ms.into())).map_err(|_| ProgressiveReadError::InvalidInput)? {
            NextCandidate::Available { sequence, lease, cancellation } => ProgressiveNext::Available { sequence, lease: ProgressiveLease::from_host(lease, cancellation) },
            NextCandidate::Pending => ProgressiveNext::Pending,
            NextCandidate::Finished => ProgressiveNext::Finished,
            NextCandidate::Closed => ProgressiveNext::Closed,
        })
    }

    pub fn cancel_session(&self) { self.operation.close(); }
}

#[uniffi::export]
impl ExtensionManager {
    pub fn create_progressive_session(&self) -> Arc<ProgressiveSession> {
        ProgressiveSession::new(&self.progressive_owner)
    }

    /// Explicit provisional attempt. This inspects bounded fMP4 metadata but
    /// does not assert absence of DRM; caller must abort on decoder errors and
    /// use complete-download fallback when unavailable or unsupported.
    pub fn create_provisional_fmp4_session(&self) -> Arc<ProgressiveSession> {
        ProgressiveSession::provisional_fmp4(&self.progressive_owner)
    }

    /// Runs the existing temporary download on a background thread. The session
    /// is single-use and accepted only by the manager that created it.
    /// No trusted clear-media admission or automatic full-download fallback is
    /// wired in production yet; an unavailable result requires the caller to
    /// choose the existing complete-download path explicitly.
    pub fn download_progressive(&self, request_json: String, session: Arc<ProgressiveSession>) -> Result<String, ProgressiveReadError> {
        let operation = session.claim(&self.progressive_owner)?;
        self.inner.download_by_strategy_progressive(&request_json, &|| Ok(()), operation)
            .map_err(|_| ProgressiveReadError::Unavailable)
    }
}

impl ProgressiveLease {
    #[allow(dead_code)]
    pub(crate) fn from_host(lease: PrefixLease, cancellation: LeaseCancellation) -> Arc<Self> {
        Arc::new(Self { lease, cancellation })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use sha2::{Digest, Sha256};

    fn carefree_match(value: &serde_json::Value) -> Option<String> {
        if value.get("error").is_some() || value.get("error_type").is_some() || value.get("verification_required").is_some() { return None; }
        let rows = value.as_array().or_else(|| value.get("tracks").and_then(|v| v.as_array())).or_else(|| value.get("items").and_then(|v| v.as_array()))?;
        let mut matches = Vec::new();
        for row in rows {
            let track = row.get("track").filter(|v| v.is_object()).unwrap_or(row);
            let title = track.get("name").or_else(|| track.get("title")).and_then(|v| v.as_str()).unwrap_or("");
            let artists = track.get("artists").or_else(|| track.get("artist")).or_else(|| track.get("artist_name"));
            let artist_matches = match artists {
                Some(serde_json::Value::String(s)) => s.trim().eq_ignore_ascii_case("Kevin MacLeod"),
                Some(serde_json::Value::Array(a)) => a.len() == 1 && a[0].as_str().or_else(|| a[0].get("name").and_then(|v| v.as_str())).is_some_and(|s| s.trim().eq_ignore_ascii_case("Kevin MacLeod")),
                _ => false,
            };
            let duration_matches = match track.get("duration_ms") { None | Some(serde_json::Value::Null) => true, Some(v) => v.as_u64().is_some_and(|n| n == 0 || (195_000..=215_000).contains(&n)) };
            let id = track.get("id").or_else(|| track.get("track_id")).and_then(|v| v.as_str()).unwrap_or("");
            if title.trim().eq_ignore_ascii_case("Carefree") && artist_matches && duration_matches && id.len() == 11 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') { matches.push(id.to_owned()); }
        }
        if matches.len() == 1 { matches.pop() } else { None }
    }

    #[test]
    fn carefree_search_requires_one_exact_unambiguous_match() {
        let row = serde_json::json!({"id":"abcdefghijk","name":"Carefree","artists":[{"name":"Kevin MacLeod"}],"duration_ms":205125});
        assert_eq!(carefree_match(&serde_json::json!([row.clone()])), Some("abcdefghijk".into()));
        assert_eq!(carefree_match(&serde_json::json!([row.clone(), row.clone()])), None);
        assert_eq!(carefree_match(&serde_json::json!([{"id":"abcdefghijk","name":"Carefree remix","artist":"Kevin MacLeod"}])), None);
        assert_eq!(carefree_match(&serde_json::json!([{"id":"abcdefghijk","name":"Carefree","artist":"Kevin MacLeod cover"}])), None);
        assert_eq!(carefree_match(&serde_json::json!({"error_type":"verification_required","tracks":[row]})), None);
        assert_eq!(carefree_match(&serde_json::json!([{"id":"abcdefghijk","name":"Carefree","artist":"Kevin MacLeod","duration_ms":80000}])), None);
    }

    /// Explicit opt-in: uses the unmodified local extension and a clean, isolated
    /// profile. Host attribution is unknown; extension fallback may use a third
    /// party. Never print provider responses, credentials, paths or URLs.
    #[test]
    #[ignore = "requires explicit network authorization and local extension bundle"]
    fn live_youtube_progressive_opt_in() {
        let bundle = match std::env::var("MORNYE_LIVE_YOUTUBE_BUNDLE") { Ok(v) => v, Err(_) => return };
        let soundcloud = std::env::var_os("MORNYE_LIVE_SOUNDCLOUD").is_some();
        let alternate = std::env::var_os("MORNYE_ALTERNATE_TRACK").is_some();
        let provider = if soundcloud { "soundcloud" } else { "ytmusic-spotiflac" };
        let root = tempfile::tempdir().unwrap();
        let manager = Arc::new(ExtensionManager::new(root.path().join("extensions").to_string_lossy().into_owned(), root.path().join("data").to_string_lossy().into_owned(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into(), "4.9.1".into(), 0).unwrap());
        manager.environment().log_buffer().set_enabled(true).unwrap();
        let output = root.path().join("output"); let normal_output = root.path().join("normal"); std::fs::create_dir_all(&output).unwrap(); std::fs::create_dir_all(&normal_output).unwrap();
        manager.environment().set_allowed_download_directories(vec![output.to_string_lossy().into_owned(), normal_output.to_string_lossy().into_owned()]).unwrap();
        if manager.install(bundle).is_err() { println!("status=install_failed"); return; }
        if manager.load_all().is_err() { println!("status=load_failed"); return; }
        if manager.set_enabled(provider.into(), true).is_err() { println!("status=enable_failed"); return; }
        let track_id = if soundcloud {
            let result = manager.custom_search_json(provider.into(), if alternate { "Monkeys Spinning Monkeys Kevin MacLeod" } else { "Carefree Kevin MacLeod" }.into(), r#"{"filter":"tracks","limit":5}"#.into(), None);
            let rows = result.ok().and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()).and_then(|v| v.as_array().cloned()).unwrap_or_default();
            let matched = rows.iter().find(|row| { let title = row.get("title").or_else(|| row.get("name")).and_then(|v| v.as_str()).unwrap_or("").to_lowercase(); let artists = row.get("artists").or_else(|| row.get("artist")).map(|v| v.to_string().to_lowercase()).unwrap_or_default(); let duration = row.get("duration_ms").and_then(|v| v.as_u64()).unwrap_or(0); if alternate { title.contains("monkeys spinning monkeys") && artists.contains("kevin macleod") && duration > 0 } else { title.contains("carefree") && artists.contains("kevin macleod") && duration > 0 } });
            if alternate { println!("alternate_match={} result_count={}", matched.is_some(), rows.len()); manager.shutdown(); return; }
            match matched.and_then(|v| v.get("id")).and_then(|v| v.as_str()) { Some(id) => id.to_owned(), None => { println!("status=no_verified_search_match result_count={}", rows.len()); manager.shutdown(); return; } }
        } else {
            let result = manager.custom_search_json(provider.into(), "Carefree Kevin MacLeod".into(), "{}".into(), None);
            let matched = result.ok().and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok()).and_then(|v| carefree_match(&v));
            match matched { Some(id) => id, None => { println!("status=no_unambiguous_search_match"); manager.shutdown(); return; } }
        };
        let session = manager.create_provisional_fmp4_session();
        let mut request_value = serde_json::json!({"contract_version":1,"service":provider,"download_provider":provider,"source":provider,"provider_track_id":track_id,"spotify_id":track_id,"temporary_playback":true,"use_extensions":true,"use_fallback":false,"output_dir":output,"track_name":if soundcloud { "daño" } else { "Carefree" },"artist_name":if soundcloud { "Peso Pluma, Tito Double P" } else { "Kevin MacLeod" },"album_name":"","filename_format":"{title}","quality":if soundcloud { "aac_160" } else { "best" },"embed_metadata":false,"embed_lyrics":false,"auto_convert_downloads":false});
        if soundcloud {
            request_value["output_dir"] = serde_json::json!(normal_output);
            let started = std::time::Instant::now();
            println!("phase=normal_download");
            let normal = manager.download_by_strategy(request_value.to_string());
            if let Ok(raw) = normal { if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                let success = v.get("success").and_then(|x| x.as_bool()).unwrap_or(false);
                let kind = v.get("error_type").and_then(|x| x.as_str()).unwrap_or("none");
                let kind = if kind.len() <= 48 && kind.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_') { kind } else { "redacted" };
                println!("normal_success={success} normal_error_type={kind} normal_elapsed_ms={}", started.elapsed().as_millis());
                if success { if let Ok(files) = std::fs::read_dir(&normal_output) { for file in files.flatten() { if let Ok(mut input) = std::fs::File::open(file.path()) { let mut hash = Sha256::new(); let mut count = 0u64; let mut buf = [0u8; 65536]; loop { match input.read(&mut buf) { Ok(0) => break, Ok(n) => { hash.update(&buf[..n]); count += n as u64; }, Err(_) => { count = 0; break; } } } if count > 0 { let hex: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect(); println!("normal_bytes={count} normal_sha256={hex}"); } } } } }
            } } else { println!("normal_status=operation_error"); }
            if std::env::var_os("MORNYE_NORMAL_ONLY").is_some() { manager.shutdown(); return; }
            request_value["output_dir"] = serde_json::json!(output);
        }
        let request = request_value.to_string();
        let start = std::time::Instant::now();
        let (tx, rx) = mpsc::channel(); let worker_manager = manager.clone(); let worker_session = session.clone();
        let _worker = std::thread::spawn(move || { let _ = tx.send(worker_manager.download_progressive(request, worker_session)); });
        let mut first = None; let mut lease = None; let mut sequence = 0; let mut completed = false;
        while start.elapsed() < Duration::from_secs(45) {
            if let Ok(result) = rx.try_recv() { let success = result.ok().and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()).and_then(|v| v.get("success").and_then(|v| v.as_bool())).unwrap_or(false); completed = success; println!("status={} first_prefix_ms={} origin=unknown", if success {"complete"} else {"failed"}, first.map_or(-1, |v: u128| v as i64)); break; }
            match session.next_lease(sequence, 250) {
                Ok(ProgressiveNext::Available { sequence: s, lease: l }) => { sequence = s; lease = Some(l); },
                Ok(ProgressiveNext::Closed | ProgressiveNext::Finished) | Err(_) => {
                    let status = match rx.recv_timeout(Duration::from_secs(2)) {
                        Ok(Ok(raw)) => match serde_json::from_str::<serde_json::Value>(&raw) {
                            Ok(v) if v.get("success").and_then(|s| s.as_bool()) == Some(true) => "complete",
                            Ok(v) => { let safe = |s: &str| if s.len() <= 48 && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_') { s.to_owned() } else { "redacted".to_owned() }; if let Some(kind) = v.get("error_type").and_then(|x| x.as_str()) { println!("error_type={}", safe(kind)); } let message = v.get("error_message").or_else(|| v.get("error")).and_then(|x| x.as_str()).unwrap_or("").to_lowercase(); for (needle, category) in [("hls", "hls"), ("playlist", "playlist"), ("segment", "segment"), ("progressive", "progressive"), ("encrypt", "encrypted"), ("unsupported", "unsupported"), ("duration", "duration"), ("timeout", "timeout"), ("network", "network"), ("verification", "verification"), ("403", "http_403"), ("404", "http_404"), ("429", "http_429"), ("ffmpeg", "ffmpeg")] { if message.contains(needle) { println!("detail_category={category}"); } } if let Some(attempts) = v.get("provider_attempts").and_then(|a| a.as_array()) { for attempt in attempts { if let Some(stage) = attempt.get("stage").and_then(|s| s.as_str()) { println!("attempt_stage={}", safe(stage)); } if let Some(kind) = attempt.get("error_type").and_then(|s| s.as_str()) { println!("attempt_type={}", safe(kind)); } } } match v.get("error_type").and_then(|s| s.as_str()) {
                                Some("invalid_request") => "failed_invalid_request",
                                Some("provider_unavailable") => "failed_provider_unavailable",
                                Some("verification_required") => "failed_verification_required",
                                Some("transient_network") => "failed_transient_network",
                                Some("integrity_failed") => "failed_integrity",
                                Some("not_found") => "failed_not_found",
                                _ => "failed_other",
                            } },
                            Err(_) => "invalid_result",
                        },
                        Ok(Err(_)) => "operation_error",
                        Err(_) => "result_pending",
                    };
                    completed = status == "complete"; println!("status={status} first_prefix_ms={} origin=unknown", first.map_or(-1, |v: u128| v as i64)); break;
                },
                _ => {}
            }
            if first.is_none() { if let Some(l) = &lease { if let Ok(ProgressiveRead::Bytes { bytes }) = l.read_at(0, 4096, 100) { first = Some(start.elapsed().as_millis()); println!("first_prefix_bytes={}", bytes.len()); } } }
        }
        if let Ok(logs) = manager.environment().log_buffer().all() {
            let entries: Vec<serde_json::Value> = serde_json::from_str(&logs).unwrap_or_default();
            for entry in entries {
                let text = entry.get("message").and_then(|v| v.as_str()).unwrap_or("").to_lowercase();
                if !text.contains("stream attempt failed") { continue; }
                for (needle, category) in [("hls", "hls"), ("playlist", "playlist"), ("segment", "segment"), ("progressive", "progressive"), ("encrypt", "encrypted"), ("unsupported", "unsupported"), ("duration", "duration"), ("timeout", "timeout"), ("network", "network"), ("verification", "verification"), ("403", "http_403"), ("404", "http_404"), ("429", "http_429"), ("ffmpeg", "ffmpeg")] { if text.contains(needle) { println!("log_category={category}"); } }
            }
        }
        if completed { if let Ok(files) = std::fs::read_dir(&output) { for file in files.flatten() { if let Ok(mut input) = std::fs::File::open(file.path()) { let mut hash = Sha256::new(); let mut count = 0u64; let mut buf = [0u8; 65536]; loop { match input.read(&mut buf) { Ok(0) => break, Ok(n) => { hash.update(&buf[..n]); count += n as u64; }, Err(_) => { count = 0; break; } } } if count > 0 { let hex: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect(); println!("completed_bytes={count} completed_sha256={hex}"); } } } } }
        session.cancel_session(); manager.shutdown();
        println!("elapsed_ms={} origin=unknown", start.elapsed().as_millis());
    }

    fn pseudo(seed: u8, len: usize) -> Vec<u8> { (0..len).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)).collect() }

    fn with_head(head: &[u8], total: usize) -> Vec<u8> { let mut body = head.to_vec(); body.extend(pseudo(head[0], total - head.len())); body }

    const M4A_FTYP_LEN: usize = 24;

    fn aac_init() -> Vec<u8> {
        let mut entry = vec![0; 28]; entry.extend(atom(b"esds", &[0; 4]));
        let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
        let moov = atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &atom(b"stbl", &atom(b"stsd", &stsd))))));
        let mut body = atom(b"ftyp", b"M4A \0\0\0\0M4A isom"); body.extend(moov); body
    }

    /// Serves `body` over loopback, half first and the rest only after the lease
    /// has been read, and drives the generic `create_progressive_session` door.
    fn generic_session_case(body: Vec<u8>, ext: &'static str, announce_length: bool, accepted: bool, reason: &str) {
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let expected = body.clone();
        let first = body.len() / 2;
        let (ready_tx, ready_rx) = mpsc::channel(); let (resume_tx, resume_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut request = [0; 4096]; let n = socket.read(&mut request).unwrap();
            assert!(!String::from_utf8_lossy(&request[..n]).to_ascii_lowercase().contains("\r\nrange:"));
            let length = if announce_length { format!("Content-Length: {}\r\n", body.len()) } else { String::new() };
            write!(socket, "HTTP/1.1 200 OK\r\n{length}Connection: close\r\n\r\n").unwrap();
            socket.write_all(&body[..first]).unwrap(); socket.flush().unwrap(); ready_tx.send(()).unwrap();
            resume_rx.recv_timeout(Duration::from_secs(10)).unwrap(); let _ = socket.write_all(&body[first..]);
        });
        let sources = root.path().join("sources"); let provider = sources.join("example.audio"); std::fs::create_dir_all(&provider).unwrap();
        std::fs::write(provider.join("manifest.json"), serde_json::json!({"name":"example.audio","version":"1","description":"local fixture","type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"aac_128","kind":"lossy"}]}).to_string()).unwrap();
        std::fs::write(provider.join("index.js"), format!(r#"registerExtension({{download(id,q,path){{let d=file.download({url:?},path,{{maxAttempts:1,resume:false,chunked:true}});return d.success?{{success:true,file_path:d.path,actual_extension:{ext:?}}}:d;}}}});"#)).unwrap();
        let manager = Arc::new(ExtensionManager::new(sources.to_string_lossy().into_owned(), root.path().join("data").to_string_lossy().into_owned(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into(), "1".into(), 0).unwrap());
        let env = manager.environment(); env.set_allow_private_network(true).unwrap();
        let output = root.path().join("output"); std::fs::create_dir_all(&output).unwrap();
        env.set_allowed_download_directories(vec![output.to_string_lossy().into_owned()]).unwrap();
        manager.load_all().unwrap(); manager.set_enabled("example.audio".into(), true).unwrap();
        let session = manager.create_progressive_session();
        let request = serde_json::json!({"service":"example.audio","source":"example.audio","provider_track_id":"track","temporary_playback":true,"use_extensions":true,"use_fallback":false,"output_dir":output,"track_name":"Track","artist_name":"Artist","album_name":"Album","filename_format":"{title}","output_ext":ext,"quality":"aac_128","allow_quality_fallback":true,"embed_metadata":false,"embed_lyrics":false}).to_string();
        let worker_manager = manager.clone(); let worker_session = session.clone();
        let worker = std::thread::spawn(move || worker_manager.download_progressive(request, worker_session));
        ready_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let lease = match session.next_lease(0, 1000).unwrap() { ProgressiveNext::Available { lease, .. } => lease, _ => panic!("{reason}: candidate unavailable") };
        let total = expected.len() as u64;
        if accepted {
            match lease.read_at(0, 4096, 1000).unwrap() {
                ProgressiveRead::Bytes { bytes } => { assert!(!bytes.is_empty(), "{reason}"); assert_eq!(bytes[..], expected[..bytes.len()], "{reason}"); }
                _ => panic!("{reason}: no bytes while the file is still arriving"),
            }
            assert_eq!(lease.size().unwrap(), announce_length.then_some(total), "{reason}: size before commit");
            assert!(matches!(lease.read_at(total, 1, 0).unwrap(), ProgressiveRead::Pending), "{reason}");
            assert!(matches!(lease.wait_terminal(0).unwrap(), ProgressiveLeaseState::Pending), "{reason}");
        } else {
            assert!(matches!(lease.read_at(0, 1, 1000), Err(ProgressiveReadError::Aborted)), "{reason}: must abort on first read");
            assert!(matches!(lease.wait_terminal(0).unwrap(), ProgressiveLeaseState::Aborted), "{reason}");
        }
        resume_tx.send(()).unwrap();
        let result = worker.join().unwrap(); server.join().unwrap();
        if accepted {
            let result: serde_json::Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["success"], true, "{reason}: {result}");
            assert!(matches!(lease.read_at(total, 1, 0).unwrap(), ProgressiveRead::End), "{reason}");
            assert_eq!(lease.size().unwrap(), Some(total), "{reason}: size after commit");
            assert!(matches!(lease.wait_terminal(0).unwrap(), ProgressiveLeaseState::Committed), "{reason}");
            let saved = std::fs::read(output.join(format!("Track{ext}"))).unwrap();
            assert_eq!(Sha256::digest(&saved), Sha256::digest(&expected), "{reason}");
        } else {
            assert!(result.is_err() || serde_json::from_str::<serde_json::Value>(&result.unwrap()).unwrap()["success"] != true, "{reason}");
            assert!(!output.join(format!("Track{ext}")).exists(), "{reason}: rejected media must not be published");
        }
        session.cancel_session(); manager.shutdown();
    }

    #[test]
    fn generic_session_streams_mp3_flac_ogg_wav_and_adts_while_the_file_arrives() {
        let fixtures: [(&str, &'static str, Vec<u8>); 6] = [
            ("mp3 frames", ".mp3", with_head(&[0xff, 0xfb, 0x90, 0x64], 24_000)),
            ("mp3 id3", ".mp3", with_head(b"ID3\x04\0\0\0\0\0\x10", 24_000)),
            ("flac", ".flac", with_head(b"fLaC", 24_000)),
            ("ogg", ".ogg", with_head(b"OggS\0\x02", 24_000)),
            ("wav", ".wav", with_head(b"RIFF\x24\x5d\0\0WAVEfmt ", 24_000)),
            ("adts", ".aac", with_head(&[0xff, 0xf1, 0x50, 0x80], 24_000)),
        ];
        for (reason, ext, body) in fixtures { generic_session_case(body, ext, true, true, reason); }
    }

    #[test]
    fn generic_session_reports_unknown_size_when_the_server_gives_no_length() {
        generic_session_case(with_head(&[0xff, 0xfb, 0x90, 0x64], 24_000), ".mp3", false, true, "mp3 without content-length");
        generic_session_case(with_head(b"fLaC", 24_000), ".flac", false, true, "flac without content-length");
    }

    #[test]
    fn generic_session_streams_fmp4_and_m4a_with_leading_moov() {
        let mut fragmented = atom(b"ftyp", b"isom\0\0\0\0");
        fragmented.extend(aac_init()[M4A_FTYP_LEN..].to_vec());
        let mut traf = atom(b"tfhd", &[0; 8]); traf.extend(atom(b"trun", &[0,0,0,0,0,0,0,1]));
        fragmented.extend(atom(b"moof", &atom(b"traf", &traf))); fragmented.extend(atom(b"mdat", &vec![0x55; 8192]));
        generic_session_case(fragmented, ".m4a", true, true, "fmp4");
        let mut classic = aac_init(); classic.extend(atom(b"mdat", &vec![0x55; 16_384]));
        generic_session_case(classic, ".m4a", true, true, "m4a moov first");
    }

    #[test]
    fn generic_session_aborts_unsupported_media_so_the_caller_can_use_the_complete_download() {
        let mut late_moov = atom(b"ftyp", b"M4A \0\0\0\0M4A isom");
        late_moov.extend(atom(b"mdat", &vec![0x55; 16_384])); late_moov.extend(aac_init()[M4A_FTYP_LEN..].to_vec());
        generic_session_case(late_moov, ".m4a", true, false, "m4a moov at end");
        generic_session_case(with_head(&[0x1a, 0x45, 0xdf, 0xa3], 24_000), ".m4a", true, false, "unrecognized container");
    }

    #[test]
    fn session_is_bound_to_its_owner_and_is_single_use() {
        let owner = Arc::new(());
        let other = Arc::new(());
        let session = ProgressiveSession::new(&owner);
        assert!(session.claim(&other).is_err());
        assert!(session.claim(&owner).is_ok());
        assert!(session.claim(&owner).is_err());
    }

    #[test]
    fn closing_session_wakes_waiter_and_is_idempotent() {
        let owner = Arc::new(());
        let session = ProgressiveSession::new(&owner);
        let waiting = session.clone();
        let thread = std::thread::spawn(move || waiting.next_lease(0, 1000));
        session.cancel_session();
        assert!(matches!(thread.join().unwrap().unwrap(), ProgressiveNext::Closed));
        session.cancel_session();
        assert!(matches!(session.next_lease(0, 0).unwrap(), ProgressiveNext::Closed));
    }

    #[test]
    fn dropping_owner_closes_unclaimed_session() {
        let owner = Arc::new(());
        let session = ProgressiveSession::new(&owner);
        drop(owner);
        assert!(matches!(session.next_lease(0, 0).unwrap(), ProgressiveNext::Closed));
    }

    fn atom(name: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut result = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        result.extend_from_slice(name); result.extend_from_slice(payload); result
    }

    #[test]
    fn public_opt_in_session_streams_provisional_fmp4_and_rejects_other_formats() {
        for compatible in [true, false] {
            let root = tempfile::tempdir().unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}/audio", listener.local_addr().unwrap());
            let mut entry = vec![0; 28]; entry.extend(atom(b"esds", &[0; 4]));
            let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
            let stbl = atom(b"stbl", &atom(b"stsd", &stsd));
            let moov = atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &stbl))));
            let mut body = atom(b"ftyp", b"isom\0\0\0\0"); body.extend(moov);
            let mut traf = atom(b"tfhd", &[0; 8]); traf.extend(atom(b"trun", &[0,0,0,0,0,0,0,1]));
            body.extend(atom(b"moof", &atom(b"traf", &traf))); body.extend(atom(b"mdat", &vec![0x55; 8192]));
            let first = body.len() - 4096;
            if !compatible { body[4..8].copy_from_slice(b"junk"); }
            let expected = body.clone();
            let (ready_tx, ready_rx) = mpsc::channel(); let (resume_tx, resume_rx) = mpsc::channel();
            let server = std::thread::spawn(move || {
                let (mut socket, _) = listener.accept().unwrap();
                socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut request = [0; 4096]; let n = socket.read(&mut request).unwrap();
                assert!(!String::from_utf8_lossy(&request[..n]).to_ascii_lowercase().contains("\r\nrange:"));
                write!(socket, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
                socket.write_all(&body[..first]).unwrap(); socket.flush().unwrap(); ready_tx.send(()).unwrap();
                resume_rx.recv_timeout(Duration::from_secs(10)).unwrap(); let _ = socket.write_all(&body[first..]);
            });
            let sources = root.path().join("sources"); let provider = sources.join("example.audio"); std::fs::create_dir_all(&provider).unwrap();
            std::fs::write(provider.join("manifest.json"), serde_json::json!({"name":"example.audio","version":"1","description":"local fixture","type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"aac_128","kind":"lossy"}]}).to_string()).unwrap();
            std::fs::write(provider.join("index.js"), format!(r#"registerExtension({{download(id,q,path){{let d=file.download({url:?},path,{{maxAttempts:1,resume:false,chunked:true}});return d.success?{{success:true,file_path:d.path,actual_extension:'.m4a'}}:d;}}}});"#)).unwrap();
            let manager = Arc::new(ExtensionManager::new(sources.to_string_lossy().into_owned(), root.path().join("data").to_string_lossy().into_owned(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into(), "1".into(), 0).unwrap());
            let env = manager.environment(); env.set_allow_private_network(true).unwrap();
            let output = root.path().join("output"); std::fs::create_dir_all(&output).unwrap();
            env.set_allowed_download_directories(vec![output.to_string_lossy().into_owned()]).unwrap();
            manager.load_all().unwrap(); manager.set_enabled("example.audio".into(), true).unwrap();
            let session = manager.create_provisional_fmp4_session();
            let request = serde_json::json!({"service":"example.audio","source":"example.audio","provider_track_id":"track","temporary_playback":true,"use_extensions":true,"use_fallback":false,"output_dir":output,"track_name":"Track","artist_name":"Artist","album_name":"Album","filename_format":"{title}","output_ext":".m4a","quality":"aac_128","allow_quality_fallback":true,"embed_metadata":false,"embed_lyrics":false}).to_string();
            let worker_manager = manager.clone(); let worker_session = session.clone();
            let worker = std::thread::spawn(move || worker_manager.download_progressive(request, worker_session));
            ready_rx.recv_timeout(Duration::from_secs(10)).unwrap();
            let lease = match session.next_lease(0, 1000).unwrap() { ProgressiveNext::Available { lease, .. } => lease, _ => panic!("candidate unavailable") };
            if compatible {
                assert!(matches!(lease.read_at(0, 4096, 1000).unwrap(), ProgressiveRead::Bytes { bytes } if !bytes.is_empty()));
                assert!(matches!(lease.read_at(expected.len() as u64, 1, 0).unwrap(), ProgressiveRead::Pending));
                let separate = match session.next_lease(0, 0).unwrap() { ProgressiveNext::Available { lease, .. } => lease, _ => panic!("second lease unavailable") };
                let waiting = separate.clone(); let offset = expected.len() as u64;
                let blocked = std::thread::spawn(move || waiting.read_at(offset, 1, 1000));
                separate.cancel_read(); separate.cancel_read();
                assert!(matches!(blocked.join().unwrap(), Err(ProgressiveReadError::Cancelled)));
            } else {
                assert!(matches!(lease.read_at(0, 1, 1000), Err(ProgressiveReadError::Aborted)));
            }
            resume_tx.send(()).unwrap();
            let result = worker.join().unwrap(); server.join().unwrap();
            if compatible {
                let result: serde_json::Value = serde_json::from_str(&result.unwrap()).unwrap();
                assert_eq!(result["success"], true, "{result}");
                assert!(matches!(lease.read_at(expected.len() as u64, 1, 0).unwrap(), ProgressiveRead::End));
                let saved = std::fs::read(output.join("Track.m4a")).unwrap();
                assert_eq!(Sha256::digest(&saved), Sha256::digest(&expected));
            } else {
                assert!(result.is_err() || serde_json::from_str::<serde_json::Value>(&result.unwrap()).unwrap()["success"] != true);
                assert!(!output.join("Track.m4a").exists());
            }
            session.cancel_session(); manager.shutdown();
        }
    }
}

#[uniffi::export]
impl ProgressiveLease {
    /// Call on an IO thread. Pending is not EOF.
    pub fn read_at(&self, offset: u64, max_bytes: u32, timeout_ms: u32) -> Result<ProgressiveRead, ProgressiveReadError> {
        Ok(match self.lease.read_at(offset, max_bytes as usize, Duration::from_millis(timeout_ms.into()))? {
            ReadAtResult::Bytes(bytes) => ProgressiveRead::Bytes { bytes },
            ReadAtResult::Pending => ProgressiveRead::Pending,
            ReadAtResult::End => ProgressiveRead::End,
        })
    }

    pub fn size(&self) -> Result<Option<u64>, ProgressiveReadError> { self.lease.size().map_err(Into::into) }

    /// A watcher can invalidate a deck even if no read is in progress.
    pub fn wait_terminal(&self, timeout_ms: u32) -> Result<ProgressiveLeaseState, ProgressiveReadError> {
        if timeout_ms > 1000 { return Err(ProgressiveReadError::InvalidInput); }
        let state = self.lease.wait_terminal(Duration::from_millis(timeout_ms.into()))
            .map_err(|_| ProgressiveReadError::Cancelled)?;
        Ok(match state {
            LeaseState::Pending => ProgressiveLeaseState::Pending,
            LeaseState::Invalidated => ProgressiveLeaseState::Invalidated,
            LeaseState::Committed => ProgressiveLeaseState::Committed,
            LeaseState::Aborted => ProgressiveLeaseState::Aborted,
        })
    }

    pub fn cancel_read(&self) { self.cancellation.cancel(); }
}
