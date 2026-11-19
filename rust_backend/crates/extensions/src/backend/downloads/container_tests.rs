use super::*;
use crate::RuntimeLimits;
use base64::Engine;

pub(super) const REAL_FLAC_BASE64: &str = "ZkxhQwAAACISABIAAAAAACQVCsRA8AAAAAAAAAAAAAAAAAAAAAAAAAAAhAAALg0AAABMYXZmNjIuMTIuMTAwAQAAABUAAABlbmNvZGVyPUxhdmY2Mi4xMi4xMDD/+HkIAAG4VQAAAIxD";

#[test]
fn provider_vm_staging_survives_cancel_until_late_producer_ack_and_success_does_not_leak() {
    for cancelled in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let (backend, output) = container_fixture_with_qualities(directory.path(),
            &format!("const input=outputPath+'.source.flac'; file.writeBytes(input,{}); const converted=ffmpeg.convert(input,outputPath,{{codec:'copy'}}); if(!converted.success) return converted; return {{success:true,file_path:outputPath}};", json!(REAL_FLAC_BASE64)),
            json!([{"id":"LOSSLESS","kind":"lossless"}]));
        let registry = backend.environment().ffmpeg_commands();
        registry.enable_typed_producer_lifetime().unwrap();
        let backend = Arc::new(backend);
        let mut request = container_request(&output, false);
        request["item_id"] = "producer-fixture".into();
        let active = backend.clone();
        let (send, receive) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = active.download_by_strategy(&request.to_string(), &|| Ok(()));
            send.send(result).unwrap();
        });
        let pending: Vec<Value> = serde_json::from_str(&registry.wait_pending_json(2_000).unwrap()).unwrap();
        assert_eq!(pending.len(), 1);
        let command_id = pending[0]["command_id"].as_str().unwrap();
        let stage = std::path::PathBuf::from(pending[0]["output_path"].as_str().unwrap());
        let attempt = stage.parent().unwrap().to_path_buf();
        let source = std::path::PathBuf::from(format!("{}.source.flac", stage.display()));
        assert!(source.is_file());
        if cancelled {
            backend.environment().download_state().cancel("producer-fixture").unwrap();
        } else {
            // The fixture producer completes its copy before its real terminal
            // event. This exercises the provider VM/queue/publication pipeline.
            std::fs::copy(&source, &stage).unwrap();
            registry.acknowledge_producer_termination(command_id, crate::ffmpeg::ProducerTerminal::Stopped);
            registry.complete(command_id, crate::ffmpeg::CommandResult { success: true, output: String::new(), error: String::new() }).unwrap();
        }
        let result = receive.recv_timeout(Duration::from_secs(3)).unwrap();
        worker.join().unwrap();
        if cancelled {
            assert!(result.is_err() || !serde_json::from_str::<Value>(&result.unwrap()).unwrap()["success"].as_bool().unwrap_or(false));
            assert!(attempt.is_dir());
            // A delayed writer can still use its source/output after the caller
            // returned; the terminal event comes only once that writer ends.
            std::fs::copy(&source, &stage).unwrap();
            assert!(!output.join("Track.flac").exists());
            registry.acknowledge_producer_termination(command_id, crate::ffmpeg::ProducerTerminal::Stopped);
            assert!(!attempt.exists());
        } else {
            let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["success"], true, "{result}");
            assert!(!attempt.exists());
            assert!(output.join("Track.flac").is_file());
        }
        backend.shutdown();
    }
}

#[test]
fn retry_preserves_unknown_prior_attempt_even_when_its_marker_was_removed() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(directory.path(),
        &format!("file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath}};", json!(REAL_FLAC_BASE64)),
        json!([{"id":"LOSSLESS","kind":"lossless"}]));
    let final_path = output.join("Track.flac");
    let digest = crate::binary::encode(&Sha256::digest(final_path.to_string_lossy().to_lowercase().as_bytes()), "hex").unwrap();
    let abandoned = output.join(format!(".mornye-download-{digest}-prior-owner"));
    std::fs::create_dir(&abandoned).unwrap();
    let input = abandoned.join("active-source.flac");
    std::fs::write(&input, b"belongs to a prior producer").unwrap();
    let marker = abandoned.join(crate::ffmpeg::UNCONFIRMED_PRODUCER_MARKER);
    std::fs::write(&marker, b"").unwrap();
    std::fs::remove_file(&marker).unwrap();
    // New backend/registry has no knowledge of the old producer; absence of a
    // marker is not proof of termination and cannot authorize recursive cleanup.
    let request = container_request(&output, false);
    let result: Value = serde_json::from_str(&backend.download_by_strategy(&request.to_string(), &|| Ok(())).unwrap()).unwrap();
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(std::fs::read(&input).unwrap(), b"belongs to a prior producer");
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 2);
    backend.shutdown();
}

