use mornye_core::downloads::DownloadRequest;
use mornye_core::lyrics::matching::normalize_loose_artist;
use mornye_core::matching::lowercase;
use mornye_core::metadata::reenrich::{self, text};
use mornye_core::resolver::{artists_match, titles_match, track_identity_title};
use mornye_providers::resolver::Check;
use serde_json::{Value, json};
use std::io::{Read, Seek, SeekFrom};

pub(super) fn strict_codec_matches(
    request: &DownloadRequest,
    manifest: &crate::manifest::ExtensionManifest,
    result: &Value,
) -> bool {
    if request.quality.trim().is_empty() {
        return true;
    }
    let option = manifest
        .find_quality(&request.quality)
        .cloned()
        .unwrap_or_else(|| crate::manifest::QualityOption {
            id: request.quality.clone(),
            ..Default::default()
        });
    if crate::manifest::quality_claims_conflict(&option, &option) {
        return false;
    }
    if request.allow_quality_fallback {
        return true;
    }
    let declared = format!("{} {}", option.id, option.label).to_ascii_lowercase();
    let expected = ["opus", "aac", "mp3", "vorbis", "flac", "alac"]
        .into_iter()
        .find(|codec| declared.contains(codec));
    let actual = text(result, "audio_codec").to_ascii_lowercase();
    let Some(expected) = expected else {
        if option.kind.eq_ignore_ascii_case("lossless") || declared.contains("lossless") {
            return matches!(actual.as_str(), "flac" | "alac" | "ape" | "wavpack" | "pcm");
        }
        // Opaque provider IDs still require a successful byte-level codec
        // observation. An unknown quality is not permission to publish garbage.
        return !actual.is_empty();
    };
    if actual != expected && !(expected == "aac" && actual.starts_with("aac")) {
        return false;
    }
    if let Some((codec, depth, sample)) = crate::manifest::quality_signature(&option)
        && matches!(codec, "flac" | "alac")
    {
        return result["bit_depth"].as_u64() == Some(u64::from(depth))
            && result["sample_rate"].as_u64() == Some(u64::from(sample));
    }
    true
}

#[cfg(test)]
mod strict_codec_tests {
    use super::*;

    #[test]
    fn contradictory_kind_cannot_publish_matching_codec() {
        let request = DownloadRequest { quality: "choice".into(), ..Default::default() };
        let mut manifest = crate::manifest::ExtensionManifest { quality_options: vec![crate::manifest::QualityOption {
            id: "choice".into(), label: "AAC 128 kbps".into(), kind: "lossless".into(), ..Default::default()
        }], ..Default::default() };
        assert!(!strict_codec_matches(&request, &manifest, &json!({"audio_codec":"aac"})));
        manifest.quality_options[0].kind.clear();
        assert!(strict_codec_matches(&request, &manifest, &json!({"audio_codec":"aac"})));
    }

    #[test]
    fn descriptor_probe_clears_provider_quality_when_final_bytes_are_unrecognized() {
        use std::io::Write;
        let raw = tempfile::tempfile().unwrap();
        let mut file = cap_std::fs::File::from_std(raw);
        file.write_all(b"truncated or invalid output").unwrap();
        let mut result = json!({"audio_codec":"flac","bit_depth":24,"sample_rate":192000});
        assert_eq!(
            probe_open_file(&mut file, "track.flac", &mut result, false, &|| Ok(())).unwrap(),
            ""
        );
        let request = DownloadRequest {
            quality: "flac".into(),
            ..Default::default()
        };
        assert!(!strict_codec_matches(
            &request,
            &crate::manifest::ExtensionManifest::default(),
            &result
        ));
        assert!(result["sample_rate"].is_null());
        assert!(result["bit_depth"].is_null());
    }

    #[test]
    fn opaque_lossless_kind_rejects_lossy_and_unknown_codec() {
        let request = DownloadRequest {
            quality: "CD".into(),
            ..Default::default()
        };
        let manifest = crate::manifest::ExtensionManifest {
            quality_options: vec![crate::manifest::QualityOption {
                id: "CD".into(),
                kind: "lossless".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(!strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"mp3"})
        ));
        assert!(!strict_codec_matches(&request, &manifest, &json!({})));
        assert!(strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"flac"})
        ));
    }

    #[test]
    fn strict_explicit_flac_checks_actual_depth_and_rate() {
        let request = DownloadRequest {
            quality: "cd".into(),
            ..Default::default()
        };
        let manifest = crate::manifest::ExtensionManifest {
            quality_options: vec![crate::manifest::QualityOption {
                id: "cd".into(),
                label: "FLAC 16-bit 44.1 kHz".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"flac","bit_depth":16,"sample_rate":44100})
        ));
        assert!(!strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"flac","bit_depth":24,"sample_rate":44100})
        ));
        assert!(!strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"flac"})
        ));
    }

    #[test]
    fn explicit_opus_rejects_aac_and_unknown_but_temporary_fallback_remains_permissive() {
        let mut request = DownloadRequest::default();
        request.quality = "opus_320".into();
        let manifest = crate::manifest::ExtensionManifest::default();
        assert!(!strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"aac"})
        ));
        assert!(!strict_codec_matches(&request, &manifest, &json!({})));
        assert!(strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"opus"})
        ));
        request.allow_quality_fallback = true;
        assert!(strict_codec_matches(
            &request,
            &manifest,
            &json!({"audio_codec":"aac"})
        ));
    }
}

