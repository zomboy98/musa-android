//! Permanent-download relay: provider order, equivalent class, class descent
//! and the opt-in strict mode. Providers are synthetic local fixtures.

use super::container_tests::{REAL_FLAC_BASE64, container_request};
use super::*;
use crate::RuntimeLimits;

const UNAVAILABLE: &str =
    "return {success:false,error_type:'quality_unavailable',error_message:'quality unavailable'};";

fn flac() -> String {
    format!(
        "file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath}};",
        json!(REAL_FLAC_BASE64)
    )
}

/// Providers are tried in the given order; the first one is the selected service.
fn relay_fixture(
    directory: &Path,
    providers: &[(&str, Value, &str, String)],
) -> (Backend, std::path::PathBuf) {
    let sources = directory.join("sources");
    for (id, qualities, availability, body) in providers {
        let source = sources.join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("manifest.json"),
            json!({"name":id,"version":"1","description":"relay fixture","type":["download_provider"],
                "permissions":{"file":true,"storage":true},"skipMetadataEnrichment":true,
                "qualityOptions":qualities})
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            source.join("index.js"),
            format!(
                "registerExtension({{checkAvailability(){{{availability}}},
                download(trackId,quality,outputPath){{storage.set('log',(storage.get('log')||'')+quality+';'); {body}}},
                log(){{return storage.get('log')||'';}}}});"
            ),
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
    for (id, ..) in providers {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .set_provider_priority("download", providers.iter().map(|(id, ..)| (*id).to_owned()).collect())
        .unwrap();
    let output = directory.join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    (backend, output)
}

fn relay_request(output: &Path, service: &str, relay: bool) -> Value {
    let mut request = container_request(output, false);
    request["service"] = service.into();
    request["use_fallback"] = true.into();
    request["quality_relay"] = relay.into();
    request
}

fn run(backend: &Backend, request: &Value) -> Value {
    serde_json::from_str(
        &backend
            .download_by_strategy(&request.to_string(), &|| Ok(()))
            .unwrap(),
    )
    .unwrap()
}

fn log(backend: &Backend, id: &str) -> String {
    serde_json::from_str::<String>(&backend.call(id, "log", "[]", None, 1000).unwrap()).unwrap()
}

const AVAILABLE: &str = "return {available:true,track_id:'track'};";

#[test]
fn provider_without_the_quality_relays_to_the_equivalent_tier_of_the_next() {
    for relay in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let (backend, output) = relay_fixture(
            directory.path(),
            &[
                ("a.audio", json!([{"id":"LOSSLESS","label":"Lossless","kind":"lossless"}]), AVAILABLE, UNAVAILABLE.into()),
                ("b.audio", json!([{"id":"low","kind":"lossy"},{"id":"cd","label":"Lossless","kind":"lossless"}]), AVAILABLE, flac()),
            ],
        );
        let result = run(&backend, &relay_request(&output, "a.audio", relay));
        assert_eq!(log(&backend, "a.audio"), "LOSSLESS;");
        if relay {
            assert_eq!(result["success"], true, "{result}");
            // The real provider and the real tier are reported, never the request.
            assert_eq!(result["provider"], "b.audio");
            assert_eq!(result["service"], "b.audio");
            assert_eq!(result["requested_quality"], "LOSSLESS");
            assert_eq!(result["resolved_quality"], "cd");
            assert_eq!(result["quality_fallback_used"], true);
            assert_eq!(result["audio_codec"], "flac");
            assert_eq!(log(&backend, "b.audio"), "cd;");
        } else {
            // Strict mode ("only this quality"): no unproven substitute.
            assert_eq!(result["success"], false, "{result}");
            assert_eq!(result["error_type"], "quality_unavailable", "{result}");
            assert_eq!(log(&backend, "b.audio"), "");
            assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
        }
        backend.shutdown();
    }
}