#[test]
fn provider_existing_flag_never_hands_external_file_to_finalizers() {
    for marker in ["flag", "prefix", "both"] {
        let directory = tempfile::tempdir().unwrap();
        let external = directory.path().join("output/library.flac");
        let returned = if marker == "flag" {
            external.to_string_lossy().into_owned()
        } else {
            format!("EXISTS:{}", external.display())
        };
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &format!(
                "return {{success:true,file_path:{},already_exists:{}}};",
                json!(returned),
                marker != "prefix"
            ),
            json!([{"id":"LOSSLESS","kind":"lossless"}]),
        );
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(REAL_FLAC_BASE64)
            .unwrap();
        std::fs::write(&external, &bytes).unwrap();
        for deferred in [false, true] {
            let mut request = container_request(&output, false);
            request["defer_saf_publish"] = deferred.into();
            let result: Value = serde_json::from_str(
                &backend
                    .download_by_strategy(&request.to_string(), &|| Ok(()))
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(result["success"], false, "{marker}/{deferred}: {result}");
            assert_eq!(result["error_type"], "file_error", "{result}");
            assert!(result.get("file_path").is_none(), "{result}");
            assert_eq!(std::fs::read(&external).unwrap(), bytes);
            assert!(!output.join("Track.flac").exists());
        }
        backend.shutdown();
    }
}

#[test]
fn opaque_strict_quality_requires_observed_audio_but_accepts_real_flac() {
    for (payload, extension, expected) in [
        (
            base64::engine::general_purpose::STANDARD.encode(b"invalid audio"),
            ".mp3",
            false,
        ),
        (REAL_FLAC_BASE64.to_owned(), ".flac", true),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &format!(
                "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath}};",
                json!(payload)
            ),
            json!([{"id":"AUTO","label":"Automatic"}]),
        );
        let mut request = container_request(&output, false);
        request["quality"] = "AUTO".into();
        request["output_ext"] = extension.into();
        let result: Value = serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["success"], expected, "{result}");
        assert_eq!(
            std::fs::read_dir(&output).unwrap().count(),
            usize::from(expected)
        );
        if !expected {
            assert_eq!(result["error_type"], "quality_unavailable");
        }
        backend.shutdown();
    }
}

#[test]
fn every_local_quality_mode_preserves_a_target_not_reused_by_precheck() {
    for (quality, fallback) in [("LOSSLESS", false), ("LOSSLESS", true), ("", false)] {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("output/Track.flac");
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &format!(
                "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath}};",
                json!(REAL_FLAC_BASE64)
            ),
            json!([{"id":"LOSSLESS","kind":"lossless"}]),
        );
        // Existing empty files are deliberately not reused by the planner's
        // precheck. The no-replace syscall still must preserve their ownership.
        std::fs::write(&target, b"").unwrap();
        let mut request = container_request(&output, false);
        request["quality"] = quality.into();
        request["allow_quality_fallback"] = fallback.into();
        let result: Value = serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["success"], false, "{quality}/{fallback}: {result}");
        assert_eq!(result["error_type"], "file_error", "{result}");
        assert_eq!(std::fs::read(&target).unwrap(), b"");
        assert_eq!(std::fs::read_dir(&output).unwrap().count(), 1);
        backend.shutdown();
    }
}

#[test]
fn saf_local_work_contract_requires_owned_reservation_with_uncreated_output() {
    for deferred in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &format!(
                "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath}};",
                json!(REAL_FLAC_BASE64)
            ),
            json!([{"id":"LOSSLESS","kind":"lossless"}]),
        );
        let mut request = container_request(&output, false);
        request["defer_saf_publish"] = deferred.into();
        // Model Android File.createTempFile exactly: it creates an empty file,
        // not merely a unique name. JSON must never imply authority to replace it.
        let placeholder = tempfile::Builder::new()
            .prefix("native_saf_work_")
            .suffix(".flac")
            .tempfile_in(&output)
            .unwrap();
        request["output_path"] = placeholder.path().to_string_lossy().into();
        let run = |request: &Value| -> Value {
            serde_json::from_str(
                &backend
                    .download_by_strategy(&request.to_string(), &|| Ok(()))
                    .unwrap(),
            )
            .unwrap()
        };
        let result = run(&request);
        assert_eq!(result["success"], false, "{result}");
        assert_eq!(result["error_type"], "file_error", "{result}");
        assert_eq!(std::fs::read(placeholder.path()).unwrap(), b"");

        // The adapter owns an unpredictable private attempt directory; its
        // output name is not created before the backend atomically publishes.
        // Keep the directory owner alive through final publication/adoption.
        let private_root = directory.path().join("native-saf-attempts");
        std::fs::create_dir(&private_root).unwrap();
        let reservation = tempfile::Builder::new()
            .prefix("native_saf_attempt_")
            .tempdir_in(&private_root)
            .unwrap();
        let working_path = reservation.path().join("output.flac");
        request["output_path"] = working_path.to_string_lossy().into();
        assert!(!working_path.exists());
        // The private SAF workspace is outside configured library grants.
        // Native publication needs the scoped capability too, not just the
        // provider's separate temporary download directory grant.
        let denied = run(&request);
        assert_eq!(denied["success"], false, "{denied}");
        assert!(!working_path.exists());
        let grant = backend
            .environment()
            .grant_temporary_download_directory(reservation.path())
            .unwrap();
        let result = run(&request);
        assert_eq!(result["success"], true, "{result}");
        assert_eq!(result["file_path"], working_path.to_string_lossy().as_ref());
        assert_eq!(
            std::fs::read(&working_path).unwrap(),
            base64::engine::general_purpose::STANDARD
                .decode(REAL_FLAC_BASE64)
                .unwrap()
        );
        assert_eq!(std::fs::read_dir(reservation.path()).unwrap().count(), 1);
        drop(grant);
        assert!(
            backend
                .environment()
                .native_files()
                .unwrap()
                .resolve_legacy(&working_path.to_string_lossy())
                .is_err()
        );
        assert!(
            working_path.exists(),
            "grant revocation must not delete completed media"
        );
        assert!(placeholder.path().exists());
        backend.shutdown();
    }
}