pub(super) fn probe_result(
    files: &crate::files::ExtensionFiles,
    result: &mut Value,
    album_pending: bool,
    check: &Check<'_>,
) -> Result<&'static str, String> {
    let path = text(result, "file_path").to_owned();
    let file = files.resolve_legacy(&path)?.open_native_read();
    match file {
        Ok(mut file) => probe_open_file(&mut file, &path, result, album_pending, check),
        Err(_) => {
            for key in ["audio_codec", "bit_depth", "sample_rate", "bitrate"] {
                result[key] = Value::Null;
            }
            check()?;
            Ok("")
        }
    }
}

/// Probe the held staging descriptor, never reopen a provider-controlled path.
pub(super) fn probe_open_file(
    file: &mut cap_std::fs::File,
    path: &str,
    result: &mut Value,
    album_pending: bool,
    check: &Check<'_>,
) -> Result<&'static str, String> {
    for key in ["audio_codec", "bit_depth", "sample_rate", "bitrate"] {
        result[key] = Value::Null;
    }
    let mut container = "";
    if file.seek(SeekFrom::Start(0)).is_ok() {
        // Provider labels may disagree with the bytes, which decide the
        // published suffix. Quality is probed only for FLAC/MP4. Missing
        // album folders may use tags from any supported container,
        // including undecoded audio.
        container = mornye_core::tags::sniff_container(file).unwrap_or_default();
        let quality = !container.is_empty();
        // Do not treat the provider's declared codec as a byte-level probe.
        if !container.is_empty() {
            result["actual_container"] = container.into();
        }
        let album = album_pending && text(result, "album").trim().is_empty();
        if (quality || album)
            && file.seek(SeekFrom::Start(0)).is_ok()
            && let Ok(metadata) = mornye_core::tags::read_file_metadata(file, path, "", check)
        {
            if quality {
                for key in ["bit_depth", "sample_rate", "audio_codec", "bitrate"] {
                    result[key] = metadata[key].clone();
                }
            }
            if album {
                result["album"] = text(&metadata, "album").trim().into();
            }
        }
        // The generic metadata reader treats every Ogg stream as Opus, so
        // identify its codec from the stream header rather than its suffix.
        if matches!(container, "ogg" | "opus") && file.seek(SeekFrom::Start(0)).is_ok() {
            let mut header = vec![0; 65536];
            let count = file.read(&mut header).unwrap_or(0);
            let header = &header[..count];
            result["audio_codec"] = if header.windows(8).any(|w| w == b"OpusHead") {
                "opus"
            } else if header.windows(7).any(|w| w == b"\x01vorbis") {
                "vorbis"
            } else {
                ""
            }
            .into();
        }
    }
    check()?;
    Ok(container)
}

pub(super) fn matches_track(request: &DownloadRequest, result: &Value, skip_names: bool) -> bool {
    let exact = !request.isrc.is_empty()
        && !text(result, "isrc").is_empty()
        && request
            .isrc
            .trim()
            .eq_ignore_ascii_case(text(result, "isrc").trim());
    let identity = reenrich::Request {
        track_name: request.track_name.clone(),
        artist_name: request.artist_name.clone(),
        isrc: request.isrc.clone(),
        duration_ms: request.duration_ms,
        ..Default::default()
    };
    let mut candidate = result.clone();
    candidate["name"] = result.get("title").cloned().unwrap_or(json!(""));
    candidate["artists"] = result.get("artist").cloned().unwrap_or(json!(""));
    // Skipping names does not permit truncated previews or a duration mismatch.
    if skip_names && request.duration_ms / 1000 <= 0 {
        return true;
    }
    if skip_names
        && (result["duration_ms"].as_i64().unwrap_or_default() / 1000 <= 0
            || (request.duration_ms / 1000)
                .abs_diff(result["duration_ms"].as_i64().unwrap_or_default() / 1000)
                <= 10)
    {
        return true;
    }
    if !identity.verified(&candidate) {
        return false;
    }
    if !exact
        && !skip_names
        && !request.album_name.is_empty()
        && !text(result, "album").is_empty()
        && !titles_match(&request.album_name, text(result, "album"))
    {
        if !request.isrc.is_empty() && !text(result, "isrc").is_empty() {
            return false;
        }
        return strong_identity(request, result);
    }
    true
}

pub(super) fn exact_identity(expected: &str, found: &str, normalize: fn(&str) -> String) -> bool {
    let (left, right) = (normalize(expected), normalize(found));
    if !left.is_empty() && !right.is_empty() {
        left == right
    } else {
        lowercase(expected.trim()) == lowercase(found.trim())
    }
}

pub(super) fn duration_matches(request: &DownloadRequest, track: &Value) -> bool {
    let expected = request.duration_ms / 1000;
    let actual = track["duration_ms"].as_i64().unwrap_or_default() / 1000;
    expected > 0 && actual > 0 && expected.abs_diff(actual) <= 10
}

pub(super) fn strong_identity(request: &DownloadRequest, track: &Value) -> bool {
    let title = text(track, "title");
    let artist = text(track, "artist");
    !request.track_name.is_empty()
        && !title.is_empty()
        && !request.artist_name.is_empty()
        && !artist.is_empty()
        && exact_identity(&request.track_name, title, track_identity_title)
        && (exact_identity(&request.artist_name, artist, normalize_loose_artist)
            || (artists_match(&request.artist_name, artist) && duration_matches(request, track)))
}