#[test]
fn provider_without_the_track_relays_to_the_third_provider() {
    let directory = tempfile::tempdir().unwrap();
    let lossless = json!([{"id":"LOSSLESS","kind":"lossless"}]);
    let (backend, output) = relay_fixture(
        directory.path(),
        &[
            ("a.audio", lossless.clone(), AVAILABLE, UNAVAILABLE.into()),
            ("b.audio", lossless.clone(), "return {available:false,reason:'track not found'};", flac()),
            ("c.audio", json!([{"id":"flac","label":"FLAC / Hi-Res"}]), AVAILABLE, flac()),
        ],
    );
    let result = run(&backend, &relay_request(&output, "a.audio", true));
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["provider"], "c.audio");
    assert_eq!(result["resolved_quality"], "flac");
    assert_eq!(log(&backend, "b.audio"), "");
    backend.shutdown();
}

#[test]
fn class_descends_only_after_every_provider_missed_it_and_never_repeats_an_attempt() {
    for relay in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let (backend, output) = relay_fixture(
            directory.path(),
            &[
                (
                    "a.audio",
                    json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"std","kind":"lossy"}]),
                    AVAILABLE,
                    format!("if (quality === 'LOSSLESS') {{{UNAVAILABLE}}} {}", flac()),
                ),
                ("b.audio", json!([{"id":"HI","label":"24-bit","kind":"lossless"}]), AVAILABLE, UNAVAILABLE.into()),
            ],
        );
        let result = run(&backend, &relay_request(&output, "a.audio", relay));
        if relay {
            assert_eq!(result["success"], true, "{result}");
            assert_eq!(result["provider"], "a.audio");
            assert_eq!(result["requested_quality"], "LOSSLESS");
            assert_eq!(result["resolved_quality"], "std");
            assert_eq!(result["quality_fallback_used"], true);
            // a.audio is both the service and first in the priority list:
            // each provider/track/tier is still asked exactly once, and the
            // lossy tier only after b.audio was asked for its lossless one.
            assert_eq!(log(&backend, "a.audio"), "LOSSLESS;std;");
            assert_eq!(log(&backend, "b.audio"), "HI;");
        } else {
            assert_eq!(result["success"], false, "{result}");
            assert_eq!(result["error_type"], "quality_unavailable", "{result}");
            assert_eq!(log(&backend, "a.audio"), "LOSSLESS;");
            assert_eq!(log(&backend, "b.audio"), "");
        }
        backend.shutdown();
    }
}

#[test]
fn quality_is_unavailable_only_after_every_provider_and_class_was_tried() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = relay_fixture(
        directory.path(),
        &[
            ("a.audio", json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"HIGH","kind":"lossy"},{"id":"ATMOS","kind":"spatial"}]), AVAILABLE, UNAVAILABLE.into()),
            ("b.audio", json!([{"id":"best","kind":"lossless"},{"id":"opus","label":"Opus 320kbps","kind":"lossy"}]), AVAILABLE, UNAVAILABLE.into()),
        ],
    );
    let result = run(&backend, &relay_request(&output, "a.audio", true));
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(result["error_type"], "quality_unavailable", "{result}");
    assert!(text(&result, "error").starts_with("All providers failed."), "{result}");
    // Spatial is never offered for a stereo request.
    assert_eq!(log(&backend, "a.audio"), "LOSSLESS;HIGH;");
    assert_eq!(log(&backend, "b.audio"), "best;opus;");
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

#[test]
fn relay_never_bypasses_required_verification() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = relay_fixture(
        directory.path(),
        &[
            (
                "a.audio",
                json!([{"id":"LOSSLESS","kind":"lossless"},{"id":"std","kind":"lossy"}]),
                AVAILABLE,
                "return {success:false,error_type:'verification_required',error_message:'verification required'};".into(),
            ),
            ("b.audio", json!([{"id":"LOSSLESS","kind":"lossless"}]), AVAILABLE, UNAVAILABLE.into()),
        ],
    );
    let result = run(&backend, &relay_request(&output, "a.audio", true));
    assert_eq!(result["success"], false, "{result}");
    // The challenge is surfaced; no other tier is requested behind it.
    assert_eq!(result["error_type"], "verification_required", "{result}");
    assert_eq!(result["service"], "a.audio", "{result}");
    assert_eq!(log(&backend, "a.audio"), "LOSSLESS;");
    assert_eq!(log(&backend, "b.audio"), "LOSSLESS;");
    backend.shutdown();
}