#[test]
fn provider_format_fields_and_returned_path_override_the_planned_extension() {
    let request = DownloadRequest {
        track_name: "Track".into(),
        filename_format: "{title}".into(),
        output_ext: ".flac".into(),
        ..Default::default()
    };
    let manifest = ExtensionManifest::default();
    for (result, expected) in [
        (json!({"file_path":"staged/Track.m4a"}), ".m4a"),
        (json!({"file_path":"staged/Track.MP3"}), ".mp3"),
        (json!({"file_path":"staged/Track.opus"}), ".opus"),
        (json!({"file_path":"staged/Track.mp4"}), ".m4a"),
        (json!({"file_path":"staged/Track.flac"}), ".flac"),
        (
            json!({"file_path":"staged/Track.mp3","actual_container":"audio/mpeg"}),
            ".mp3",
        ),
        (
            json!({"file_path":"staged/Track.m4a","actual_extension":"audio/mp4"}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.flac","actual_container":"m4a"}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.flac","output_extension":" MP4 "}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.m4a","actual_extension":".mp3","output_extension":".flac"}),
            ".mp3",
        ),
        // A FLAC label yields to the container its bytes were probed as.
        (
            json!({"file_path":"staged/Track.flac","actual_extension":".flac","actual_container":"m4a"}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.flac","output_extension":"flac","actual_container":"mp3"}),
            ".mp3",
        ),
        (json!({}), ".flac"),
    ] {
        let response = success(
            &request,
            &result,
            "planned/Track.flac",
            false,
            &manifest,
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(response["actual_extension"], expected);
        assert_eq!(response["resolved_file_name"], format!("Track{expected}"));
    }
}

#[test]
fn downloads_publish_the_actual_container_for_regular_and_explicit_working_paths() {
    // Header-only payloads verify byte-preserving publication; real decodable
    // audio and Flutter metadata finalization are exercised on devices.
    for (returned_extension, payload, expected) in [
        ("m4a", b"\0\0\0\x18ftypM4A fixture".as_slice(), ".m4a"),
        ("mp4", b"\0\0\0\x18ftypM4A fixture".as_slice(), ".m4a"),
        ("mp3", b"ID3example audio".as_slice(), ".mp3"),
        ("opus", b"OggSexample audio".as_slice(), ".opus"),
        // A legacy provider may leave the requested suffix on MP4 bytes.
        ("flac", b"\0\0\0\x18ftypM4A fixture".as_slice(), ".m4a"),
        // Or on MP3 bytes, which FLAC tags could not be written into.
        (
            "flac",
            b"ID3\x04\0\0\0\0\0\0\xff\xfb\x90\0fixture".as_slice(),
            ".mp3",
        ),
    ] {
        for explicit_path in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let encoded = base64::engine::general_purpose::STANDARD.encode(payload);
            let (backend, output) = container_fixture(
                directory.path(),
                &format!(
                    "const path=outputPath.replace(/\\.[^.]+$/,'.{returned_extension}');
                    file.writeBytes(path,{encoded});
                    return {{success:true,file_path:path}};",
                    encoded = json!(encoded),
                ),
            );
            let mut request = container_request(&output, returned_extension == "flac");
            request["allow_quality_fallback"] = true.into();
            if explicit_path {
                request["output_path"] = output.join("working.flac").to_string_lossy().into();
            }
            let raw = backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap();
            let response: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(response["success"], true, "{response}");
            assert_eq!(response["actual_extension"], expected, "{response}");
            assert_eq!(response["resolved_file_name"], format!("Track{expected}"));
            let stem = if explicit_path { "working" } else { "Track" };
            let published = output.join(format!("{stem}{expected}"));
            assert_eq!(response["file_path"], published.to_string_lossy().as_ref());
            assert_eq!(std::fs::read(&published).unwrap(), payload);
            assert!(!output.join(format!("{stem}.flac")).exists());
            // Resolving the corrected suffix must never replace a sibling.
            let second: Value = serde_json::from_str(
                &backend
                    .download_by_strategy(&request.to_string(), &|| Ok(()))
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(second["success"], false, "{second}");
            assert_eq!(std::fs::read(&published).unwrap(), payload);
            backend.shutdown();
        }
    }
}

#[test]
fn a_flac_label_on_unrecognized_bytes_fails_without_publishing() {
    let directory = tempfile::tempdir().unwrap();
    let encoded = base64::engine::general_purpose::STANDARD.encode(b"<!DOCTYPE html>");
    let (backend, output) = container_fixture(
        directory.path(),
        &format!(
            "file.writeBytes(outputPath,{encoded});
            return {{success:true,file_path:outputPath,actual_extension:'.flac'}};",
            encoded = json!(encoded),
        ),
    );
    let mut request = container_request(&output, true);
    request["allow_quality_fallback"] = true.into();
    let raw = backend
        .download_by_strategy(&request.to_string(), &|| Ok(()))
        .unwrap();
    let response: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(response["success"], false, "{response}");
    assert!(
        text(&response, "error").contains("is not FLAC audio"),
        "{response}"
    );
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

/// A download provider running `body` as its download function, with an
/// allowed output directory.
fn container_fixture(directory: &Path, body: &str) -> (Backend, std::path::PathBuf) {
    container_fixture_with_qualities(directory, body, json!([]))
}

pub(super) fn container_fixture_with_qualities(
    directory: &Path,
    body: &str,
    qualities: Value,
) -> (Backend, std::path::PathBuf) {
    container_fixture_with_availability(
        directory,
        body,
        qualities,
        "return {available:true,track_id:'track'};",
    )
}

#[test]
fn provider_api_errors_keep_real_rate_limits_and_reject_similar_status_codes() {
    for (message, expected) in [
        (
            "Could not fetch track data: SoundCloud API returned HTTP 429",
            "rate_limit",
        ),
        (
            "Failed to resolve Deezer download: HTTP 429 for https://fixture.invalid/track",
            "rate_limit",
        ),
        (
            "Could not fetch track data: SoundCloud API returned HTTP 4290",
            "api_error",
        ),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let (backend, output) = container_fixture(
            directory.path(),
            &format!(
                "return {{success:false,error_message:{},error_type:'api_error'}};",
                json!(message)
            ),
        );
        let request = container_request(&output, false);
        let result: Value = serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["error_type"], expected, "{result}");
        backend.shutdown();
    }
}

#[test]
fn strict_opus_rejects_provider_bytes_with_a_different_codec_before_publication() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        &format!(
            "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath,actual_extension:'.mp3',audio_codec:'opus'}};",
            json!(REAL_FLAC_BASE64),
        ),
        json!([{"id":"opus_320","label":"Opus 320 kbps","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["quality"] = "opus_320".into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(result["error_type"], "quality_unavailable", "{result}");
    assert_eq!(result["diagnostic_cause"], "strict_quality_mismatch");
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn strict_encrypted_result_is_not_published_without_post_decryption_validation() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,decryption_key:'dummy'};",
        json!([{"id":"opaque","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["quality"] = "opaque".into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(result["diagnostic_cause"], "encrypted_validation_guard");
    assert!(
        text(&result, "error").contains("encrypted audio"),
        "{result}"
    );
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn all_providers_failed_only_keeps_the_last_host_cause() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    for (id, body) in [
        ("guard.audio", "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,decryption_key:'dummy'};"),
        ("fake.audio", "return {success:false,error_type:'quality_unavailable',error_message:'canary',diagnostic_cause:'strict_quality_mismatch'};"),
    ] {
        let source = sources.join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("manifest.json"),
            json!({"name":id,"version":"1","description":"fixture","type":["download_provider"],
                "permissions":{"file":true},"skipMetadataEnrichment":true,
                "qualityOptions":[{"id":"LOSSLESS","label":"FLAC 16-bit/44.1 kHz","kind":"lossless"}]})
                .to_string(),
        ).unwrap();
        std::fs::write(
            source.join("index.js"),
            format!("registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},download(trackId,quality,outputPath){{{body}}}}});"),
        ).unwrap();
    }
    let backend = Backend::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    ).unwrap();
    backend.load_all().unwrap();
    for id in ["guard.audio", "fake.audio"] {
        backend.set_enabled(id, true).unwrap();
    }
    let output = directory.path().join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend.environment().set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
    let mut request = container_request(&output, false);
    request["use_fallback"] = true.into();
    for (first, last, cause) in [
        ("guard.audio", "fake.audio", Value::Null),
        ("fake.audio", "guard.audio", json!("encrypted_validation_guard")),
    ] {
        request["service"] = first.into();
        backend.set_provider_priority("download", vec![first.into(), last.into()]).unwrap();
        let result: Value = serde_json::from_str(
            &backend.download_by_strategy(&request.to_string(), &|| Ok(())).unwrap(),
        ).unwrap();
        assert!(text(&result, "error").starts_with("All providers failed."), "{result}");
        assert_eq!(result["service"], last, "{result}");
        assert_eq!(result["diagnostic_cause"], cause, "{result}");
    }
    backend.shutdown();
}

#[test]
fn strict_encryption_descriptors_do_not_publish_or_expose_keys() {
    for descriptor in [
        "decryption_key:'private-fixture-key'",
        "decryption:{key:'private-fixture-key',method:'aes'}",
    ] {
        let directory = tempfile::tempdir().unwrap();
        let body = format!(
            "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {{success:true,file_path:outputPath,{descriptor}}};"
        );
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &body,
            json!([{"id":"opaque","kind":"lossy"}]),
        );
        let mut request = container_request(&output, false);
        request["quality"] = "opaque".into();
        let raw = backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap();
        let result: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(result["error_type"], "quality_unavailable", "{result}");
        assert!(!raw.contains("private-fixture-key"));
        assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
        backend.shutdown();
    }
}

fn container_fixture_with_availability(
    directory: &Path,
    body: &str,
    qualities: Value,
    availability: &str,
) -> (Backend, std::path::PathBuf) {
    let source = directory.join("sources/example.audio");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        json!({"name":"example.audio","version":"1",
            "description":"Generic native-container fixture","type":["download_provider"],
            "permissions":{"file":true,"storage":true},"skipMetadataEnrichment":true,"qualityOptions":qualities})
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        source.join("index.js"),
        format!(
            "registerExtension({{checkAvailability(){{{availability}}},
            download(trackId,quality,outputPath){{{body}}},attempts(){{return storage.get('attempts')||0;}}}});"
        ),
    )
    .unwrap();
    let backend = Backend::new(
        &directory.join("sources"),
        &directory.join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    backend.set_enabled("example.audio", true).unwrap();
    backend.download_manifest("example.audio").unwrap();
    let output = directory.join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    (backend, output)
}

