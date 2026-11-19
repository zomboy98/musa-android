use super::*;

#[test]
fn provider_attempt_dedup_keeps_different_tracks_and_qualities() {
    let mut seen = BTreeSet::new();
    assert!(first_unique_provider_attempt(&mut seen, "Source", "track", "HIGH"));
    assert!(!first_unique_provider_attempt(&mut seen, "source", "track", "high"));
    assert!(first_unique_provider_attempt(&mut seen, "source", "different-track", "high"));
    assert!(first_unique_provider_attempt(&mut seen, "source", "track", "LOSSLESS"));
    assert!(first_unique_provider_attempt(&mut seen, "other", "track", "high"));
}

#[test]
fn saved_quality_candidate_marker_is_opt_in_and_does_not_claim_verified_quality() {
    let explicit = DownloadRequest::parse(r#"{"quality":"LOSSLESS"}"#).unwrap();
    assert!(!explicit.allow_saved_quality_id_fallback);
    let saved = DownloadRequest::parse(r#"{"quality":"LOSSLESS","allow_saved_quality_id_fallback":true}"#).unwrap();
    assert!(saved.allow_saved_quality_id_fallback);
    let mut response = json!({"success":true});
    report_selected_quality(&mut response, &saved, "LOSSLESS");
    assert_eq!(response["requested_quality"], "LOSSLESS");
    assert_eq!(response["quality_verification"], "bitrate_unverified");
    assert!(response.get("resolved_quality").is_none());
}

#[test]
fn refresh_failures_preserve_only_valid_structured_http_status() {
    for status in [401, 403] {
        let response = provider_failure_from_result("provider", &json!({"error_type":"expired_stream", "http_status":status, "error_message":"sensitive provider detail"}));
        assert_eq!(response["error_type"], "expired_stream");
        assert_eq!(response["http_status"], status);
        assert!(response["error"].as_str().unwrap().contains(&status.to_string()));
        assert!(!response.to_string().contains("sensitive"));
        assert!(!response["error"].as_str().unwrap().contains("expired"));
    }
    for status in [Value::Null, json!(0), json!(999), json!("403")] {
        let response = provider_failure_from_result("provider", &json!({"error_type":"expired_stream", "http_status":status}));
        assert!(response.get("http_status").is_none());
        assert_eq!(response["error_type"], "expired_stream");
        assert!(!response["error"].as_str().unwrap().contains("expired"));
    }
}

#[test]
fn index_failure_after_real_commit_preserves_file_and_success_without_leaking_error() {
    use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(crate::files::FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let path = files.resolve("track.flac").unwrap();
    let mut stage = path.stage().unwrap();
    stage.file.write_all(b"completed artifact").unwrap();
    let registry = CancellationRegistry::new(CancellationDomain::Download);
    let lease = registry.acquire("index-failure").unwrap();
    stage.publish_new_with_lease(&lease).unwrap();
    let response =
        finish_committed_download(json!({"success":true,"file_path":path.absolute}), |_| {
            assert_eq!(
                std::fs::read(&path.absolute).unwrap(),
                b"completed artifact"
            );
            registry.cancel("index-failure").unwrap();
            Err("index failure with sensitive diagnostic".into())
        });
    assert_eq!(response["success"], true);
    assert_eq!(response["index_refresh_pending"], true);
    assert!(!response.to_string().contains("sensitive"));
    assert!(lease.has_committed());
    assert_eq!(
        std::fs::read(&path.absolute).unwrap(),
        b"completed artifact"
    );
}

#[test]
fn vbr_average_is_reported_without_claiming_a_verified_target_rate() {
    let request = DownloadRequest {
        quality: "opus_320".into(),
        ..Default::default()
    };
    for average in [128, 270, 320] {
        let mut response = json!({"success":true,"audio_codec":"opus","actual_bitrate":average});
        report_selected_quality(&mut response, &request, "opus_320");
        assert_eq!(response["requested_quality"], "opus_320");
        assert_eq!(response["provider_selected_quality"], "opus_320");
        assert!(response.get("resolved_quality").is_none());
        assert_eq!(response["quality_verification"], "bitrate_unverified");
        assert_eq!(response["actual_bitrate"], average);
    }
}
use crate::environment::ExtensionEnvironment;
use crate::{
    RuntimeLimits,
    backend::{LyricsRequest, MetadataOptions},
};
use mornye_network::{NetworkOptions, NetworkService};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

/// Opt-in only: `MORNYE_PROGRESSIVE_FIXTURE` points to an existing local file.
/// Never copies the fixture into the repository or logs its path or contents.
#[cfg(feature = "experimental-progressive-reader")]
#[test]
#[ignore = "requires an explicitly supplied local AAC/M4A fixture and desktop ffmpeg"]
fn progressive_external_m4a_fixture_through_real_host_lease_and_pipe() {
    use crate::download::progressive_candidate::ProgressiveOperation;
    use crate::download::progressive_reader::ReadAtResult;
    use sha2::{Digest, Sha256};
    use std::process::{Command, Stdio};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    fn hash(path: &std::path::Path) -> [u8; 32] {
        let mut file = std::fs::File::open(path).expect("local fixture unavailable");
        let mut digest = Sha256::new(); let mut buf = [0; 65536];
        loop { let n = file.read(&mut buf).unwrap(); if n == 0 { break; } digest.update(&buf[..n]); }
        digest.finalize().into()
    }

    let fixture = std::path::PathBuf::from(std::env::var_os("MORNYE_PROGRESSIVE_FIXTURE").expect("set local fixture explicitly"));
    let size = std::fs::metadata(&fixture).unwrap().len();
    assert!(size > 131_072 && size <= 64 * 1024 * 1024);
    let before = hash(&fixture);
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/audio", listener.local_addr().unwrap());
    let (first_tx, first_rx) = mpsc::channel();
    let (continue_tx, continue_rx) = mpsc::channel();
    let server_fixture = fixture.clone();
    let completed = Arc::new(AtomicBool::new(false));
    let server_completed = completed.clone();
    let server = thread::spawn(move || {
        let (mut client, _) = listener.accept().unwrap();
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut request = [0; 4096]; let _ = client.read(&mut request).unwrap();
        write!(client, "HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n").unwrap();
        let mut source = std::fs::File::open(server_fixture).unwrap();
        let mut buf = [0; 65536]; let first = source.read(&mut buf).unwrap();
        client.write_all(&buf[..first]).unwrap(); client.flush().unwrap(); first_tx.send(()).unwrap();
        continue_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        loop {
            let n = source.read(&mut buf).unwrap(); if n == 0 { break; }
            client.write_all(&buf[..n]).unwrap(); client.flush().unwrap();
            thread::sleep(Duration::from_millis(10));
        }
        server_completed.store(true, Ordering::Release);
    });
    let source = root.path().join("sources/example.audio"); std::fs::create_dir_all(&source).unwrap();
    std::fs::write(source.join("manifest.json"), json!({"name":"example.audio","version":"1","description":"local test", "type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"aac_128","kind":"lossy"}]}).to_string()).unwrap();
    std::fs::write(source.join("index.js"), format!(r#"registerExtension({{download(id,quality,path){{let d=file.download({url:?},path,{{maxAttempts:1,resume:false}});if(!d.success)return d;return {{success:true,file_path:d.path,actual_extension:'.m4a'}};}}}});"#)).unwrap();
    let backend = Arc::new(Backend::new(&root.path().join("sources"), &root.path().join("data"), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap());
    backend.environment().set_allow_private_network(true).unwrap(); backend.load_all().unwrap(); backend.set_enabled("example.audio", true).unwrap();
    let output = root.path().join("output"); std::fs::create_dir_all(&output).unwrap();
    backend.environment().set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
    let request = json!({"service":"example.audio","source":"example.audio","provider_track_id":"track","temporary_playback":true,"use_extensions":true,"use_fallback":false,"output_dir":output,"track_name":"Track","artist_name":"Artist","album_name":"Album","filename_format":"{title}","output_ext":".m4a","quality":"aac_128","allow_quality_fallback":true,"embed_metadata":false,"embed_lyrics":false}).to_string();
    // Test-only admission trusts this caller-supplied local fixture; it is not
    // evidence of DRM or clear-media status for a live provider.
    let operation = Arc::new(ProgressiveOperation::fmp4_fixture());
    let worker_backend = backend.clone(); let worker_operation = operation.clone();
    let start = Instant::now();
    let worker = thread::spawn(move || worker_backend.download_by_strategy_progressive(&request, &|| Ok(()), worker_operation));
    first_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let candidate = loop { if let Some(candidate) = operation.current() { break candidate; } assert!(Instant::now() < deadline); thread::sleep(Duration::from_millis(5)); };
    let (lease, _) = candidate.stream().lease();
    let first = match lease.read_at(0, 4096, Duration::from_secs(1)).unwrap() { ReadAtResult::Bytes(bytes) => bytes, _ => panic!("missing initial bytes") };
    assert!(!first.is_empty());
    assert!(!completed.load(Ordering::Acquire), "first lease access occurred after full transfer");
    let first_access = start.elapsed();

    // FFmpeg receives only a pipe fed by the lease, never the local path/URL.
    let mut ffmpeg = Command::new("ffmpeg").args(["-v","error","-protocol_whitelist","pipe","-format_whitelist","mov","-probesize","32768","-analyzeduration","0","-f","mov","-i","pipe:0","-map","0:a:0","-f","s16le","-acodec","pcm_s16le","pipe:1"])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().expect("desktop ffmpeg unavailable");
    let mut stdin = ffmpeg.stdin.take().unwrap(); let mut stdout = ffmpeg.stdout.take().unwrap();
    let child = Arc::new(std::sync::Mutex::new(ffmpeg));
    let watchdog_child = child.clone();
    let stopped = Arc::new(AtomicBool::new(false));
    let watchdog_stopped = stopped.clone();
    let watchdog = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !watchdog_stopped.load(Ordering::Acquire) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
        }
        if !watchdog_stopped.load(Ordering::Acquire) { let _ = watchdog_child.lock().unwrap().kill(); }
    });
    let (pcm_tx, pcm_rx) = mpsc::channel();
    let decode_start = start;
    let pcm = thread::spawn(move || {
        let mut buf = [0; 65536]; let n = stdout.read(&mut buf).unwrap();
        let _ = pcm_tx.send((n, decode_start.elapsed()));
        let mut total = n as u64; loop { let n = stdout.read(&mut buf).unwrap(); if n == 0 { break; } total += n as u64; } total
    });
    let (pipe_lease, _) = candidate.stream().lease();
    let feeder = thread::spawn(move || {
        let mut offset = 0u64;
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            if Instant::now() >= deadline { return Err("lease feeder timed out"); }
            match pipe_lease.read_at(offset, 65536, Duration::from_secs(1)).map_err(|_| "lease read failed")? {
                ReadAtResult::Bytes(bytes) => { stdin.write_all(&bytes).map_err(|_| "decoder pipe closed")?; offset += bytes.len() as u64; },
                ReadAtResult::Pending => {}, ReadAtResult::End => break,
            }
        }
        Ok(offset)
    });
    let early_pcm = pcm_rx.recv_timeout(Duration::from_secs(3)).ok();
    let pcm_before_complete = early_pcm.as_ref().is_some_and(|(bytes, _)| *bytes > 0) && !completed.load(Ordering::Acquire);
    continue_tx.send(()).unwrap();
    let response: Value = serde_json::from_str(&worker.join().unwrap().unwrap()).unwrap();
    server.join().unwrap(); assert_eq!(response["success"], true, "backend rejected local fixture");
    assert_eq!(feeder.join().unwrap().unwrap(), size);
    let status = loop {
        if let Some(status) = child.lock().unwrap().try_wait().unwrap() { break status; }
        thread::sleep(Duration::from_millis(20));
    };
    stopped.store(true, Ordering::Release); watchdog.join().unwrap();
    assert!(status.success());
    let pcm_bytes = pcm.join().unwrap(); assert!(pcm_bytes > 0);
    assert_eq!(hash(&output.join("Track.m4a")), before);
    assert_eq!(hash(&fixture), before);
    eprintln!("fixture_bytes={size} first_lease_ms={} first_pcm_before_complete={pcm_before_complete} first_pcm_ms={:?} pcm_bytes={pcm_bytes} hash_unchanged=true", first_access.as_millis(), early_pcm.map(|(_, time)| time.as_millis()));
    backend.shutdown();
}

#[cfg(feature = "experimental-progressive-reader")]
#[test]
fn progressive_session_without_trusted_clear_admission_never_starts_provider() {
    use crate::download::progressive_candidate::{NextCandidate, ProgressiveOperation};
    use std::time::Duration;
    let root = tempfile::tempdir().unwrap();
    let backend = Backend::new(&root.path().join("sources"), &root.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap();
    let operation = Arc::new(ProgressiveOperation::default());
    let error = backend.download_by_strategy_progressive("{}", &|| Ok(()), operation.clone()).unwrap_err();
    assert_eq!(error, "trusted clear-audio admission unavailable");
    assert!(matches!(operation.next_lease(0, Duration::ZERO).unwrap(), NextCandidate::Finished));
    backend.shutdown();
}

#[cfg(feature = "experimental-progressive-reader")]
#[test]
fn progressive_backend_binds_real_returned_candidate_and_accepts_only_after_publication() {
    use crate::download::progressive_candidate::ProgressiveOperation;
    use crate::download::progressive_reader::{ReadAtError, ReadAtResult};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    for mode in 0..4 {
        let return_first = mode == 1;
        let cancel = mode == 2;
        let truncate = mode == 3;
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let (ready_tx, ready_rx) = mpsc::channel();
        let (continue_tx, continue_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut request = [0; 4096]; let _ = stream.read(&mut request).unwrap();
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n").unwrap();
                stream.write_all(&[if index == 0 { 0x11 } else { 0x22 }; 4096]).unwrap();
                stream.flush().unwrap(); ready_tx.send(index).unwrap();
                continue_rx.recv_timeout(Duration::from_secs(10)).unwrap();
                if !(truncate && index == 1) {
                    let _ = stream.write_all(&[if index == 0 { 0x11 } else { 0x22 }; 4096]);
                }
            }
        });
        let source = root.path().join("sources/example.audio");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("manifest.json"), json!({"name":"example.audio","version":"1", "description":"test", "type":["download_provider"], "permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true}, "skipMetadataEnrichment":true, "qualityOptions":[{"id":"mp3_128","kind":"lossy"}]}).to_string()).unwrap();
        std::fs::write(source.join("index.js"), format!(r#"registerExtension({{download(id,quality,path){{let first=file.download({url:?},path+'.first',{{maxAttempts:1,resume:false}});if(!first.success)return first;let second=file.download({url:?},path,{{maxAttempts:1,resume:false}});if(!second.success)return second;return {{success:true,file_path:{returned},actual_extension:'.mp3'}};}}}});"#, returned = if return_first { "first.path" } else { "second.path" })).unwrap();
        let backend = Arc::new(Backend::new(&root.path().join("sources"), &root.path().join("data"), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap());
        backend.environment().set_allow_private_network(true).unwrap();
        backend.load_all().unwrap(); backend.set_enabled("example.audio", true).unwrap();
        let output = root.path().join("output"); std::fs::create_dir_all(&output).unwrap();
        backend.environment().set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
        let request = json!({"service":"example.audio","source":"example.audio","provider_track_id":"track", "temporary_playback":true,"use_extensions":true,"use_fallback":false,"output_dir":output,"track_name":"Track","artist_name":"Artist","album_name":"Album","filename_format":"{title}","output_ext":".mp3","quality":"mp3_128","allow_quality_fallback":true,"embed_metadata":false,"embed_lyrics":false}).to_string();
        let operation = Arc::new(ProgressiveOperation::clear_fixture());
        let worker_backend = backend.clone(); let worker_operation = operation.clone();
        let worker = thread::spawn(move || worker_backend.download_by_strategy_progressive(&request, &|| Ok(()), worker_operation));
        assert_eq!(ready_rx.recv_timeout(Duration::from_secs(10)).unwrap(), 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        let first = loop { if let Some(candidate) = operation.current() { break candidate; } assert!(Instant::now() < deadline); thread::sleep(Duration::from_millis(5)); };
        let (first_lease, _) = first.stream().lease();
        assert!(matches!(first_lease.read_at(0, 4096, Duration::from_secs(1)).unwrap(), ReadAtResult::Bytes(bytes) if bytes.iter().all(|b| *b == 0x11)));
        continue_tx.send(()).unwrap();
        assert_eq!(ready_rx.recv_timeout(Duration::from_secs(10)).unwrap(), 1);
        assert!(matches!(first_lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
        let second = operation.current().unwrap();
        let (second_lease, _) = second.stream().lease();
        assert!(matches!(second_lease.read_at(0, 4096, Duration::from_secs(1)).unwrap(), ReadAtResult::Bytes(bytes) if bytes.iter().all(|b| *b == 0x22)));
        assert!(matches!(second_lease.read_at(8192, 1, Duration::ZERO).unwrap(), ReadAtResult::Pending));
        if cancel { operation.close(); }
        continue_tx.send(()).unwrap();
        let result = worker.join().unwrap();
        server.join().unwrap();
        if cancel || truncate {
            assert!(result.as_ref().is_err() || serde_json::from_str::<Value>(result.as_ref().unwrap()).unwrap()["success"] != true);
            assert!(matches!(second_lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
            assert!(!output.join("Track.mp3").exists());
        } else if return_first {
            let response: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_ne!(response["success"], true, "returned first candidate must not match observed second");
            assert!(matches!(second_lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Invalidated)));
        } else {
            let response: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(response["success"], true, "{response}");
            assert!(matches!(second_lease.read_at(8192, 1, Duration::ZERO).unwrap(), ReadAtResult::End));
            assert_eq!(std::fs::read(output.join("Track.mp3")).unwrap(), vec![0x22; 8192]);
        }
        backend.shutdown();
    }
}

#[test]
fn temporary_quality_contract_defaults_strict_and_preserves_false_metadata() {
    let strict = DownloadRequest::parse("{}").unwrap();
    assert!(!strict.allow_quality_fallback);
    let temporary = DownloadRequest::parse(r#"{"allow_quality_fallback":true}"#).unwrap();
    assert!(temporary.allow_quality_fallback);
    let result = compact(json!({"success":true,"quality_fallback_used":false}));
    assert_eq!(result["quality_fallback_used"], false);
}

#[test]
fn playback_only_provider_policy_blocks_permanent_manual_selection() {
    let directory = tempfile::tempdir().unwrap();
    let backend = Backend::new(
        &directory.path().join("sources"), &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default(),
    ).unwrap();
    for provider in ["soundcloud", "YouTube", "ytmusic-spotiflac"] {
        let response: Value = serde_json::from_str(&backend.download_by_strategy(&json!({
            "service": provider, "use_extensions": true, "use_fallback": false,
            "output_dir": directory.path().join("output")
        }).to_string(), &|| Ok(())).unwrap()).unwrap();
        assert_eq!(response["success"], false);
        assert!(text(&response, "error").contains("temporary playback"));
    }
    let temporary = DownloadRequest::parse(r#"{"temporary_playback":true}"#).unwrap();
    assert!(temporary.temporary_playback);
    assert!(!DownloadRequest::parse("{}").unwrap().temporary_playback);
    backend.shutdown();
}

#[test]
fn playback_only_provider_is_reachable_for_temporary_requests() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    let provider = sources.join("soundcloud");
    std::fs::create_dir_all(&provider).unwrap();
    std::fs::write(provider.join("manifest.json"), json!({
        "name":"soundcloud", "version":"1", "description":"Fixture",
        "type":["download_provider"], "permissions":{"storage":true,"file":true}
    }).to_string()).unwrap();
    std::fs::write(provider.join("index.js"), r#"registerExtension({
        checkAvailability(){return {available:false,reason:'No verified track match found'};},
        download(){throw new Error('unexpected download');}
    });"#).unwrap();
    let backend = Backend::new(&sources, &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap();
    backend.load_all().unwrap();
    backend.set_enabled("soundcloud", true).unwrap();
    let response: Value = serde_json::from_str(&backend.download_by_strategy(&json!({
        "service":"soundcloud", "temporary_playback":true, "use_extensions":true,
        "use_fallback":false, "output_dir":directory.path().join("output")
    }).to_string(), &|| Ok(())).unwrap()).unwrap();
    assert_eq!(response["error_type"], "not_found", "{response}");
    assert!(text(&response, "error").contains("No verified track match found"), "{response}");
    backend.shutdown();
}

const RECORDING: &str = r#"{"recordings":[{"tags":[{"name":"rock","count":1}],"releases":[{"title":"Album","artist-credit":[{"name":"Album Artist"}]}]}]}"#;
const CATALOG: &str = r#"{"id":7,"album":{"id":9},"genres":{"data":[{"name":"Jazz"}]},"label":"Label","copyright":"Copyright"}"#;

#[test]
fn contributor_annotations_allow_verified_cross_catalog_durations() {
    let request = DownloadRequest {
        track_name: "Signal (with Guest Artist)".into(),
        artist_name: "Lead Artist".into(),
        isrc: "USAAA2600001".into(),
        duration_ms: 200_000,
        ..Default::default()
    };
    let mut result = json!({"title":"Signal","artist":"Lead Artist", "isrc":"USAAA2600001", "duration_ms":220_000});
    assert!(matches_track(&request, &result, false));
    result["duration_ms"] = 30_000.into();
    assert!(!matches_track(&request, &result, false));
    result["duration_ms"] = 220_000.into();
    result["title"] = "Signal (Live)".into();
    assert!(!matches_track(&request, &result, false));
}

#[test]
fn availability_metadata_preserves_the_catalog_owner() {
    let request = DownloadRequest {
        source: "example.catalog".into(),
        spotify_id: "12345678901".into(),
        track_name: "Signal".into(),
        ..Default::default()
    };
    assert_eq!(host_track(&request)["provider_id"], "example.catalog");
}

#[test]
fn unavailable_catalog_match_reports_the_provider_reason() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    let provider = sources.join("example.audio");
    std::fs::create_dir_all(&provider).unwrap();
    std::fs::write(
        provider.join("manifest.json"),
        json!({
            "name":"example.audio", "version":"1", "description":"Generic catalog fixture",
            "type":["download_provider"], "permissions":{"storage":true,"file":true}
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        provider.join("index.js"),
        r#"registerExtension({
        checkAvailability(){return {available:false,reason:'No verified track match found'};},
        download(){throw new Error('unverified track must not download');}
    });"#,
    )
    .unwrap();
    let backend = Backend::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    backend.set_enabled("example.audio", true).unwrap();
    backend
        .set_provider_priority("download", vec!["example.audio".into()])
        .unwrap();
    let response = backend.download_by_strategy(&json!({
        "service":"example.audio", "use_extensions":true, "use_fallback":true,
        "output_dir":directory.path().join("output"), "track_name":"Signal", "quality":"best"
    }).to_string(), &|| Ok(())).unwrap();
    let result: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(result["service"], "example.audio");
    assert_eq!(result["error_type"], "not_found");
    assert!(text(&result, "error").contains("No verified track match found"));
    assert!(!text(&result, "error").contains("No extension download providers"));
    backend.shutdown();
}

#[test]
fn source_enrichment_upgrades_artwork_without_supplemental_artwork_overrides() {
    let mut request = DownloadRequest {
        cover_url: "https://example.test/selected/300.jpg".into(),
        ..Default::default()
    };
    let enriched = json!({"cover_url":"https://example.test/selected/3000.jpg"});
    apply_metadata(&mut request, &enriched, true);
    assert_eq!(request.cover_url, enriched["cover_url"]);
    apply_metadata(&mut request, &json!({"cover_url":""}), true);
    assert_eq!(request.cover_url, enriched["cover_url"]);
    apply_metadata(
        &mut request,
        &json!({"cover_url":"https://example.test/other-release/300.jpg"}),
        false,
    );
    assert_eq!(request.cover_url, enriched["cover_url"]);
    for format in ["flac", "mp3", "opus", "ogg", "m4a"] {
        let response = success(
            &request,
            &json!({"cover_url":"https://example.test/audio-provider/300.jpg"}),
            &format!("track.{format}"),
            false,
            &ExtensionManifest::default(),
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(response["cover_url"], enriched["cover_url"]);
    }
    request.cover_url.clear();
    apply_metadata(&mut request, &enriched, false);
    assert_eq!(request.cover_url, enriched["cover_url"]);
}

#[test]
fn download_preserves_source_artist_credits_in_response_and_embedded_tags() {
    let manifest = ExtensionManifest {
        name: "audio-provider".into(),
        ..Default::default()
    };
    for (source, provided, expected) in [
        (
            "Lead Artist & Guest Artist",
            "Lead Artist",
            "Lead Artist & Guest Artist",
        ),
        (
            "",
            "Lead Artist & Guest Artist",
            "Lead Artist & Guest Artist",
        ),
        (
            "   ",
            "Lead Artist & Guest Artist",
            "Lead Artist & Guest Artist",
        ),
        (
            "Lead Artist & Guest Artist",
            "",
            "Lead Artist & Guest Artist",
        ),
    ] {
        let request = DownloadRequest {
            track_name: "Track".into(),
            artist_name: source.into(),
            ..Default::default()
        };
        let result = json!({"artist": provided});
        for exists in [false, true] {
            let response = success(&request, &result, "track.flac", exists, &manifest, &|| {
                Ok(())
            })
            .unwrap();
            assert_eq!(response["artist"], expected);
            assert_eq!(
                download_metadata_fields(&request, &response)["ARTIST"],
                expected
            );
        }
    }
}

fn network() -> (Arc<NetworkService>, Arc<rustls::ServerConfig>) {
    let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        vec![certificate.cert.der().clone()],
        rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into(),
    )
    .unwrap();
    let network = NetworkService::with_options(NetworkOptions {
        extra_root_pem: certificate.cert.pem().into_bytes(),
        doh_upstreams: vec![],
        ..Default::default()
    })
    .unwrap();
    network.set_allow_private_network(true);
    (network, Arc::new(config))
}

fn server(
    requests: usize,
    body: &'static str,
    config: Arc<rustls::ServerConfig>,
) -> (
    String,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    thread::JoinHandle<Vec<String>>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("https://{}", listener.local_addr().unwrap());
    let (started, ready) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut paths = Vec::new();
        for index in 0..requests {
            let stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "missing metadata request");
                        thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("{error}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut stream = rustls::StreamOwned::new(
                rustls::ServerConnection::new(Arc::clone(&config)).unwrap(),
                stream,
            );
            let mut request = [0; 4096];
            let count = stream.read(&mut request).unwrap();
            assert!(count > 0);
            paths.push(
                std::str::from_utf8(&request[..count])
                    .unwrap()
                    .split_whitespace()
                    .nth(1)
                    .unwrap()
                    .to_owned(),
            );
            if index == 0 {
                let _ = started.send(());
                released.recv_timeout(Duration::from_secs(3)).unwrap();
            }
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
        paths
    });
    (url, ready, release, worker)
}

fn backend(
    directory: &Path,
    catalog: String,
    recording: String,
    network: Arc<NetworkService>,
) -> Arc<Backend> {
    let environment = ExtensionEnvironment::with_network(
        &directory.join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        network,
    )
    .unwrap();
    let mut options = MetadataOptions {
        deezer_endpoint: catalog,
        ..Default::default()
    };
    options.musicbrainz.endpoint = recording;
    Arc::new(
        Backend::with_environment(
            &directory.join("sources"),
            environment,
            RuntimeLimits::default(),
            options,
        )
        .unwrap(),
    )
}

#[test]
fn pending_auth_distinguishes_ready_session_challenge_and_preflight_failure() {
    let cases = [
        (
            "ready",
            r#"{"session_id":"fixture","session_secret":"fixture-secret","expires_at":"2099-01-01T00:00:00Z"}"#,
        ),
        ("challenge", r#"{"challenge_id":"fixture"}"#),
        ("invalid", r#"{"message":"missing response fields"}"#),
    ];
    for (outcome, body) in cases {
        let directory = tempfile::tempdir().unwrap();
        let (network, tls) = network();
        let (origin, _seen, release, worker) = server(1, body, tls);
        let backend = backend(directory.path(), origin.clone(), origin.clone(), network);
        assert_eq!(
            backend.get_extension_pending_auth_json("unknown").unwrap(),
            ""
        );
        let source = directory.path().join("sources").join("example.session");
        std::fs::create_dir(&source).unwrap();
        std::fs::write(
            source.join("manifest.json"),
            json!({
                "name":"example.session", "version":"1", "description":"Signed session fixture",
                "type":["download_provider"], "permissions":{"storage":true,"network":["127.0.0.1"]},
                "signedSession":{"namespace":"example-session","baseUrl":origin}
            }).to_string(),
        ).unwrap();
        std::fs::write(
            source.join("index.js"),
            "registerExtension({download(){return {success:false}}});",
        )
        .unwrap();
        backend.load_all().unwrap();
        backend.set_enabled("example.session", true).unwrap();
        release.send(()).unwrap();
        let result = backend.get_extension_pending_auth_json("example.session");
        let paths = worker.join().unwrap();
        assert!(paths[0].starts_with("/bootstrap?"));
        match outcome {
            "ready" => {
                assert_eq!(result.unwrap(), r#"{"authenticated":true}"#);
                assert_eq!(
                    backend
                        .get_extension_pending_auth_json("example.session")
                        .unwrap(),
                    r#"{"authenticated":true}"#,
                );
            }
            "challenge" => {
                let pending: Value = serde_json::from_str(&result.unwrap()).unwrap();
                assert!(text(&pending, "auth_url").starts_with(&format!("{origin}/challenge?")));
                assert!(pending.get("authenticated").is_none());
            }
            _ => assert!(
                result
                    .unwrap_err()
                    .contains("did not return a session or verification challenge")
            ),
        }
    }
}

#[test]
fn extended_metadata_overlaps_requests_preserves_fields_and_reuses_genre_fallback() {
    for catalog_body in [
        CATALOG,
        r#"{"id":7,"album":{"id":9},"label":"Label","copyright":"Copyright"}"#,
    ] {
        let (network, config) = network();
        let (catalog, catalog_ready, release_catalog, catalog_worker) =
            server(2, catalog_body, Arc::clone(&config));
        let (recording, recording_ready, release_recording, recording_worker) =
            server(1, RECORDING, config);
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path(), catalog, recording, network);
        let active = Arc::clone(&backend);
        let worker = thread::spawn(move || {
            let mut request = DownloadRequest {
                isrc: "EXAMPLE12345".into(),
                album_name: "Album".into(),
                label: "Existing label".into(),
                ..Default::default()
            };
            active
                .enrich_download_extended(&mut request, &|| Ok(()))
                .unwrap();
            request
        });
        // Neither server replies until both independent requests have started.
        catalog_ready.recv_timeout(Duration::from_secs(2)).unwrap();
        recording_ready
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        release_catalog.send(()).unwrap();
        release_recording.send(()).unwrap();
        let mut request = worker.join().unwrap();
        assert_eq!(request.album_artist, "Album Artist");
        assert_eq!(request.label, "Existing label");
        assert_eq!(request.copyright, "Copyright");
        assert_eq!(
            request.genre,
            if catalog_body == CATALOG {
                "Jazz"
            } else {
                "Rock"
            }
        );
        assert_eq!(
            catalog_worker.join().unwrap(),
            ["/2.0/track/isrc:EXAMPLE12345", "/2.0/album/9"]
        );
        recording_worker.join().unwrap();
        // Complete input must not query either server, which is now closed.
        backend
            .enrich_download_extended(&mut request, &|| Ok(()))
            .unwrap();
        assert_eq!(request.label, "Existing label");
        backend.shutdown();
    }
}

#[test]
fn extended_metadata_cancellation_joins_both_blocked_requests() {
    for shutdown in [false, true] {
        let (network, config) = network();
        let (catalog, catalog_ready, release_catalog, catalog_worker) =
            server(1, CATALOG, Arc::clone(&config));
        let (recording, recording_ready, release_recording, recording_worker) =
            server(1, RECORDING, config);
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path(), catalog, recording, network);
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&cancelled);
        let active = Arc::clone(&backend);
        let worker = thread::spawn(move || {
            let mut request = DownloadRequest {
                isrc: "EXAMPLE12345".into(),
                album_name: "Album".into(),
                ..Default::default()
            };
            active.enrich_download_extended(&mut request, &|| {
                active.check()?;
                if stop.load(Ordering::Acquire) {
                    Err("download cancelled".into())
                } else {
                    Ok(())
                }
            })
        });
        catalog_ready.recv_timeout(Duration::from_secs(2)).unwrap();
        recording_ready
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        if shutdown {
            backend.shutdown();
        } else {
            cancelled.store(true, Ordering::Release);
        }
        let started = Instant::now();
        while !worker.is_finished() {
            assert!(
                started.elapsed() < Duration::from_secs(2),
                "cancel waited for HTTP replies"
            );
            thread::sleep(Duration::from_millis(1));
        }
        let result = worker.join().unwrap();
        if shutdown {
            assert!(result.is_err(), "owner shutdown must cancel metadata");
        } else {
            assert_eq!(result, Err("download cancelled".into()));
        }
        release_catalog.send(()).unwrap();
        release_recording.send(()).unwrap();
        catalog_worker.join().unwrap();
        recording_worker.join().unwrap();
        backend.shutdown();
    }
}

struct GatedServer {
    url: String,
    started: mpsc::Receiver<(String, mpsc::Sender<()>)>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<Vec<String>>>,
}

impl GatedServer {
    fn new(config: Arc<rustls::ServerConfig>, replies: &[(&str, u16, &str)]) -> Self {
        let replies: std::collections::BTreeMap<_, _> = replies
            .iter()
            .map(|(path, status, body)| (path.to_string(), (*status, body.to_string())))
            .collect();
        let replies = Arc::new(replies);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("https://{}", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let (ready, started) = mpsc::channel();
        let worker = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(8);
            let mut workers = Vec::new();
            while !stopped.load(Ordering::Acquire) && Instant::now() < deadline {
                let stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("gated fixture accept: {error}"),
                };
                assert!(workers.len() < 8, "unexpected repeated request");
                let config = config.clone();
                let ready = ready.clone();
                let replies = replies.clone();
                workers.push(thread::spawn(move || {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    stream.set_write_timeout(Some(Duration::from_secs(2))).unwrap();
                    let mut stream = rustls::StreamOwned::new(
                        rustls::ServerConnection::new(config).unwrap(), stream,
                    );
                    let mut request = Vec::new();
                    while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                        let mut bytes = [0; 4096];
                        let count = stream.read(&mut bytes).unwrap();
                        assert!(count > 0 && request.len() + count <= 8192);
                        request.extend_from_slice(&bytes[..count]);
                    }
                    let path = std::str::from_utf8(&request).unwrap().split_whitespace().nth(1).unwrap()
                        .split('?').next().unwrap().to_owned();
                    let (release, released) = mpsc::channel();
                    ready.send((path.clone(), release)).unwrap();
                    let _ = released.recv_timeout(Duration::from_secs(3));
                    let (status, body) = replies.get(&path).expect("unexpected fixture path");
                    let _ = write!(stream, "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    path
                }));
            }
            workers
                .into_iter()
                .map(|worker| worker.join().unwrap())
                .collect()
        });
        Self {
            url,
            started,
            stop,
            worker: Some(worker),
        }
    }

    fn next(&self) -> (String, mpsc::Sender<()>) {
        self.started.recv_timeout(Duration::from_secs(2)).unwrap()
    }

    fn finish(&mut self) -> Vec<String> {
        self.stop.store(true, Ordering::Release);
        let mut paths = self.worker.take().unwrap().join().unwrap();
        paths.sort();
        paths
    }
}

impl Drop for GatedServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[test]
fn reenrich_cover_and_lyrics_overlap_preserve_best_effort_results_and_cancel() {
    for mode in [
        "success",
        "cover_failure",
        "lyrics_failure",
        "missing",
        "instrumental",
        "instrumental_native",
        "instrumental_with_lyrics",
        "word_synced_native",
        "cancel",
    ] {
        let (network, config) = network();
        let mut server = GatedServer::new(
            config,
            &[
                (
                    "/cover",
                    if matches!(
                        mode,
                        "cover_failure" | "instrumental_native" | "word_synced_native"
                    ) {
                        404
                    } else {
                        200
                    },
                    "artwork",
                ),
                (
                    "/lyrics",
                    if matches!(mode, "lyrics_failure" | "missing") {
                        404
                    } else {
                        200
                    },
                    "New lyrics",
                ),
            ],
        );
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(
            directory.path(),
            server.url.clone(),
            server.url.clone(),
            network,
        );
        let archive = directory.path().join("example.lyrics.sflx");
        let mut writer = zip::ZipWriter::new(std::fs::File::create(&archive).unwrap());
        let manifest = json!({"name":"example.lyrics","displayName":"Example Lyrics","version":"1",
            "description":"Generic lyrics fixture","type":["lyrics_provider"],"permissions":{"network":["127.0.0.1"]}});
        let source = format!(
            r#"registerExtension({{fetchLyrics(){{const response=http.get({});
            return response.statusCode===200 ? {} : {{}};}}}});"#,
            json!(format!("{}/lyrics", server.url)),
            if mode.starts_with("instrumental") {
                "{instrumental:true}"
            } else if mode == "word_synced_native" {
                r#"{syncType:"LINE_SYNCED",lines:[
                    {startTimeMs:1000,words:"<00:01.00>New <00:01.50>lyrics<00:02.00>",endTimeMs:2000},
                    {startTimeMs:3000,words:"<00:03.00>Next <00:03.50>line<00:04.00>",endTimeMs:4000}]}"#
            } else {
                "{plainLyrics:response.body}"
            },
        );
        for (name, body) in [
            ("manifest.json", manifest.to_string()),
            ("index.js", source),
        ] {
            writer
                .start_file(name, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(body.as_bytes()).unwrap();
        }
        writer.finish().unwrap();
        backend.install(&archive).unwrap();
        backend.set_enabled("example.lyrics", true).unwrap();
        backend
            .set_lyrics_providers_json(r#"["extension:example.lyrics"]"#)
            .unwrap();
        let native = matches!(mode, "instrumental_native" | "word_synced_native");
        let file_name = if native { "track.flac" } else { "track.mp3" };
        let audio = directory.path().join("data").join(file_name);
        let sidecar = directory.path().join("data/track.lrc");
        if native {
            let mut flac = b"fLaC\x80\x00\x00\x22".to_vec();
            flac.extend_from_slice(&[0; 34]);
            flac.extend_from_slice(&[0xff, 0xf8]);
            flac.extend_from_slice(&[0; 32]);
            std::fs::write(&audio, flac).unwrap();
        } else {
            std::fs::write(&audio, "original audio").unwrap();
        }
        let has_existing = !matches!(mode, "missing" | "instrumental" | "instrumental_native");
        if has_existing {
            std::fs::write(&sidecar, "[00:01.00]Old lyrics").unwrap();
            if native {
                backend
                    .embed_lyrics_to_file(file_name, "[00:01.00]Old lyrics", &|| Ok(()))
                    .unwrap();
            }
        }
        let request = json!({"file_path":file_name,"track_name":"Track","artist_name":"Artist",
            "cover_url":format!("{}/cover", server.url),"embed_lyrics":true,"lyrics_mode":"both",
            "update_fields":["cover","lyrics"]})
        .to_string();
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = cancelled.clone();
        let active = backend.clone();
        let worker = thread::spawn(move || {
            active.reenrich_file(&request, &|| {
                if stop.load(Ordering::Acquire) {
                    Err("reenrich cancelled".into())
                } else {
                    Ok(())
                }
            })
        });
        let first = server.next();
        let second = server.next();
        let mut paths = [first.0.as_str(), second.0.as_str()];
        paths.sort();
        assert_eq!(paths, ["/cover", "/lyrics"]);
        if mode == "cancel" {
            cancelled.store(true, Ordering::Release);
            let deadline = Instant::now() + Duration::from_secs(2);
            while !worker.is_finished() {
                assert!(
                    Instant::now() < deadline,
                    "reenrich cancellation waited for server replies"
                );
                thread::sleep(Duration::from_millis(1));
            }
        } else {
            first.1.send(()).unwrap();
            second.1.send(()).unwrap();
        }
        let result = worker.join().unwrap();
        if mode == "cancel" {
            assert_eq!(result, Err("reenrich cancelled".into()));
            first.1.send(()).unwrap();
            second.1.send(()).unwrap();
        } else {
            let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["method"], if native { "native" } else { "ffmpeg" });
            assert_eq!(result["write_external_lrc"], mode != "missing");
            let lyrics = result["lyrics"].as_str().unwrap();
            let (status, expected) = match mode {
                "lyrics_failure" | "instrumental_with_lyrics" => ("preserved", "Old lyrics"),
                "missing" => ("not_found", ""),
                "instrumental" | "instrumental_native" => ("instrumental", "[instrumental:true]"),
                "word_synced_native" => ("updated", "<00:01.00>New <00:01.50>lyrics<00:02.00>"),
                _ => ("updated", "New lyrics"),
            };
            assert_eq!(result["lyrics_status"], status);
            if mode == "missing" {
                assert!(lyrics.is_empty());
                assert!(result["metadata"].get("LYRICS").is_none());
            } else {
                assert!(lyrics.contains(expected));
                if !native {
                    assert_eq!(result["metadata"]["LYRICS"], lyrics);
                }
            }
            if !native {
                let cover = result["cover_path"].as_str().unwrap();
                if mode == "cover_failure" {
                    assert!(cover.is_empty());
                } else {
                    assert_eq!(std::fs::read(cover).unwrap(), b"artwork");
                    std::fs::remove_file(cover).unwrap();
                }
            } else {
                let embedded = backend
                    .get_lyrics_lrc(
                        &LyricsRequest {
                            file_path: file_name.into(),
                            ..Default::default()
                        },
                        &|| Ok(()),
                    )
                    .unwrap();
                assert_eq!(embedded, lyrics);
            }
        }
        if !native {
            assert_eq!(std::fs::read(&audio).unwrap(), b"original audio");
        }
        if has_existing {
            assert_eq!(std::fs::read(&sidecar).unwrap(), b"[00:01.00]Old lyrics");
        } else {
            assert!(!sidecar.exists());
        }
        assert!(
            std::fs::read_dir(directory.path().join("data"))
                .unwrap()
                .all(|entry| !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("reenrich_cover_"))
        );
        assert_eq!(server.finish(), ["/cover", "/lyrics"]);
        backend.shutdown();
    }
}

fn provider_diagnostic_fixture(providers: &[(&str, &str)], fallback: bool) -> Value {
    let directory = tempfile::tempdir().unwrap();
    provider_diagnostic_fixture_at(directory.path(), providers, fallback)
}

#[test]
fn disabling_selected_personal_provider_during_enrichment_does_not_enable_fallback() {
    selected_personal_provider_during_enrichment(false);
}

#[test]
fn cancellation_wins_when_selected_personal_provider_is_disabled_during_enrichment() {
    selected_personal_provider_during_enrichment(true);
}

fn selected_personal_provider_during_enrichment(cancel: bool) {
    let directory = tempfile::tempdir().unwrap();
    let (network, config) = network();
    let (url, started, release, server) = server(1, "{}", config);
    let backend = backend(directory.path(), url.clone(), url.clone(), network);
    for (name, kind, capability, script) in [
        (
            "example.account",
            "download_provider",
            json!({"accountDownloadMode":{"setting":"accountMode","value":"personal"}}),
            "checkAvailability(){return {available:false};}".to_owned(),
        ),
        (
            "example.fallback",
            "download_provider",
            json!({}),
            "checkAvailability(){storage.set('attempted',true);return {available:false};},attempted(){return storage.get('attempted')||false;}".to_owned(),
        ),
        (
            "example.metadata",
            "metadata_provider",
            json!({}),
            format!("enrichTrack(track){{http.get({});return track;}}", json!(url)),
        ),
    ] {
        let provider = directory.path().join("sources").join(name);
        std::fs::create_dir_all(&provider).unwrap();
        std::fs::write(
            provider.join("manifest.json"),
            json!({"name":name,"version":"1","description":"Account race fixture",
                "type":[kind],"capabilities":capability,
                "permissions":{"storage":true,"network":["127.0.0.1"]}})
                .to_string(),
        )
        .unwrap();
        std::fs::write(provider.join("index.js"), format!("registerExtension({{{script}}});"))
            .unwrap();
    }
    backend.load_all().unwrap();
    for id in ["example.account", "example.fallback", "example.metadata"] {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .set_provider_priority(
            "download",
            vec!["example.account".into(), "example.fallback".into()],
        )
        .unwrap();
    backend
        .update_settings(
            "example.account",
            serde_json::from_value(json!({"accountMode":"personal"})).unwrap(),
        )
        .unwrap();
    let worker = {
        let backend = backend.clone();
        let request = json!({"service":"example.account", "source":"example.metadata", "item_id":"account-race",
            "use_extensions":true, "use_fallback":true, "output_dir":directory.path().join("output"),
            "track_name":"Signal", "artist_name":"Fixture Artist", "album_name":"Fixture Album",
            "release_date":"2026-01-01", "isrc":"USAAA2600001", "quality":"cd"});
        thread::spawn(move || {
            backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap()
        })
    };
    started.recv_timeout(Duration::from_secs(2)).unwrap();
    backend.set_enabled("example.account", false).unwrap();
    if cancel {
        backend
            .environment()
            .download_state()
            .cancel("account-race")
            .unwrap();
    }
    release.send(()).unwrap();
    let response = worker.join().unwrap();
    assert_eq!(server.join().unwrap(), ["/"]);
    let result: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(
        result["error_type"],
        if cancel {
            "cancelled"
        } else {
            "provider_unavailable"
        },
        "{response}"
    );
    assert_eq!(
        backend
            .call("example.fallback", "attempted", "[]", None, 1000)
            .unwrap(),
        "false"
    );
}

fn provider_diagnostic_fixture_at(
    directory: &Path,
    providers: &[(&str, &str)],
    fallback: bool,
) -> Value {
    let sources = directory.join("sources");
    for (name, script) in providers {
        let provider = sources.join(name);
        std::fs::create_dir_all(&provider).unwrap();
        std::fs::write(
            provider.join("manifest.json"),
            json!({
                "name":name, "version":"1", "description":"Diagnostic fixture",
                "qualityOptions":[{"id":"cd","label":"FLAC 16-bit 44.1 kHz","kind":"lossless"}],
                "type":["download_provider"], "permissions":{"storage":true,"file":true}
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            provider.join("index.js"),
            format!("registerExtension({{{script}}});"),
        )
        .unwrap();
    }
    let backend = Backend::new(
        &sources,
        &directory.join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    for (name, _) in providers {
        backend.set_enabled(name, true).unwrap();
    }
    backend
        .set_provider_priority(
            "download",
            providers.iter().map(|(name, _)| (*name).into()).collect(),
        )
        .unwrap();
    let output = directory.join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    let raw = backend
        .download_by_strategy(
            &json!({
                "service":providers.first().map_or("", |(name, _)| *name),
                "use_extensions":true, "use_fallback":fallback,
                "output_dir":output, "track_name":"Signal", "artist_name":"Fixture Artist",
                "album_name":"Fixture Album", "release_date":"2026-01-01",
                "isrc":"USAAA2600001", "quality":"cd"
            })
            .to_string(),
            &|| Ok(()),
        )
        .unwrap();
    backend.shutdown();
    serde_json::from_str(&raw).unwrap()
}

const DIAGNOSTIC_ABSENT: &str = "checkAvailability(){return {available:false};}, download(){throw new Error('must not download');}";

#[test]
fn availability_trace_reports_operation_and_response_without_provider_text() {
    assert_eq!(availability_error_stage("checkAvailability timeout: sentinel-secret"), "availability_operation_timeout");
    assert_eq!(availability_error_stage("failure https://private.invalid/timeout"), "availability_operation_error");
    for (script, expected) in [
        (r#"checkAvailability(){throw new Error('sentinel-secret https://private.invalid/token');}"#, "availability_operation_error"),
        (r#"checkAvailability(){return {available:false,reason:'sentinel-secret https://private.invalid/token'};}"#, "availability_response_unavailable"),
    ] {
        let result = provider_diagnostic_fixture(&[("example.first", script)], true);
        let attempts = result["provider_attempts"].as_array().unwrap();
        assert!(attempts.iter().any(|v| v["stage"] == expected), "{result}");
        assert!(!result.to_string().contains("sentinel-secret"));
        assert!(!result.to_string().contains("private.invalid"));
    }
}

#[test]
fn availability_reason_class_maps_to_closed_labels() {
    for (reason, expected) in [
        ("", "empty"),
        ("   ", "empty"),
        ("No matching track", "no_match"),
        ("no verified candidate", "no_match"),
        ("Track not found", "no_match"),
        ("search failed: upstream", "lookup_failed"),
        ("request returned HTTP 429", "lookup_failed"),
        ("network unreachable", "lookup_failed"),
        ("download cancelled", "cancelled"),
        ("no track identity", "identity_missing"),
        ("no search query", "identity_missing"),
        ("direct stream is not playable", "direct_unplayable"),
        ("something else entirely", "other"),
    ] {
        assert_eq!(availability_reason_class(reason), expected, "{reason}");
    }
}

#[test]
fn download_trace_details_are_closed_and_bounded() {
    let details = download_trace_details("request", 9, &json!({"retry_after_seconds": 30}));
    assert_eq!(details, vec![("id_source", json!("request")), ("id_len", json!(9)), ("retry_after_s", json!(30))]);
    let details = download_trace_details("empty", 0, &json!({"retry_after_seconds": 0}));
    assert_eq!(details, vec![("id_source", json!("empty")), ("id_len", json!(0))]);
    let details = download_trace_details("availability", 4000, &json!({"retry_after_seconds": 9999999}));
    assert_eq!(details, vec![("id_source", json!("availability")), ("id_len", json!(255)), ("retry_after_s", json!(86400))]);
    let mut trace = Vec::new();
    trace_attempt_details(&mut trace, "example.first", "download", "rate_limit", &details);
    assert_eq!(trace[0]["id_source"], "availability");
    assert_eq!(trace[0]["retry_after_s"], 86400);
}

#[test]
fn download_trace_details_carry_only_a_valid_http_status() {
    let details = download_trace_details("request", 9, &json!({"http_status": 503, "retry_after_seconds": 7}));
    assert_eq!(details, vec![("id_source", json!("request")), ("id_len", json!(9)), ("retry_after_s", json!(7)), ("http_status", json!(503))]);
    let details = download_trace_details("request", 9, &json!({"http_status": 429, "retry_after_seconds": 0}));
    assert_eq!(details, vec![("id_source", json!("request")), ("id_len", json!(9)), ("http_status", json!(429))]);
    for invalid in [json!(99), json!(600), json!(0), json!(-429), json!("429"), json!(null), json!(429.5)] {
        let details = download_trace_details("request", 9, &json!({"http_status": invalid}));
        assert!(details.iter().all(|(key, _)| *key != "http_status"), "{invalid}");
    }
    let mut trace = Vec::new();
    let details = download_trace_details("request", 9, &json!({"http_status": 429, "error": "https://private.invalid/sentinel-secret"}));
    trace_attempt_details(&mut trace, "example.first", "download", "rate_limit", &details);
    assert_eq!(trace[0]["http_status"], 429);
    assert!(!trace[0].to_string().contains("sentinel-secret"));
}

#[test]
fn download_trace_http_status_survives_extension_failure() {
    let result = provider_diagnostic_fixture(
        &[("example.first", r#"checkAvailability(){return {available:true,track_id:'1234567'};},
            download(){return {success:false,error_type:'rate_limited',error_message:'private detail',http_status:429};}"#)],
        true,
    );
    let attempts = result["provider_attempts"].as_array().unwrap();
    assert!(attempts.iter().any(|v| v["stage"] == "download" && v["http_status"] == 429), "{result}");
    assert!(attempts.iter().all(|v| v.get("retry_after_s").is_none()), "{result}");
    assert!(!result.to_string().contains("private detail"));
}

#[test]
fn availability_trace_carries_reason_class_without_provider_text() {
    let result = provider_diagnostic_fixture(
        &[("example.first", r#"checkAvailability(){return {available:false,reason:'search failed https://private.invalid/sentinel-secret'};}"#)],
        true,
    );
    let attempts = result["provider_attempts"].as_array().unwrap();
    assert!(attempts.iter().any(|v| v["stage"] == "availability_response_unavailable" && v["reason_class"] == "lookup_failed"), "{result}");
    assert!(!result.to_string().contains("sentinel-secret"));
    assert!(!result.to_string().contains("private.invalid"));
}

#[test]
fn download_trace_carries_id_source_and_length() {
    let result = provider_diagnostic_fixture(
        &[("example.first", r#"checkAvailability(){return {available:true,track_id:'1234567'};},
            download(){return {success:false,error_type:'network',error_message:'connection failed'};}"#)],
        true,
    );
    let attempts = result["provider_attempts"].as_array().unwrap();
    assert!(attempts.iter().any(|v| v["stage"] == "download" && v["id_source"] == "availability" && v["id_len"] == 7), "{result}");
    assert!(!result.to_string().contains("1234567"));
}

#[test]
fn quality_failure_continues_to_next_provider_and_traces_safely() {
    let result = provider_diagnostic_fixture(
        &[
            ("example.first", r#"checkAvailability(){return {available:true,track_id:'7'};},
                download(){return {success:false,error_type:'quality_unavailable',error_message:'https://private.example/?token=fixture-secret'};}"#),
            ("example.second", r#"checkAvailability(){return {available:true,track_id:'8'};},
                download(){return {success:false,error_type:'network',error_message:'connection failed'};}"#),
        ], true,
    );
    let attempts = result["provider_attempts"].as_array().unwrap();
    assert!(attempts.iter().any(|v| v["provider"] == "example.first" && v["stage"] == "download" && v["error_type"] == "quality_unavailable"));
    assert!(attempts.iter().any(|v| v["provider"] == "example.second" && v["stage"] == "download" && v["error_type"] == "network"));
    assert!(!result.to_string().contains("fixture-secret"));
    assert!(!result.to_string().contains("private.example"));
    assert_eq!(trace_provider("https://host/?token=secret"), "invalid-provider-id");
}

#[test]
fn provider_diagnostic_strict_unknown_remains_provider_failure() {
    let result = provider_diagnostic_fixture(
        &[(
            "example.first",
            r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'unknown',error_message:'request failed https://private.example/audio?token=fixture-secret'};}"#,
        )],
        false,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "unknown");
    assert!(!result.to_string().contains("private.example"));
    assert!(!result.to_string().contains("fixture-secret"));
}

#[test]
fn provider_diagnostic_rate_limit_survives_later_absence() {
    let result = provider_diagnostic_fixture(
        &[
            (
                "example.first",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'rate_limited',error_message:'HTTP 429',retry_after_seconds:19};}"#,
            ),
            ("example.second", DIAGNOSTIC_ABSENT),
        ],
        true,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "rate_limit");
    assert_eq!(result["retry_after_seconds"], 19);
}

#[test]
fn provider_diagnostic_all_absent_reports_not_found() {
    let result = provider_diagnostic_fixture(
        &[
            ("example.first", DIAGNOSTIC_ABSENT),
            ("example.second", DIAGNOSTIC_ABSENT),
            ("example.third", DIAGNOSTIC_ABSENT),
        ],
        true,
    );
    assert_eq!(result["error_type"], "not_found");
}

#[test]
fn provider_diagnostic_no_eligible_provider_reports_unavailable() {
    let result = provider_diagnostic_fixture(&[], true);
    assert_eq!(result["success"], false);
    assert_eq!(result["error_type"], "provider_unavailable");
    assert_eq!(result["error"], "No extension download providers available");
}

#[test]
fn provider_diagnostic_typed_availability_failure_survives_later_absence() {
    for (script, kind, retry) in [
        (
            "checkAvailability(){return {available:false,error_type:'auth',reason:'not_found'};}",
            "auth",
            0,
        ),
        (
            "checkAvailability(){return {available:false,errorType:'network',reason:'https://private.example/?token=fixture-secret'};}",
            "network",
            0,
        ),
        (
            "checkAvailability(){return {available:false,errorType:'rate_limit',retryAfterSeconds:19};}",
            "rate_limit",
            19,
        ),
        (
            "checkAvailability(){return {available:false,error_type:'verification_required'};}",
            "verification_required",
            0,
        ),
    ] {
        let result = provider_diagnostic_fixture(
            &[
                ("example.first", script),
                ("example.second", DIAGNOSTIC_ABSENT),
                ("example.third", DIAGNOSTIC_ABSENT),
            ],
            true,
        );
        assert_eq!(result["service"], "example.first", "{result}");
        assert_eq!(result["error_type"], kind);
        assert_eq!(
            result["retry_after_seconds"].as_i64().unwrap_or_default(),
            retry
        );
        assert!(!result.to_string().contains("fixture-secret"));
    }
}

#[test]
fn provider_diagnostic_verification_survives_later_failure() {
    let result = provider_diagnostic_fixture(
        &[
            (
                "example.first",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'verification_required',error_message:'Verification required'};}"#,
            ),
            (
                "example.second",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'network',error_message:'Connection timeout'};}"#,
            ),
        ],
        true,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "verification_required");
}

#[test]
fn provider_diagnostic_storage_failure_stops_fallback() {
    let result = provider_diagnostic_fixture(
        &[
            (
                "example.first",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'permission',error_message:'Permission denied'};}"#,
            ),
            (
                "example.second",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'verification_required',error_message:'Verification required'};}"#,
            ),
        ],
        true,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "permission");
}

#[test]
fn provider_diagnostic_skip_fallback_stops_before_next_provider() {
    let result = provider_diagnostic_fixture(
        &[
            (
                "example.first",
                r#"checkAvailability(){return {available:false,skip_fallback:true};},
            download(){throw new Error('must not download');}"#,
            ),
            (
                "example.second",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'verification_required',error_message:'Verification required'};}"#,
            ),
        ],
        true,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "extension_error");
}

#[test]
fn provider_diagnostic_fallback_publishes_a_real_download() {
    let script = format!(
        "checkAvailability(isrc,title,artist){{\
        if(isrc!=='USAAA2600001'||title!=='Signal'||artist!=='Fixture Artist')\
        throw new Error('wrong track requested');\
        return {{available:true,track_id:'7'}};}},\
        download(trackId,quality,outputPath){{file.writeBytes(outputPath,{});\
        return {{success:true,file_path:outputPath,title:'Signal',artist:'Fixture Artist',isrc:'USAAA2600001'}};}}",
        json!(super::container_tests::REAL_FLAC_BASE64),
    );
    let providers = [
        ("example.first", DIAGNOSTIC_ABSENT),
        ("example.second", script.as_str()),
        ("example.third", script.as_str()),
    ];
    let strict = provider_diagnostic_fixture(&providers, false);
    assert_eq!(strict["success"], false, "{strict}");
    assert_eq!(strict["service"], "example.first");
    assert_eq!(strict["error_type"], "not_found");

    let directory = tempfile::tempdir().unwrap();
    let result = provider_diagnostic_fixture_at(directory.path(), &providers, true);
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["service"], "example.second");
    assert_eq!(result["actual_extension"], ".flac");
    use base64::Engine as _;
    let expected = base64::engine::general_purpose::STANDARD
        .decode(super::container_tests::REAL_FLAC_BASE64)
        .unwrap();
    assert_eq!(std::fs::read(text(&result, "file_path")).unwrap(), expected);
}

#[test]
fn provider_diagnostic_fallback_rejects_a_different_recording() {
    let audio = json!(super::container_tests::REAL_FLAC_BASE64);
    let wrong = format!(
        "checkAvailability(){{return {{available:true,track_id:'wrong'}};}},\
        download(trackId,quality,outputPath){{file.writeBytes(outputPath,{audio});\
        return {{success:true,file_path:outputPath,title:'Other Song',artist:'Other Artist',isrc:'USBBB2600002'}};}}",
    );
    let right = format!(
        "checkAvailability(){{return {{available:true,track_id:'right'}};}},\
        download(trackId,quality,outputPath){{file.writeBytes(outputPath,{audio});\
        return {{success:true,file_path:outputPath,title:'Signal',artist:'Fixture Artist',isrc:'USAAA2600001'}};}}",
    );
    let directory = tempfile::tempdir().unwrap();
    let result = provider_diagnostic_fixture_at(
        directory.path(),
        &[
            ("example.first", DIAGNOSTIC_ABSENT),
            ("example.second", &wrong),
            ("example.third", &right),
        ],
        true,
    );
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["service"], "example.third");
    assert_eq!(result["provider_track_id"], "right");
}

#[test]
fn provider_diagnostic_hides_raw_response_and_credential_details() {
    for message in [
        "request failed, Authorization: Bearer fixture-secret",
        "request failed, token=fixture-secret",
        "request failed, token=verification_required",
        "request failed https://private.example/verification_required",
        "request failed //private.example/verification_required",
        "request failed\nbody: verification_required",
        "request failed\nHTTP response: verification_required",
        "request failed: payload=verification_required",
        "request failed: response body=fixture-secret",
        r#"request failed: ["fixture-secret"]"#,
        r#"request failed: {"opaque":"fixture-secret"}"#,
    ] {
        let script = format!(
            "checkAvailability(){{return {{available:true,track_id:'7'}};}},\
            download(){{return {{success:false,error_type:'unknown',error_message:{}}};}}",
            json!(message)
        );
        let result = provider_diagnostic_fixture(&[("example.first", &script)], false);
        assert_eq!(result["error_type"], "unknown");
        assert!(!result.to_string().contains("fixture-secret"));
    }
}

#[test]
fn provider_diagnostic_rejects_unrecognized_error_codes() {
    let result = provider_diagnostic_fixture(
        &[(
            "example.first",
            r#"checkAvailability(){return {available:true,track_id:'7'};},
            download(){return {success:false,error_type:'fixture_secret',error_message:'request failed'};}"#,
        )],
        false,
    );
    assert_eq!(result["error_type"], "unknown");
    assert!(!result.to_string().contains("fixture_secret"));
}

#[test]
fn provider_diagnostic_unknown_availability_reason_is_not_catalog_absence() {
    for reason in [
        "HTTP 503",
        "Login expired",
        "Search failed: resource not found",
        "not implemented",
    ] {
        let script = format!(
            "checkAvailability(){{return {{available:false,reason:{}}};}}",
            json!(reason)
        );
        let result = provider_diagnostic_fixture(
            &[
                ("example.first", &script),
                ("example.second", DIAGNOSTIC_ABSENT),
            ],
            true,
        );
        assert_eq!(result["service"], "example.first", "{reason}");
        assert_eq!(result["error_type"], "unknown", "{reason}");
    }
}

#[test]
fn provider_diagnostic_recognizes_soundcloud_catalog_absence() {
    let result = provider_diagnostic_fixture(
        &[(
            "example.first",
            r#"checkAvailability(){return {available:false,reason:'No confident playable match found on SoundCloud'};}"#,
        )],
        false,
    );
    assert_eq!(result["error_type"], "not_found");
    assert!(text(&result, "error").contains("No confident playable match found"));
}

#[test]
fn provider_diagnostic_keeps_last_error_at_equal_priority() {
    let result = provider_diagnostic_fixture(
        &[
            (
                "example.first",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
                download(){return {success:false,error_type:'network',error_message:'Connection timeout'};}"#,
            ),
            (
                "example.second",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
                download(){return {success:false,error_type:'rate_limit',error_message:'HTTP 429'};}"#,
            ),
        ],
        true,
    );
    assert_eq!(result["service"], "example.second");
    assert_eq!(result["error_type"], "rate_limit");
}

#[test]
fn provider_diagnostic_stop_preserves_attempt_type_and_retry() {
    for (reported, expected) in [
        ("provider_reauth_required", "provider_reauth_required"),
        ("auth", "auth"),
        ("provider_unavailable", "provider_unavailable"),
        ("isp_blocked", "isp_blocked"),
        ("rate_limited", "rate_limit"),
    ] {
        let script = format!(
            "checkAvailability(){{return {{available:true,track_id:'7',skip_fallback:true,reason:'token=fixture-secret'}};}},\
            download(){{return {{success:false,error_type:{},error_message:'request failed',retry_after_seconds:19}};}}",
            json!(reported)
        );
        let result = provider_diagnostic_fixture(
            &[
                ("example.first", &script),
                ("example.second", DIAGNOSTIC_ABSENT),
            ],
            true,
        );
        assert_eq!(result["service"], "example.first");
        assert_eq!(result["error_type"], expected);
        assert_eq!(result["retry_after_seconds"], 19);
        assert!(text(&result, "error").starts_with("Fallback stopped"));
        assert!(!result.to_string().contains("fixture-secret"));
    }
}

#[test]
fn provider_diagnostic_storage_signal_after_first_line_stops_fallback() {
    let message = format!("{}\nPermission denied", "write attempt ".repeat(32));
    let script = format!(
        "checkAvailability(){{return {{available:true,track_id:'7'}};}},\
        download(){{return {{success:false,error_type:'file_error',error_message:{}}};}}",
        json!(message)
    );
    let result = provider_diagnostic_fixture(
        &[
            ("example.first", &script),
            (
                "example.second",
                r#"checkAvailability(){return {available:true,track_id:'7'};},
                download(){return {success:false,error_type:'verification_required',error_message:'Verification required'};}"#,
            ),
        ],
        true,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "permission");
}

#[test]
fn provider_diagnostic_infers_multiline_verification_after_sanitizing() {
    let result = provider_diagnostic_fixture(
        &[(
            "example.first",
            r#"checkAvailability(){return {available:true,track_id:'7'};},
                download(){return {success:false,error_type:'api_error',
                    error_message:'Session check failed\nsigned session expired\nraw response=fixture-secret'};}"#,
        )],
        false,
    );
    assert_eq!(result["service"], "example.first");
    assert_eq!(result["error_type"], "verification_required");
    assert!(!result.to_string().contains("fixture-secret"));
}

#[test]
fn saved_source_quality_requires_provenance_and_preserves_live_manifest() {
    let request = DownloadRequest::parse(r#"{"service":"source","quality":"opaque","quality_source_provider":"source","quality_source_id":"opaque","quality_source_kind":"lossy","quality_source_label":"Opus 320 kbps","label":"album label"}"#).unwrap();
    let source = source_with_request_quality(&request, None).unwrap();
    let target = ExtensionManifest { name: "target".into(), quality_options: vec![crate::manifest::QualityOption { id: "other".into(), label: "Opus 320 kbps".into(), kind: "lossy".into(), ..Default::default() }], ..Default::default() };
    assert_eq!(target.resolve_strict_download_quality("opaque", Some(&source)).unwrap(), "other");
    assert_eq!(request.label, "album label");
    let changed = ExtensionManifest { name: "source".into(), quality_options: vec![crate::manifest::QualityOption { id: "new".into(), ..Default::default() }], ..Default::default() };
    let source = source_with_request_quality(&request, Some(changed)).unwrap();
    assert_eq!(target.resolve_strict_download_quality("opaque", Some(&source)).unwrap(), "other");
    let mut mismatch = request.clone(); mismatch.quality = "override".into();
    assert!(source_with_request_quality(&mismatch, None).is_none());
    mismatch = request.clone(); mismatch.quality_source_provider = "stranger".into();
    assert!(source_with_request_quality(&mismatch, None).is_none());
    mismatch = request.clone(); mismatch.service = "other".into(); mismatch.source = "source".into();
    assert!(source_with_request_quality(&mismatch, None).is_none());
    let live = ExtensionManifest { name: "source".into(), quality_options: vec![crate::manifest::QualityOption { id: "opaque".into(), label: "AAC 128 kbps".into(), kind: "lossy".into(), ..Default::default() }], ..Default::default() };
    let source = source_with_request_quality(&request, Some(live)).unwrap();
    assert_eq!(source.find_quality("opaque").unwrap().label, "AAC 128 kbps");
    assert!(target.resolve_strict_download_quality("opaque", Some(&source)).is_err());
}

#[test]
fn legacy_and_new_quality_request_json_parse() {
    let old = DownloadRequest::parse(r#"{"quality":"best","label":"record label"}"#).unwrap();
    assert!(old.quality_source_provider.is_empty());
    assert_eq!(old.label, "record label");
    let new = DownloadRequest::parse(r#"{"quality":"best","quality_source_provider":"source","quality_source_id":"best","quality_source_kind":"lossless","quality_source_label":"FLAC"}"#).unwrap();
    assert_eq!((&*new.quality_source_provider, &*new.quality_source_id, &*new.quality_source_kind, &*new.quality_source_label), ("source", "best", "lossless", "FLAC"));
}

#[cfg(feature = "experimental-progressive-reader")]
mod generic_audio {
    use super::*;
    use crate::download::progressive_candidate::{NextCandidate, ProgressiveOperation};
    use crate::download::progressive_reader::{LeaseState, ReadAtError, ReadAtResult};
    use sha2::{Digest, Sha256};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::time::Duration;

    fn atom(name: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut result = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        result.extend_from_slice(name); result.extend_from_slice(payload); result
    }

    fn pseudo(seed: u8, len: usize) -> Vec<u8> { (0..len).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)).collect() }

    fn with_head(head: &[u8], total: usize) -> Vec<u8> { let mut body = head.to_vec(); body.extend(pseudo(head[0], total - head.len())); body }

    /// ftyp (24 bytes) followed by an AAC moov.
    fn aac_init(ftyp: &[u8]) -> Vec<u8> {
        let mut entry = vec![0; 28]; entry.extend(atom(b"esds", &[0; 4]));
        let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
        let moov = atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &atom(b"stbl", &atom(b"stsd", &stsd))))));
        let mut body = atom(b"ftyp", ftyp); body.extend(moov); body
    }

    const M4A: &[u8] = b"M4A \0\0\0\0M4A isom";

    /// Serves `body` over loopback (half first, the rest after the lease was read)
    /// and drives the generic audio operation through the real host download.
    fn case(body: Vec<u8>, ext: &'static str, announce_length: bool, accepted: bool, label: &str) {
        case_with(body, ext, announce_length, accepted, label, "", None, 0);
    }

    /// `extra` is appended to the `file.download` options; `clear` is what the lease
    /// must serve instead of the transferred bytes (on-the-fly decryption).
    fn case_with(body: Vec<u8>, ext: &'static str, announce_length: bool, accepted: bool, label: &str, extra: &str, clear: Option<Vec<u8>>, exposed_limit: usize) {
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let expected = body.clone();
        let served = clear.unwrap_or_else(|| body.clone());
        let first = body.len() / 2;
        let (ready_tx, ready_rx) = mpsc::channel(); let (resume_tx, resume_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut request = [0; 4096]; let n = socket.read(&mut request).unwrap();
            assert!(!String::from_utf8_lossy(&request[..n]).to_ascii_lowercase().contains("\r\nrange:"));
            let length = if announce_length { format!("Content-Length: {}\r\n", body.len()) } else { String::new() };
            write!(socket, "HTTP/1.1 200 OK\r\n{length}Connection: close\r\n\r\n").unwrap();
            socket.write_all(&body[..first]).unwrap(); socket.flush().unwrap(); ready_tx.send(()).unwrap();
            resume_rx.recv_timeout(Duration::from_secs(10)).unwrap(); let _ = socket.write_all(&body[first..]);
        });
        let source = root.path().join("sources/example.audio"); std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("manifest.json"), json!({"name":"example.audio","version":"1","description":"local test","type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"aac_128","kind":"lossy"}]}).to_string()).unwrap();
        std::fs::write(source.join("index.js"), format!(r#"registerExtension({{download(id,quality,path){{let d=file.download({url:?},path,{{maxAttempts:1,resume:false,chunked:true{extra}}});if(!d.success)return d;return {{success:true,file_path:d.path,actual_extension:{ext:?}}};}}}});"#)).unwrap();
        let backend = Arc::new(Backend::new(&root.path().join("sources"), &root.path().join("data"), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap());
        backend.environment().set_allow_private_network(true).unwrap(); backend.load_all().unwrap(); backend.set_enabled("example.audio", true).unwrap();
        let output = root.path().join("output"); std::fs::create_dir_all(&output).unwrap();
        backend.environment().set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
        let request = json!({"service":"example.audio","source":"example.audio","provider_track_id":"track","temporary_playback":true,"use_extensions":true,"use_fallback":false,"output_dir":output,"track_name":"Track","artist_name":"Artist","album_name":"Album","filename_format":"{title}","output_ext":ext,"quality":"aac_128","allow_quality_fallback":true,"embed_metadata":false,"embed_lyrics":false}).to_string();
        let operation = Arc::new(ProgressiveOperation::generic_audio());
        let worker_backend = backend.clone(); let worker_operation = operation.clone();
        let worker = thread::spawn(move || worker_backend.download_by_strategy_progressive(&request, &|| Ok(()), worker_operation));
        ready_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let lease = match operation.next_lease(0, Duration::from_secs(1)).unwrap() { NextCandidate::Available { lease, .. } => lease, _ => panic!("{label}: candidate unavailable") };
        let total = expected.len() as u64;
        if accepted {
            match lease.read_at(0, 4096, Duration::from_secs(1)).unwrap() {
                ReadAtResult::Bytes(bytes) => { assert!(!bytes.is_empty(), "{label}"); assert_eq!(bytes[..], served[..bytes.len()], "{label}"); }
                _ => panic!("{label}: no bytes while the file is still arriving"),
            }
            // Everything offered while the transfer is incomplete must be the served bytes.
            let mut offset = 0u64;
            while let ReadAtResult::Bytes(bytes) = lease.read_at(offset, 4096, Duration::ZERO).unwrap() {
                assert_eq!(bytes[..], served[offset as usize..offset as usize + bytes.len()], "{label}");
                offset += bytes.len() as u64;
            }
            assert!(offset > 0 && offset <= first as u64, "{label}: {offset} bytes while {first} were sent");
            assert_eq!(lease.size().unwrap(), announce_length.then_some(total), "{label}: size before commit");
            assert!(matches!(lease.read_at(total, 1, Duration::ZERO).unwrap(), ReadAtResult::Pending), "{label}");
            assert_eq!(lease.wait_terminal(Duration::ZERO).unwrap(), LeaseState::Pending, "{label}");
        } else {
            // Refusal may follow some already-approved bytes (never more than `exposed_limit`);
            // everything offered before it must be the served bytes.
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let mut offset = 0usize;
            loop {
                match lease.read_at(offset as u64, 4096, Duration::from_millis(50)) {
                    Err(ReadAtError::Aborted) => break,
                    Ok(ReadAtResult::Bytes(bytes)) => {
                        assert_eq!(bytes[..], served[offset..offset + bytes.len()], "{label}");
                        offset += bytes.len();
                        assert!(offset <= exposed_limit, "{label}: exposed {offset} bytes, limit {exposed_limit}");
                    }
                    Ok(ReadAtResult::Pending) => {}
                    _ => panic!("{label}: unexpected read outcome"),
                }
                assert!(std::time::Instant::now() < deadline, "{label}: never aborted");
            }
            assert_eq!(lease.wait_terminal(Duration::ZERO).unwrap(), LeaseState::Aborted, "{label}");
        }
        resume_tx.send(()).unwrap();
        let result = worker.join().unwrap(); server.join().unwrap();
        if accepted {
            let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["success"], true, "{label}: {result}");
            assert!(matches!(lease.read_at(total, 1, Duration::ZERO).unwrap(), ReadAtResult::End), "{label}");
            assert_eq!(lease.size().unwrap(), Some(total), "{label}: size after commit");
            assert_eq!(lease.wait_terminal(Duration::ZERO).unwrap(), LeaseState::Committed, "{label}");
            let saved = std::fs::read(output.join(format!("Track{ext}"))).unwrap();
            assert_eq!(Sha256::digest(&saved), Sha256::digest(&expected), "{label}");
        } else {
            let rejected = match result { Err(_) => true, Ok(raw) => serde_json::from_str::<Value>(&raw).unwrap()["success"] != true };
            assert!(rejected, "{label}");
            assert!(!output.join(format!("Track{ext}")).exists(), "{label}: rejected media must not be published");
        }
        backend.shutdown();
    }

    #[test]
    fn generic_audio_streams_mp3_flac_ogg_wav_and_adts_while_the_file_arrives() {
        let fixtures: [(&str, &'static str, Vec<u8>); 6] = [
            ("mp3 frames", ".mp3", with_head(&[0xff, 0xfb, 0x90, 0x64], 24_000)),
            ("mp3 id3", ".mp3", with_head(b"ID3\x04\0\0\0\0\0\x10", 24_000)),
            ("flac", ".flac", with_head(b"fLaC", 24_000)),
            ("ogg", ".ogg", with_head(b"OggS\0\x02", 24_000)),
            ("wav", ".wav", with_head(b"RIFF\x24\x5d\0\0WAVEfmt ", 24_000)),
            ("adts", ".aac", with_head(&[0xff, 0xf1, 0x50, 0x80], 24_000)),
        ];
        for (label, ext, body) in fixtures { case(body, ext, true, true, label); }
    }

    #[test]
    fn generic_audio_reports_unknown_size_when_the_server_gives_no_length() {
        case(with_head(&[0xff, 0xfb, 0x90, 0x64], 24_000), ".mp3", false, true, "mp3 without content-length");
        case(with_head(b"fLaC", 24_000), ".flac", false, true, "flac without content-length");
    }

    #[test]
    fn generic_audio_streams_fmp4_and_m4a_with_leading_moov() {
        let mut fragmented = aac_init(b"isom\0\0\0\0");
        let mut traf = atom(b"tfhd", &[0; 8]); traf.extend(atom(b"trun", &[0, 0, 0, 0, 0, 0, 0, 1]));
        fragmented.extend(atom(b"moof", &atom(b"traf", &traf))); fragmented.extend(atom(b"mdat", &vec![0x55; 8192]));
        case(fragmented, ".m4a", true, true, "fmp4");
        let mut classic = aac_init(M4A); classic.extend(atom(b"mdat", &vec![0x55; 16_384]));
        case(classic, ".m4a", true, true, "m4a moov first");
    }

    #[test]
    fn generic_audio_decrypts_cenc_fmp4_while_the_file_arrives_when_the_provider_hands_over_the_key() {
        use crate::download::progressive_cenc::tests::{build, plain_fragments, FragmentOptions, Spec, KEY};
        let built = build(&Spec::default(), &plain_fragments(12, 10), &FragmentOptions::default());
        let hex: String = KEY.iter().map(|byte| format!("{byte:02x}")).collect();
        let option = format!(",decryption:{{strategy:'ffmpeg.mov_key',key:'{hex}',input_format:'mov'}}");
        case_with(built.encrypted.clone(), ".m4a", true, true, "cenc with key", &option, Some(built.expected.clone()), 0);
        // Without the key the same bytes are protected media: the lease aborts.
        case(built.encrypted.clone(), ".m4a", true, false, "cenc without key");
        // A wrong key or a malformed descriptor never exposes ciphertext.
        let wrong = format!(",decryption:{{strategy:'ffmpeg.mov_key',key:'{}'}}", "a5".repeat(16));
        // Before the first sample only the neutralised headers may ever be exposed.
        case_with(built.encrypted.clone(), ".m4a", true, false, "cenc wrong key", &wrong, Some(built.expected.clone()), built.samples[0].0);
        case_with(built.encrypted.clone(), ".m4a", true, false, "cenc malformed key", ",decryption:{strategy:'ffmpeg.mov_key',key:'zz'}", None, 0);
        case_with(built.encrypted, ".m4a", true, false, "cenc other strategy", &format!(",decryption:{{strategy:'other',key:'{hex}'}}"), None, 0);
    }

    #[test]
    fn generic_audio_aborts_unsupported_media_so_the_caller_can_use_the_complete_download() {
        let init = aac_init(M4A);
        let mut late_moov = atom(b"ftyp", M4A);
        late_moov.extend(atom(b"mdat", &vec![0x55; 16_384])); late_moov.extend_from_slice(&init[24..]);
        case(late_moov, ".m4a", true, false, "m4a moov at end");
        case(with_head(&[0x1a, 0x45, 0xdf, 0xa3], 24_000), ".m4a", true, false, "unrecognized container");
    }
}
