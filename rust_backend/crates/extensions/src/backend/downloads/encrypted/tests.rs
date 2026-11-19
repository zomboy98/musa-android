use super::super::container_tests::{container_fixture_with_qualities, container_request};
use super::*;
use crate::RuntimeLimits;
use crate::environment::ExtensionEnvironment;
use base64::Engine;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::AtomicUsize;

#[test]
fn amazon_best_flac_is_narrowly_accepted() {
    let mut manifest = crate::manifest::ExtensionManifest {
        name: "amazon".into(),
        quality_options: vec![crate::manifest::QualityOption {
            id: "best".into(), label: "FLAC Best Available".into(),
            kind: "lossless".into(), ..Default::default()
        }],
        ..Default::default()
    };
    assert!(supported_quality(&manifest, "best"));
    let request = DownloadRequest { quality: "best".into(), ..Default::default() };
    assert!(strict_codec_matches(&request, &manifest, &json!({
        "audio_codec": "flac", "bit_depth": 16, "sample_rate": 44100
    })));
    assert!(!strict_codec_matches(&request, &manifest, &json!({"audio_codec": "aac"})));
    assert!(!strict_codec_matches(&request, &manifest, &json!({})));
    manifest.name = "other".into();
    assert!(!supported_quality(&manifest, "best"));
    manifest.name = "amazon".into();
    manifest.quality_options[0].label = "FLAC 24 bit Best Available".into();
    assert!(!supported_quality(&manifest, "best"));
    manifest.quality_options[0].label = "FLAC Best Available".into();
    manifest.quality_options[0].kind = "lossy".into();
    assert!(!supported_quality(&manifest, "best"));
    assert!(!supported_quality(&manifest, "unknown"));
}

fn helper() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/private_mov.py")
}