#[test]
fn temporary_quality_never_retries_provider_with_mixed_failures() {
    for first_quality in [true, false] {
        let directory = tempfile::tempdir().unwrap();
        let body = format!(
            "let n=storage.get('attempts')||0; storage.set('attempts',n+1); if(n<2) {{let q=(n===0)==={first_quality}; return {{success:false,error_type:q?'quality_unavailable':'auth',error_message:q?'quality unavailable':'login required'}};}} file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {{success:true,file_path:outputPath,actual_extension:'.mp3'}};"
        );
        let (backend, output) = container_fixture_with_qualities(
            directory.path(),
            &body,
            json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
        );
        let mut request = container_request(&output, false);
        request["source"] = "example.audio".into();
        request["allow_quality_fallback"] = true.into();
        let result: Value = serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["success"], false, "{result}");
        // The same provider/track/quality is never repeated: a quality miss
        // gets one alternate tier (2 attempts); an authentication failure
        // blocks the provider, so no alternate tier follows (1 attempt).
        assert_eq!(
            backend
                .call("example.audio", "attempts", "[]", None, 1000)
                .unwrap(),
            if first_quality { "2" } else { "1" }
        );
        assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
        backend.shutdown();
    }
}

#[test]
fn temporary_quality_never_retries_after_verification_required() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "let n=storage.get('attempts')||0; storage.set('attempts',n+1); if(n===0) return {success:false,error_type:'quality_unavailable',error_message:'quality unavailable'}; if(n===1) return {success:false,error_type:'verification_required',error_message:'verification required'}; file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["source"] = "example.audio".into();
    request["use_fallback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["error_type"], "verification_required", "{result}");
    assert_eq!(
        backend
            .call("example.audio", "attempts", "[]", None, 1000)
            .unwrap(),
        "2"
    );
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_is_opt_in_and_uses_manifest_order() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "if (quality !== 'aac_160') throw new Error('unexpected quality'); file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        json!([{"id":"aac_160","kind":"lossy"},{"id":"aac_96","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    let run = |request: &Value| -> Value {
        serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap()
    };
    let strict = run(&request);
    assert_eq!(strict["error_type"], "quality_unavailable", "{strict}");
    assert_eq!(strict["diagnostic_cause"], "quality_selection_unavailable");
    request["allow_quality_fallback"] = true.into();
    let result = run(&request);
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["requested_quality"], "LOSSLESS");
    assert_eq!(result["resolved_quality"], "aac_160");
    assert_eq!(result["quality_fallback_used"], true);
    assert_eq!(result["provider"], "example.audio");
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_never_retries_authentication_failure() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "if (quality === 'LOSSLESS') return {success:false,error_type:'auth',error_message:'login required'}; file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["allow_quality_fallback"] = true.into();
    let response: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(response["success"], false, "{response}");
    assert_eq!(response["error_type"], "auth", "{response}");
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_skips_the_effectively_attempted_quality() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "if (quality === 'FLAC') return {success:false,error_type:'quality_unavailable',error_message:'unavailable'}; if (quality !== 'aac_160') throw new Error('unexpected quality'); file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        json!([{"id":"FLAC","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["allow_quality_fallback"] = true.into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["requested_quality"], "LOSSLESS");
    assert_eq!(result["resolved_quality"], "aac_160");
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_cancels_during_second_pass() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "file.writeBytes(outputPath,'SUQzBAAAAAAA'); while(true) {}",
        json!([{"id":"aac_160","kind":"lossy"}]),
    );
    let backend = Arc::new(backend);
    let mut request = container_request(&output, false);
    request["allow_quality_fallback"] = true.into();
    let cancelled = Arc::new(AtomicBool::new(false));
    let flag = cancelled.clone();
    let worker_backend = backend.clone();
    let worker = std::thread::spawn(move || {
        worker_backend.download_by_strategy(&request.to_string(), &|| {
            if flag.load(Ordering::Acquire) {
                Err("cancelled during retry".into())
            } else {
                Ok(())
            }
        })
    });
    let staging = directory.path().join("data/example.audio/downloads");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let found = std::fs::read_dir(&staging)
            .ok()
            .into_iter()
            .flatten()
            .flatten()
            .any(|entry| {
                entry.path().is_dir()
                    && std::fs::read_dir(entry.path())
                        .ok()
                        .into_iter()
                        .flatten()
                        .flatten()
                        .next()
                        .is_some()
            });
        if found {
            break;
        }
        assert!(Instant::now() < deadline, "second pass did not start");
        std::thread::sleep(Duration::from_millis(5));
    }
    cancelled.store(true, Ordering::Release);
    let result = worker.join().unwrap().unwrap();
    assert!(result.contains("cancelled during retry"), "{result}");
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn unavailable_preflight_and_availability_try_fallback() {
    unavailable_preflight_fixture(false);
}

