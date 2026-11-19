//! Explicit device-only integration test. The host supplies an owned synthetic
//! CENC fixture encrypted with the byte [19; 16], and the matching private .so.
//! Set TMPDIR to a writable, test-owned Android directory before starting the
//! test binary; the fixture and library paths must also be absolute.

use super::*;
use base64::Engine;
use mornye_extensions::{RuntimeLimits, backend::Backend};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

struct CancelBeforeNative {
    inner: NativePrivateMovFinalizer,
    state: Arc<mornye_core::downloads::DownloadState>,
    observed: Arc<AtomicBool>,
}

impl PrivateMovFinalizer for CancelBeforeNative {
    fn finalize(&self, job: Arc<PrivateMovJob>) -> Result<(), PrivateFinalizationError> {
        self.state.cancel("android-private-fixture").unwrap();
        let outcome = self.inner.finalize(job);
        assert_eq!(outcome, Err(PrivateFinalizationError::Cancelled));
        self.observed.store(true, Ordering::Release);
        outcome
    }
}

#[test]
#[ignore = "requires an explicitly provisioned synthetic fixture and private Android library"]
fn owned_cenc_uses_real_adapter_and_native_callbacks() {
    let fixture = std::env::var_os("MUSA_PRIVATE_MOV_FIXTURE").expect("fixture path required");
    let library = std::env::var_os("MUSA_PRIVATE_MOV_LIBRARY").expect("library path required");
    let ciphertext = base64::engine::general_purpose::STANDARD
        .encode(std::fs::read(fixture).expect("synthetic fixture required"));
    for mode in ["success", "wrong-key", "cancel"] {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("sources/example.audio");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("manifest.json"),
            json!({
                "name":"example.audio", "version":"1", "description":"Synthetic fixture",
                "type":["download_provider"], "permissions":{"file":true,"storage":true},
                "skipMetadataEnrichment":true,
                "qualityOptions":[{"id":"FLAC_16_44100","label":"FLAC 16 bit 44100 Hz"}]
            })
            .to_string(),
        )
        .unwrap();
        let key_byte = if mode == "wrong-key" { 20 } else { 19 };
        std::fs::write(source.join("index.js"), format!(
            "registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},download(trackId,quality,outputPath){{file.writeBytes(outputPath,{});return {{success:true,file_path:outputPath,decryption:{{strategy:'ffmpeg.mov_key',input_format:'mov',output_extension:'.flac',key:Array(16).fill({key_byte}).map(x=>x.toString(16).padStart(2,'0')).join('')}}}};}}}});", json!(ciphertext)
        )).unwrap();
        let backend = Backend::new(
            &directory.path().join("sources"),
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        backend.load_all().unwrap();
        backend.set_enabled("example.audio", true).unwrap();
        backend
            .environment()
            .log_buffer()
            .set_enabled(true)
            .unwrap();
        let output = directory.path().join("output");
        std::fs::create_dir_all(&output).unwrap();
        backend
            .environment()
            .set_allowed_download_directories(std::slice::from_ref(&output))
            .unwrap();
        let native =
            unsafe { NativePrivateMovFinalizer::load_test_library_unchecked(Path::new(&library)) }
                .expect("trusted test library must load");
        let cancelled = Arc::new(AtomicBool::new(false));
        let finalizer: Arc<dyn PrivateMovFinalizer> = if mode == "cancel" {
            Arc::new(CancelBeforeNative {
                inner: native,
                state: backend.environment().download_state(),
                observed: Arc::clone(&cancelled),
            })
        } else {
            Arc::new(native)
        };
        backend.register_private_mov_finalizer(finalizer).unwrap();
        let request = json!({"service":"example.audio", "source":"example.audio",
            "provider_track_id":"track", "item_id":"android-private-fixture",
            "use_extensions":true, "use_fallback":false, "output_dir":output,
            "track_name":"Track", "artist_name":"Artist", "album_name":"Album",
            "filename_format":"{title}", "output_ext":".flac", "quality":"FLAC_16_44100",
            "embed_metadata":false, "embed_lyrics":false});
        let response = backend.download_by_strategy(&request.to_string(), &|| Ok(()));
        match &response {
            Ok(value) | Err(value) => assert_no_fixture_key(value.as_bytes(), key_byte),
        }
        if mode == "cancel" {
            assert!(response.is_err() || !response.as_ref().unwrap().contains("\"success\":true"));
            assert!(
                cancelled.load(Ordering::Acquire),
                "native cancellation was not observed"
            );
        } else {
            let raw = response.unwrap();
            let result: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(
                result["success"].as_bool(),
                Some(mode == "success"),
                "mode {mode}"
            );
            assert!(!raw.contains("decryption"));
            if mode == "success" {
                assert_eq!(result["private_finalization_validated"], true);
                assert_eq!(
                    &std::fs::read(output.join("Track.flac")).unwrap()[..4],
                    b"fLaC"
                );
            }
        }
        let logs = backend.environment().log_buffer().all().unwrap();
        assert_no_fixture_key(logs.as_bytes(), key_byte);
        assert_eq!(output.join("Track.flac").exists(), mode == "success");
        assert_eq!(
            std::fs::read_dir(directory.path().join("data/.host-private-mov"))
                .unwrap()
                .count(),
            0
        );
        backend.shutdown();
    }
}

fn assert_no_fixture_key(output: &[u8], key_byte: u8) {
    let raw = [key_byte; 16];
    let hex = format!("{key_byte:02x}").repeat(16);
    assert!(!output.windows(raw.len()).any(|part| part == raw));
    assert!(!output.windows(hex.len()).any(|part| part == hex.as_bytes()));
}