fn launch(mode: &str, input: &Path, output: Option<&Path>, key: &[u8]) -> std::process::Child {
    let mut command = Command::new("python");
    command.arg(helper()).arg(mode).arg(input);
    if let Some(output) = output {
        command.arg(output);
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("PyAV fixture Python must be installed");
    child.stdin.take().unwrap().write_all(key).unwrap();
    child
}

fn joined(child: &mut std::process::Child) -> bool {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status.success();
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("owned fixture process exceeded deadline");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn amazon_best_publishes_measured_flac_from_owned_cenc() {
    let directory = tempfile::tempdir().unwrap();
    let encrypted = directory.path().join("owned-fixture.mp4");
    assert!(joined(&mut launch("create", &encrypted, None, &[19; 16])));
    let ciphertext = base64::engine::general_purpose::STANDARD
        .encode(std::fs::read(&encrypted).unwrap());
    let source = directory.path().join("sources/amazon");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(source.join("manifest.json"), json!({
        "name":"amazon", "version":"2.3.19", "description":"Owned fixture",
        "type":["download_provider"], "permissions":{"file":true,"storage":true},
        "skipMetadataEnrichment":true,
        "qualityOptions":[{"id":"best","label":"FLAC Best Available","kind":"lossless"}]
    }).to_string()).unwrap();
    std::fs::write(source.join("index.js"), format!(
        "registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},download(trackId,quality,outputPath){{file.writeBytes(outputPath,{});return {{success:true,file_path:outputPath,decryption:{{strategy:'ffmpeg.mov_key',input_format:'mov',output_extension:'.flac',key:Array(16).fill(19).map(x=>x.toString(16).padStart(2,'0')).join('')}}}};}}}});", json!(ciphertext)
    )).unwrap();
    let backend = Backend::new(&directory.path().join("sources"), &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap();
    backend.load_all().unwrap();
    backend.set_enabled("amazon", true).unwrap();
    let output = directory.path().join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend.environment().set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
    let private_probe = ExtensionEnvironment::new(&directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1").unwrap();
    private_probe.set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
    let probe = private_probe.load(&json!({"name":"example.audio","version":"1","description":"Owned private access fixture","type":["download_provider"],"permissions":{"file":true,"storage":true}}).to_string(),
        "registerExtension({inspect(p){const read=file.read(p);return {exists:file.exists(p),readable:read&&read.success===true};}});", RuntimeLimits::default()).unwrap();
    backend.register_private_mov_finalizer(Arc::new(FixtureFinalizer {
        mode: "success", destination: output.join("Track.flac"),
        state: backend.environment().download_state(), probe, retained: Mutex::default(),
        calls: AtomicUsize::new(0),
    })).unwrap();
    let mut request = container_request(&output, false);
    request["service"] = "amazon".into();
    request["source"] = "amazon".into();
    request["quality"] = "best".into();
    let result: Value = serde_json::from_str(&backend.download_by_strategy(&request.to_string(), &|| Ok(())).unwrap()).unwrap();
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["audio_codec"], "flac", "{result}");
    assert_eq!(result["actual_bit_depth"], 16, "{result}");
    assert_eq!(result["actual_sample_rate"], 44100, "{result}");
    assert_eq!(result["private_finalization_validated"], true);
    assert!(output.join("Track.flac").exists());
    backend.shutdown();
    private_probe.shutdown();
}

struct FixtureFinalizer {
    mode: &'static str,
    destination: PathBuf,
    state: Arc<mornye_core::downloads::DownloadState>,
    probe: Arc<crate::ExtensionRuntime>,
    retained: Mutex<Option<Arc<PrivateMovJob>>>,
    calls: AtomicUsize,
}

impl PrivateMovFinalizer for FixtureFinalizer {
    fn finalize(&self, job: Arc<PrivateMovJob>) -> Result<(), PrivateFinalizationError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        assert!(
            !self.destination.exists(),
            "publication occurred before finalization"
        );
        let observed: Value = serde_json::from_str(
            &self
                .probe
                .call(
                    "inspect",
                    &json!([job.input_path()]).to_string(),
                    None,
                    5000,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            observed["exists"], false,
            "private input exposed to extension"
        );
        assert_eq!(
            observed["readable"], false,
            "private input readable by extension"
        );
        if self.mode == "unconfirmed" {
            *self.retained.lock().unwrap() = Some(job);
            return Err(PrivateFinalizationError::ProducerUnconfirmed);
        }
        let mut child = launch(
            "decrypt",
            job.input_path(),
            Some(job.output_path()),
            job.key_bytes(),
        );
        if self.mode == "cancel" {
            self.state.cancel("private-fixture").unwrap();
            assert!(job.input_path().exists());
            let _ = child.kill();
        }
        let success = joined(&mut child);
        if self.mode == "truncated" && success {
            std::fs::OpenOptions::new()
                .write(true)
                .open(job.output_path())
                .unwrap()
                .set_len(42)
                .unwrap();
        }
        if self.mode == "empty-pcm" && success {
            // Keep a structurally valid STREAMINFO-only FLAC with unknown
            // sample count. A remux/probe success is not decoded audio.
            let mut header = std::fs::read(job.output_path()).unwrap();
            assert_eq!(&header[..4], b"fLaC");
            header.truncate(42);
            header[4] = 0x80;
            header[21] &= 0xf0;
            header[22..42].fill(0);
            std::fs::write(job.output_path(), header).unwrap();
        }
        if self.mode == "collision" {
            std::fs::write(&self.destination, b"another publisher won").unwrap();
        }
        job.acknowledge_terminal(ProducerTerminal::Stopped);
        if success {
            Ok(())
        } else {
            Err(PrivateFinalizationError::Failed)
        }
    }
}

#[test]
fn real_owned_cenc_fixture_is_private_validated_cancel_safe_and_collision_safe() {
    for mode in [
        "success",
        "tagged",
        "wrong-key",
        "truncated",
        "empty-pcm",
        "wrong-quality",
        "opaque-quality",
        "legacy-key",
        "collision",
        "cancel",
        "unconfirmed",
    ] {
        let directory = tempfile::tempdir().unwrap();
        let encrypted = directory.path().join("owned-fixture.mp4");
        let mut create = launch("create", &encrypted, None, &[19; 16]);
        assert!(
            joined(&mut create),
            "owned CENC fixture generation failed; PyAV is required"
        );
        let ciphertext =
            base64::engine::general_purpose::STANDARD.encode(std::fs::read(&encrypted).unwrap());
        let key_byte = if mode == "wrong-key" { 20 } else { 19 };
        // Only ciphertext is embedded in a fixture source file. The fictional
        // fixture key is constructed in VM memory, never written as a string.
        let mut body = format!(
            "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath,decryption:{{strategy:'ffmpeg.mov_key',input_format:'mov',output_extension:'.flac',key:Array(16).fill({key_byte}).map(x=>x.toString(16).padStart(2,'0')).join('')}}}};",
            json!(ciphertext)
        );
        if mode == "legacy-key" {
            body = format!(
                "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath,decryption_key:Array(16).fill({key_byte}).map(x=>x.toString(16).padStart(2,'0')).join('')}};",
                json!(ciphertext)
            );
        }
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &body,
            json!([{"id":"FLAC_16_44100","label":"FLAC 16 bit 44100 Hz"},{"id":"FLAC_24_96000","label":"FLAC 24 bit 96000 Hz"},{"id":"opaque","label":"Provider tier"}]),
        );
        let private_probe = ExtensionEnvironment::new(
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
        )
        .unwrap();
        private_probe
            .set_allowed_download_directories(std::slice::from_ref(&output))
            .unwrap();
        let probe = private_probe.load(&json!({"name":"example.audio","version":"1","description":"Owned private access fixture","type":["download_provider"],"permissions":{"file":true,"storage":true}}).to_string(),
            "registerExtension({inspect(p){const read=file.read(p);return {exists:file.exists(p),readable:read&&read.success===true};}});", RuntimeLimits::default()).unwrap();
        let finalizer = Arc::new(FixtureFinalizer {
            mode,
            destination: output.join("Track.flac"),
            state: backend.environment().download_state(),
            probe,
            retained: Mutex::default(),
            calls: AtomicUsize::new(0),
        });
        backend
            .register_private_mov_finalizer(finalizer.clone())
            .unwrap();
        assert!(
            backend
                .download("example.audio", ProviderDownloadRequest::default(), 1000)
                .is_err(),
            "public JSON API remained available after private capability registration"
        );
        assert!(
            backend
                .environment()
                .set_allowed_download_directories(&[directory.path().join("data")])
                .is_err()
        );
        let mut request = container_request(&output, false);
        request["item_id"] = "private-fixture".into();
        request["source"] = "example.audio".into();
        if mode == "tagged" {
            request["embed_metadata"] = true.into();
            request["comment"] = "synthetic-provider-secret-marker".into();
        }
        request["quality"] = if mode == "wrong-quality" {
            "FLAC_24_96000"
        } else if mode == "opaque-quality" {
            "opaque"
        } else {
            "FLAC_16_44100"
        }
        .into();
        assert_eq!(
            supports_request(&DownloadRequest::parse(&request.to_string()).unwrap()),
            mode != "tagged"
        );
        let response = backend.download_by_strategy(&request.to_string(), &|| Ok(()));
        if mode == "cancel" {
            assert!(response.is_err() || !response.as_ref().unwrap().contains("\"success\":true"));
        } else {
            let response = response.unwrap();
            let result: Value = serde_json::from_str(&response).unwrap();
            assert_eq!(
                result["success"].as_bool(),
                Some(matches!(mode, "success" | "legacy-key")),
                "mode {mode}"
            );
            assert!(!response.contains("decryption"));
            assert!(
                !response.contains(&crate::binary::encode(&[key_byte as u8; 16], "hex").unwrap())
            );
            if matches!(mode, "success" | "legacy-key") {
                assert_eq!(result["private_finalization_validated"], true);
            }
        }
        if mode == "collision" {
            assert_eq!(
                std::fs::read(output.join("Track.flac")).unwrap(),
                b"another publisher won"
            );
        } else {
            assert_eq!(
                output.join("Track.flac").exists(),
                matches!(mode, "success" | "legacy-key")
            );
        }
        if matches!(mode, "opaque-quality" | "tagged") {
            assert_eq!(finalizer.calls.load(Ordering::Relaxed), 0);
        }
        let private_root = directory.path().join("data/.host-private-mov");
        if mode == "unconfirmed" {
            let job = finalizer.retained.lock().unwrap().take().unwrap();
            assert!(job.input_path().exists());
            let attempt = job.input_path().parent().unwrap().to_path_buf();
            job.acknowledge_terminal(ProducerTerminal::Stopped);
            assert!(!attempt.exists());
        }
        assert_eq!(
            std::fs::read_dir(&private_root).unwrap().count(),
            0,
            "mode {mode} retained completed staging"
        );
        backend.shutdown();
        private_probe.shutdown();
    }
}

#[test]
fn private_root_rejects_existing_and_future_grants_including_aliases() {
    let directory = tempfile::tempdir().unwrap();
    let private = directory.path().join(".host-private-mov");
    std::fs::create_dir(&private).unwrap();
    let files = Arc::new(FileRegistry::default());
    files
        .set_allowed_directories(&[directory.path().to_path_buf()])
        .unwrap();
    assert!(files.reserve_private_directory(&private).is_err());
    files.set_allowed_directories(&[]).unwrap();
    let grant = files.grant_temporary_directory(directory.path()).unwrap();
    assert!(files.reserve_private_directory(&private).is_err());
    drop(grant);
    files.reserve_private_directory(&private).unwrap();
    assert!(
        files
            .set_allowed_directories(&[directory.path().to_path_buf()])
            .is_err()
    );
    assert!(files.grant_temporary_directory(&private).is_err());
    assert!(files.extension(&private).is_err());
    let child = private.join("attempt");
    std::fs::create_dir(&child).unwrap();
    assert!(files.grant_temporary_directory(&child).is_err());
    assert!(files.extension(&child).is_err());
    #[cfg(unix)]
    {
        let alias = directory.path().join("alias");
        std::os::unix::fs::symlink(&private, &alias).unwrap();
        assert!(
            files
                .set_allowed_directories(std::slice::from_ref(&alias))
                .is_err()
        );
        assert!(files.grant_temporary_directory(&alias).is_err());
        assert!(files.extension(&alias).is_err());
    }
    let permitted = directory.path().join("downloads");
    files
        .set_allowed_directories(std::slice::from_ref(&permitted))
        .unwrap();
    assert!(files.grant_temporary_directory(&permitted).is_ok());
}

#[test]
fn finalize_local_rejects_tainted_metadata_before_producer_or_staging() {
    struct CountingFinalizer(AtomicUsize);
    impl PrivateMovFinalizer for CountingFinalizer {
        fn finalize(&self, _: Arc<PrivateMovJob>) -> Result<(), PrivateFinalizationError> {
            self.0.fetch_add(1, Ordering::Relaxed);
            Err(PrivateFinalizationError::Failed)
        }
    }

    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "return {success:true,decryption:{strategy:'ffmpeg.mov_key',key:Array(16).fill(19).map(x=>x.toString(16).padStart(2,'0')).join('')}};",
        json!([{"id":"FLAC_16_44100","label":"FLAC 16 bit 44100 Hz"}]),
    );
    backend.enable_private_downloads();
    let descriptor = backend
        .download_private_with_lease(
            "example.audio",
            ProviderDownloadRequest::default(),
            5000,
            None,
        )
        .unwrap()
        .decryption
        .unwrap();
    let manifest = backend.download_manifest("example.audio").unwrap();
    let mut value = container_request(&output, true);
    value["quality"] = "FLAC_16_44100".into();
    let mut request = DownloadRequest::parse(&value.to_string()).unwrap();
    metadata::apply_metadata(
        &mut request,
        &json!({"comment":"synthetic-provider-secret-marker"}),
        true,
    );
    let files = backend.environment().native_files().unwrap();
    let input = files
        .resolve_legacy(&output.join("missing-input.mp4").to_string_lossy())
        .unwrap();
    let destination = files
        .resolve_legacy(&output.join("Track.flac").to_string_lossy())
        .unwrap();
    let lease = Arc::new(
        backend
            .environment()
            .download_state()
            .acquire("guard-test")
            .unwrap(),
    );
    let finalizer = Arc::new(CountingFinalizer(AtomicUsize::new(0)));
    let result = finalize_local(
        &backend,
        finalizer.clone(),
        &request,
        &manifest,
        descriptor,
        &input,
        &destination,
        "Track.flac",
        lease,
        &|| Ok(()),
    )
    .unwrap();
    let DownloadOutcome::Final(result) = result else {
        panic!("expected final rejection")
    };
    assert_eq!(result["success"], false);
    assert!(
        !result
            .to_string()
            .contains("synthetic-provider-secret-marker")
    );
    assert_eq!(finalizer.0.load(Ordering::Relaxed), 0);
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    assert!(!directory.path().join("data/.host-private-mov").exists());
    backend.shutdown();
}

#[test]
fn provider_enrichment_taints_request_fields_and_metadata_is_rejected() {
    let directory = tempfile::tempdir().unwrap();
    let mut value = container_request(directory.path(), true);
    value["quality"] = "FLAC_16_44100".into();
    let mut request = DownloadRequest::parse(&value.to_string()).unwrap();
    let marker = "synthetic-provider-secret-marker";
    // Simulate the source extension's enrichment result at the exact merge
    // boundary used by the planner. The empty response passed to the field
    // builder does not remove data already merged into the request.
    metadata::apply_metadata(&mut request, &json!({"comment": marker}), true);
    let fields = metadata::download_metadata_fields(&request, &json!({}));
    assert_eq!(fields.get("COMMENT").map(String::as_str), Some(marker));
    let fixture = base64::engine::general_purpose::STANDARD.decode("ZkxhQwAAACISABIAAAAAACQVCsRA8AAAAAAAAAAAAAAAAAAAAAAAAAAAhAAALg0AAABMYXZmNjIuMTIuMTAwAQAAABUAAABlbmNvZGVyPUxhdmY2Mi4xMi4xMDD/+HkIAAG4VQAAAIxD").unwrap();
    let mut result = Vec::new();
    embed_flac_metadata(
        &mut std::io::Cursor::new(fixture),
        &mut result,
        &fields,
        "",
        None,
        &|| Ok(()),
    )
    .unwrap();
    assert!(
        result
            .windows(marker.len())
            .any(|window| window == marker.as_bytes())
    );
    assert!(!supports_request(&request));
}

#[test]
fn private_finalization_rejects_unqualified_requests() {
    let directory = tempfile::tempdir().unwrap();
    let mut request = container_request(directory.path(), false);
    request["source"] = "example.audio".into();
    request["quality"] = "FLAC_16_44100".into();
    assert!(supports_request(
        &DownloadRequest::parse(&request.to_string()).unwrap()
    ));
    for (field, value) in [
        ("output_path", json!("/private/saf/output.flac")),
        ("output_fd", json!(7)),
        ("output_ext", json!(".m4a")),
        ("output_dir", json!("")),
        ("quality", json!("")),
        ("allow_quality_fallback", json!(true)),
        ("embed_metadata", json!(true)),
        ("embed_lyrics", json!(true)),
        ("embed_replaygain", json!(true)),
        ("post_processing_enabled", json!(true)),
        ("requires_container_conversion", json!(true)),
    ] {
        let mut unsupported = request.clone();
        unsupported[field] = value;
        assert!(
            !supports_request(&DownloadRequest::parse(&unsupported.to_string()).unwrap()),
            "accepted unsupported {field}"
        );
    }
}