#[test]
fn unavailable_preflight_preserves_availability_verification() {
    unavailable_preflight_fixture(true);
}

fn unavailable_preflight_fixture(verification: bool) {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    for id in ["a.audio", "b.audio"] {
        let source = sources.join(id);
        std::fs::create_dir_all(&source).unwrap();
        let mut manifest = json!({"name":id,"version":"1","description":"test","type":["download_provider"],"permissions":{"file":true,"storage":true,"network":["127.0.0.1"]},"skipMetadataEnrichment":true});
        if id == "a.audio" {
            manifest["signedSession"] = json!({"namespace":"test-unavailable","baseUrl":format!("https://127.0.0.1:{port}"),"appVersion":"1","platform":"extension","endpoints":{"bootstrap":"/bootstrap","challenge":"/challenge","exchange":"/exchange","refresh":"/refresh"}});
        }
        std::fs::write(source.join("manifest.json"), manifest.to_string()).unwrap();
        let script = if id == "a.audio" && verification {
            "registerExtension({checkAvailability(){throw new Error('verification_required: verification required');},download(){throw new Error('must not download');}});"
        } else if id == "a.audio" {
            "registerExtension({checkAvailability(){throw new Error('provider unavailable');},download(){throw new Error('must not download');}});"
        } else {
            "registerExtension({checkAvailability(){return {available:true,track_id:'track'};},download(trackId,quality,outputPath){file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};}});"
        };
        std::fs::write(source.join("index.js"), script).unwrap();
    }
    let backend = Backend::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    for id in ["a.audio", "b.audio"] {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .set_provider_priority("download", vec!["a.audio".into(), "b.audio".into()])
        .unwrap();
    let output = directory.path().join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    let mut request = container_request(&output, false);
    // This fixture exercises availability, not strict quality equivalence.
    // Cross-provider quality loosening is a temporary-playback contract;
    // permanent downloads require proven equivalence (see manifest.rs).
    request["temporary_playback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    request["service"] = "a.audio".into();
    let disabled: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(disabled["success"], false, "{disabled}");
    request["use_fallback"] = true.into();
    if verification {
        backend.set_fallback_providers(Some(vec![])).unwrap();
        let blocked: Value = serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(blocked["error_type"], "verification_required", "{blocked}");
        assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
        backend.set_fallback_providers(None).unwrap();
    }
    let enabled: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(enabled["success"], true, "{enabled}");
    assert_eq!(enabled["provider"], "b.audio");
    backend.shutdown();
}

#[test]
fn verification_does_not_retry_same_provider_as_priority_or_quality() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "let n=storage.get('attempts')||0; storage.set('attempts',n+1); if(n===0) return {success:false,error_type:'verification_required',error_message:'verification required'}; file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["source"] = "example.audio".into();
    request["use_fallback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["error_type"], "verification_required", "{result}");
    assert_eq!(
        backend
            .call("example.audio", "attempts", "[]", None, 1000)
            .unwrap(),
        "1"
    );
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn verification_tries_other_provider_only_when_fallback_enabled() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    for (id, body) in [
        (
            "a.audio",
            "return {success:false,error_type:'verification_required',error_message:'verification required'};",
        ),
        (
            "b.audio",
            "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        ),
    ] {
        let source = sources.join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("manifest.json"), json!({"name":id,"version":"1","description":"test","type":["download_provider"],"permissions":{"file":true},"skipMetadataEnrichment":true}).to_string()).unwrap();
        std::fs::write(source.join("index.js"), format!("registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},download(trackId,quality,outputPath){{{body}}}}});")).unwrap();
    }
    let backend = Backend::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    for id in ["a.audio", "b.audio"] {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .set_provider_priority("download", vec!["a.audio".into(), "b.audio".into()])
        .unwrap();
    let output = directory.path().join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    let mut request = container_request(&output, false);
    // Provider fallback with quality loosening is the temporary-playback path.
    request["temporary_playback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    request["service"] = "a.audio".into();
    let disabled: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        disabled["error_type"], "verification_required",
        "{disabled}"
    );
    request["use_fallback"] = true.into();
    let enabled: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(enabled["success"], true, "{enabled}");
    assert_eq!(enabled["provider"], "b.audio");
    backend.shutdown();
}

#[test]
fn quality_retry_verification_allows_another_provider() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    for (id, second) in [
        (
            "a.audio",
            "return {success:false,error_type:'verification_required',error_message:'verification required'};",
        ),
        (
            "b.audio",
            "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        ),
    ] {
        let source = sources.join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("manifest.json"), json!({"name":id,"version":"1","description":"test","type":["download_provider"],"permissions":{"file":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]}).to_string()).unwrap();
        std::fs::write(source.join("index.js"), format!("registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},download(trackId,quality,outputPath){{if(quality==='LOSSLESS') return {{success:false,error_type:'quality_unavailable',error_message:'quality unavailable'}}; {second}}}}});")).unwrap();
    }
    let backend = Backend::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    for id in ["a.audio", "b.audio"] {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .set_provider_priority("download", vec!["a.audio".into(), "b.audio".into()])
        .unwrap();
    let output = directory.path().join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    let mut request = container_request(&output, false);
    request["service"] = "a.audio".into();
    request["use_fallback"] = true.into();
    // An alternate tier on another provider is only valid for playback.
    request["temporary_playback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["provider"], "b.audio");
    assert_eq!(result["resolved_quality"], "aac_160");
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_retries_quality_candidate_after_other_provider_auth() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    for (id, qualities, body) in [
        (
            "a.audio",
            json!([{"id":"aac_160","kind":"lossy"}]),
            "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        ),
        (
            "b.audio",
            json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
            "if (quality === 'LOSSLESS') return {success:false,error_type:'auth',error_message:'login required'}; file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath,actual_extension:'.mp3'};",
        ),
    ] {
        let source = sources.join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("manifest.json"), json!({"name":id,"version":"1","description":"test","type":["download_provider"],"permissions":{"file":true},"skipMetadataEnrichment":true,"qualityOptions":qualities}).to_string()).unwrap();
        std::fs::write(source.join("index.js"), format!("registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},download(trackId,quality,outputPath){{{body}}}}});")).unwrap();
    }
    let backend = Backend::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    for id in ["a.audio", "b.audio"] {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .set_provider_priority("download", vec!["a.audio".into(), "b.audio".into()])
        .unwrap();
    let output = directory.path().join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    let mut request = container_request(&output, false);
    backend.set_fallback_providers(Some(vec![])).unwrap();
    request["service"] = "b.audio".into();
    request["use_fallback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    let disabled: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(disabled["error_type"], "auth", "{disabled}");
    backend.set_fallback_providers(None).unwrap();
    request["service"] = "a.audio".into();
    request["use_fallback"] = true.into();
    request["allow_quality_fallback"] = true.into();
    let response: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(response["success"], true, "{response}");
    assert_eq!(response["provider"], "a.audio");
    assert_eq!(response["resolved_quality"], "aac_160");
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_respects_explicit_stop_and_cancel() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_availability(
        directory.path(),
        "file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath};",
        json!([{"id":"aac_160","kind":"lossy"}]),
        "return {available:true,track_id:'track',skip_fallback:true};",
    );
    let mut request = container_request(&output, false);
    request["allow_quality_fallback"] = true.into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["success"], false, "{result}");
    assert!(
        text(&result, "error").contains("Fallback stopped"),
        "{result}"
    );
    let cancelled = backend
        .download_by_strategy(&request.to_string(), &|| Err("cancelled by caller".into()))
        .unwrap();
    assert!(cancelled.contains("cancelled by caller"));
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn temporary_quality_fallback_respects_verification() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "if (quality === 'LOSSLESS') return {success:false,error_type:'verification_required',error_message:'verification required'}; file.writeBytes(outputPath,'SUQzBAAAAAAA'); return {success:true,file_path:outputPath};",
        json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"aac_160","kind":"lossy"}]),
    );
    let mut request = container_request(&output, false);
    request["allow_quality_fallback"] = true.into();
    let result: Value = serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["error_type"], "verification_required", "{result}");
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

pub(super) fn container_request(output: &Path, embed_metadata: bool) -> Value {
    json!({"service":"example.audio","provider_track_id":"track",
        "use_extensions":true,"use_fallback":false,"output_dir":output,
        "track_name":"Track","artist_name":"Artist","album_name":"Album",
        "filename_format":"{title}","output_ext":".flac","quality":"LOSSLESS",
        "embed_metadata":embed_metadata,"embed_lyrics":false})
}

#[test]
fn saved_generic_id_never_reuses_cross_provider_or_existing_file_without_proof() {
    for (saved, conflicting, existing, loose) in [(false, false, false, false), (true, false, false, false), (true, true, false, false), (true, false, true, false), (true, false, true, true)] {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        for id in ["a.audio", "b.audio"] {
            let source = sources.join(id);
            std::fs::create_dir_all(&source).unwrap();
            std::fs::write(source.join("manifest.json"), json!({
                "name":id,"version":"1","description":"local fixture",
                "type":["download_provider"],"permissions":{"file":true,"storage":true},
                "skipMetadataEnrichment":true,"qualityOptions":[{"id":"LOSSLESS","kind":if id == "b.audio" && conflicting { "lossy" } else { "lossless" }}]
            }).to_string()).unwrap();
            let body = if id == "a.audio" {
                "return {success:false,error_type:'quality_unavailable',error_message:'quality unavailable'};".to_owned()
            } else {
                format!("file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath,actual_extension:'.flac'}};", json!(REAL_FLAC_BASE64))
            };
            let expected_id = if id == "a.audio" { "track" } else { "other-track" };
            let available = !(existing && id == "a.audio");
            std::fs::write(source.join("index.js"), format!(
                "registerExtension({{checkAvailability(){{return {{available:{available},track_id:'{expected_id}'}};}},download(trackId,quality,outputPath){{storage.set('attempts',(storage.get('attempts')||0)+1); if(trackId !== '{expected_id}') return {{success:false,error_type:'wrong_track'}}; {body}}},attempts(){{return storage.get('attempts')||0;}}}});"
            )).unwrap();
        }
        let backend = Backend::new(&sources, &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", RuntimeLimits::default()).unwrap();
        backend.load_all().unwrap();
        for id in ["a.audio", "b.audio"] { backend.set_enabled(id, true).unwrap(); }
        backend.set_provider_priority("download", vec!["a.audio".into(), "b.audio".into()]).unwrap();
        let output = directory.path().join("output"); std::fs::create_dir_all(&output).unwrap();
        backend.environment().set_allowed_download_directories(std::slice::from_ref(&output)).unwrap();
        if existing { std::fs::write(output.join("Track.flac"), b"existing audio").unwrap(); }
        let mut request = container_request(&output, false);
        request["allow_quality_fallback"] = loose.into();
        request["service"] = "a.audio".into();
        // Direct source attempts bypass availability; leave source unset so the
        // unavailable original is skipped before reaching the fallback provider.
        request["source"] = if existing { "" } else { "a.audio" }.into();
        request["use_fallback"] = true.into(); request["allow_saved_quality_id_fallback"] = saved.into();
        let result: Value = serde_json::from_str(&backend.download_by_strategy(&request.to_string(), &|| Ok(())).unwrap()).unwrap();
        assert_eq!(backend.call("a.audio", "attempts", "[]", None, 1000).unwrap(), if existing { "0" } else { "1" });
        assert_eq!(result["success"], false, "{result}");
        assert_eq!(result["error_type"], "quality_unavailable", "{result}");
        assert_eq!(backend.call("b.audio", "attempts", "[]", None, 1000).unwrap(), "0");
        if existing { assert_eq!(std::fs::read(output.join("Track.flac")).unwrap(), b"existing audio"); }
        backend.shutdown();
    }
}

#[test]
fn strict_local_flac_publication_probes_owned_final_bytes_and_preserves_an_existing_target() {
    // Real 16-bit mono 44100 Hz FLAC silence generated with FFmpeg:
    // -f lavfi -i anullsrc=r=44100:cl=mono -t 0.01 -c:a flac
    // -metadata_header_padding 0 -f flac pipe:1
    let encoded = REAL_FLAC_BASE64;
    let flac = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        &format!(
            "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath}};",
            json!(encoded)
        ),
        json!([{"id":"LOSSLESS","kind":"lossless"}]),
    );
    let request = container_request(&output, false);
    let run = || -> Value {
        serde_json::from_str(
            &backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap()
    };
    let result = run();
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["audio_codec"], "flac", "{result}");
    assert_eq!(std::fs::read(output.join("Track.flac")).unwrap(), flac);
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 1);
    // An existing wrong-quality artifact is never silently replaced.
    std::fs::write(output.join("Track.flac"), b"existing unknown audio").unwrap();
    let result = run();
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(
        std::fs::read(output.join("Track.flac")).unwrap(),
        b"existing unknown audio"
    );
    backend.shutdown();
}

#[test]
fn conflicting_saved_quality_rejects_live_changed_source_before_download() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = container_fixture_with_qualities(
        directory.path(),
        "return {success:false,error_type:'called_provider'};",
        json!([{"id":"LOSSLESS","kind":"lossy","label":"AAC 128 kbps"}]),
    );
    for loose in [false, true] {
    let mut request = container_request(&output, false);
    request["allow_quality_fallback"] = loose.into();
    request["quality_source_provider"] = "example.audio".into();
    request["quality_source_id"] = "LOSSLESS".into();
    request["quality_source_kind"] = "lossless".into();
    request["quality_source_label"] = "FLAC 16-bit 44.1 kHz".into();
    let result: Value = serde_json::from_str(&backend.download_by_strategy(&request.to_string(), &|| Ok(())).unwrap()).unwrap();
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(result["error_type"], "quality_unavailable", "{result}");
    }
    backend.shutdown();
}