#[test]
fn relayed_tier_is_still_verified_and_encrypted_audio_is_reported_unverified() {
    let directory = tempfile::tempdir().unwrap();
    let lossless = json!([{"id":"LOSSLESS","kind":"lossless"}]);
    let (backend, output) = relay_fixture(
        directory.path(),
        &[
            // Claims lossless but returns bytes that are not audio.
            ("a.audio", lossless.clone(), AVAILABLE, "file.writeBytes(outputPath,'aW52YWxpZCBhdWRpbw=='); return {success:true,file_path:outputPath};".into()),
            ("b.audio", lossless.clone(), AVAILABLE, format!("file.writeBytes(outputPath,{}); return {{success:true,file_path:outputPath,decryption_key:'dummy'}};", json!(REAL_FLAC_BASE64))),
        ],
    );
    let result = run(&backend, &relay_request(&output, "a.audio", true));
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["provider"], "b.audio");
    assert_eq!(result["quality_verification"], "encrypted_unverified", "{result}");
    backend.shutdown();
}

// Streaming: a provider that lacks the format or the track never pins playback.
#[test]
fn streaming_relays_after_quality_unavailable_and_after_not_found() {
    for missing_track in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let availability = if missing_track { "return {available:false,reason:'track not found'};" } else { AVAILABLE };
        let (backend, output) = relay_fixture(
            directory.path(),
            &[
                ("a.audio", json!([{"id":"HIGH","kind":"lossy"}]), availability, UNAVAILABLE.into()),
                ("b.audio", json!([{"id":"cd","label":"Lossless","kind":"lossless"}]), AVAILABLE, flac()),
            ],
        );
        let mut request = relay_request(&output, "a.audio", false);
        request["quality"] = "HIGH".into();
        request["temporary_playback"] = true.into();
        request["allow_quality_fallback"] = true.into();
        // Without automatic fallback the user pinned the provider on purpose.
        request["use_fallback"] = false.into();
        let pinned = run(&backend, &request);
        assert_eq!(pinned["success"], false, "{pinned}");
        assert_eq!(log(&backend, "b.audio"), "");
        request["use_fallback"] = true.into();
        let result = run(&backend, &request);
        assert_eq!(result["success"], true, "{result}");
        assert_eq!(result["provider"], "b.audio");
        assert_eq!(result["resolved_quality"], "cd");
        // One attempt per request (pinned, then relayed): never a repeat.
        assert_eq!(log(&backend, "a.audio"), if missing_track { "" } else { "HIGH;HIGH;" });
        backend.shutdown();
    }
}

#[test]
fn temporary_playback_ignores_the_permanent_relay_flag() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, output) = relay_fixture(
        directory.path(),
        &[
            ("a.audio", json!([{"id":"LOSSLESS","label":"Lossless","kind":"lossless"}]), AVAILABLE, UNAVAILABLE.into()),
            ("b.audio", json!([{"id":"cd","label":"Lossless","kind":"lossless"}]), AVAILABLE, flac()),
        ],
    );
    let mut request = relay_request(&output, "a.audio", true);
    request["temporary_playback"] = true.into();
    let result = run(&backend, &request);
    // Without allow_quality_fallback playback keeps its strict contract.
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(log(&backend, "b.audio"), "");
    backend.shutdown();
}

#[test]
fn la_lista_de_streaming_se_guarda_aparte_y_no_altera_la_de_descargas() {
    let directory = tempfile::tempdir().unwrap();
    let (backend, _output) = relay_fixture(
        directory.path(),
        &[
            ("a.audio", json!([{"id":"cd","kind":"lossless"}]), AVAILABLE, flac()),
            ("b.audio", json!([{"id":"cd","kind":"lossless"}]), AVAILABLE, flac()),
        ],
    );
    let leidas = |backend: &Backend| -> Value {
        serde_json::from_str(&backend.provider_priorities().unwrap()).unwrap()
    };
    assert_eq!(leidas(&backend)["streaming"], json!([]));
    backend
        .set_provider_priority("streaming", vec!["b.audio".into(), "a.audio".into(), "B.audio".into()])
        .unwrap();
    let prioridades = leidas(&backend);
    assert_eq!(prioridades["streaming"], json!(["b.audio", "a.audio"]));
    assert_eq!(prioridades["download"], json!(["a.audio", "b.audio"]));
    assert!(backend.set_provider_priority("desconocida", Vec::new()).is_err());
    backend.shutdown();
}
