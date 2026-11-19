use super::Backend;
use crate::files::ExtensionFiles;
use cap_std::fs::OpenOptions;
use mornye_core::lyrics::{LyricsResponse, config, file, lrc};
use mornye_providers::lyrics::{Check, LyricsError, SearchRequest};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;

/// Native export arguments. Unlike the private JS SDK, file_path is not trimmed.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct LyricsRequest {
    pub spotify_id: String,
    pub track: String,
    pub artist: String,
    pub file_path: String,
    pub duration_ms: i64,
    pub isrc: String,
    pub refresh: bool,
}

#[derive(Default, Serialize)]
struct LrcResult {
    lyrics: String,
    source: String,
    sync_type: String,
    instrumental: bool,
}

impl Backend {
    pub fn embed_lyrics_to_file(
        &self,
        path: &str,
        lyrics: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let fields = BTreeMap::from([
            ("LYRICS".into(), lyrics.into()),
            ("UNSYNCEDLYRICS".into(), lyrics.into()),
        ]);
        self.embed_flac_fields_response(
            path,
            &fields,
            "",
            ("Failed to embed lyrics", "Lyrics embedded successfully"),
            check,
        )
    }

    pub fn get_lyrics_lrc(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        Ok(self
            .lrc_result(request, &check)
            .map_err(|error| error.to_string())?
            .lyrics)
    }

    pub fn get_lyrics_lrc_with_source(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        let result = match self.lrc_result(request, &check) {
            Ok(result) => result,
            Err(LyricsError::NotFound(_)) => {
                check()?;
                LrcResult::default()
            }
            Err(error) => return Err(error.to_string()),
        };
        serde_json::to_string(&result).map_err(|error| error.to_string())
    }

    /// One provider's lyrics, as JSON in the shape of
    /// [`Self::get_lyrics_lrc_with_source`]. Ignores `file_path`.
    pub fn get_lyrics_from_provider(
        &self,
        provider: &str,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        let mut response = self
            .lyrics
            .fetch_from(
                provider,
                SearchRequest {
                    spotify_id: request.spotify_id.clone(),
                    track: request.track.clone(),
                    artist: request.artist.clone(),
                    duration: request.duration_ms as f64 / 1000.0,
                    isrc: request.isrc.clone(),
                    ..SearchRequest::default()
                },
                &check,
            )
            .map_err(|error| error.to_string())?;
        check()?;
        response.normalize_timing();
        let lyrics = render(&response, request);
        serde_json::to_string(&LrcResult {
            instrumental: lrc::is_instrumental_marker(&lyrics),
            lyrics,
            source: response.source.clone(),
            sync_type: response.sync_type.clone(),
        })
        .map_err(|error| error.to_string())
    }

    /// The enabled lyrics providers in priority order, as a JSON array.
    pub fn get_enabled_lyrics_providers_json(&self) -> Result<String, String> {
        let _operation = self.enter()?;
        serde_json::to_string(&self.lyrics.enabled_providers()).map_err(|error| error.to_string())
    }

    fn lrc_result(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<LrcResult, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        if !request.file_path.is_empty() {
            let files = self
                .manager
                .environment()
                .native_files()
                .map_err(LyricsError::Other)?;
            let existing =
                existing(&files, &request.file_path, check).map_err(LyricsError::Cancelled)?;
            return Ok(match existing {
                Some(lyrics) => {
                    let source = lrc::extract_source(&lyrics);
                    LrcResult {
                        source: if source.is_empty() {
                            "Embedded".into()
                        } else {
                            source
                        },
                        sync_type: "EMBEDDED".into(),
                        instrumental: lrc::is_instrumental_marker(&lyrics),
                        lyrics,
                    }
                }
                None => LrcResult::default(),
            });
        }
        let response = self.fetch_lyrics(request, check)?;
        let lyrics = render(&response, request);
        Ok(LrcResult {
            instrumental: lrc::is_instrumental_marker(&lyrics),
            lyrics,
            source: response.source,
            sync_type: response.sync_type,
        })
    }

    pub(super) fn fetch_lyrics(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let mut response = self.lyrics.fetch(
            SearchRequest {
                spotify_id: request.spotify_id.clone(),
                track: request.track.clone(),
                artist: request.artist.clone(),
                duration: request.duration_ms as f64 / 1000.0,
                isrc: request.isrc.clone(),
                refresh: request.refresh,
                ..SearchRequest::default()
            },
            check,
        )?;
        check().map_err(LyricsError::Cancelled)?;
        response.normalize_timing();
        Ok(response)
    }

    pub fn set_lyrics_providers_json(&self, raw: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        let providers = config::decode_providers(raw).map_err(|error| error.to_string())?;
        self.lyrics
            .set_providers(&providers)
            .map_err(|error| error.to_string())
    }

    pub fn get_available_lyrics_providers_json(&self) -> Result<String, String> {
        let _operation = self.enter()?;
        serde_json::to_string(&config::available_providers()).map_err(|error| error.to_string())
    }

    pub fn set_lyrics_fetch_options_json(&self, raw: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        let _settings = self.lyrics_settings.lock().expect("lyrics settings lock");
        let mut options = self.lyrics.options();
        options
            .update_json(raw)
            .map_err(|error| error.to_string())?;
        self.lyrics
            .set_options(options)
            .map_err(|error| error.to_string())
    }

    pub fn fetch_and_save_lyrics(
        &self,
        request: &LyricsRequest,
        output_path: &str,
        check: &Check<'_>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let files = self.manager.environment().native_files()?;
        let previous = if request.file_path.is_empty() {
            None
        } else {
            existing(&files, &request.file_path, &check)?
        };
        let (content, message) = if let Some(content) = previous {
            (
                content,
                format!("Saved LRC from embedded/sidecar to: {output_path}"),
            )
        } else {
            let response = self
                .fetch_lyrics(request, &check)
                .map_err(|error| format!("lyrics not found: {error}"))?;
            if response.instrumental {
                return Err("track is instrumental, no lyrics available".into());
            }
            let content = render(&response, request);
            if content.is_empty() {
                return Err("failed to generate LRC content".into());
            }
            let message = format!(
                "Saved LRC to: {output_path} ({} lines)",
                response.lines().len()
            );
            (content, message)
        };
        let write = || -> Result<(), String> {
            let output = files.resolve_legacy(output_path)?;
            let _output = files.lock(&output, &check)?;
            check()?;
            // Go WriteFile does not create missing parents. Reject symlinks and
            // non-regular destinations before an atomic replacement as well.
            output.native_display()?;
            output.require_parent()?;
            let permissions = match output.open(OpenOptions::new().write(true)) {
                Ok(file) => Some(
                    file.metadata()
                        .map_err(|error| error.to_string())?
                        .permissions(),
                ),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.to_string()),
            };
            let mut stage = output
                .stage_existing_parent()
                .map_err(|error| error.to_string())?;
            if let Some(permissions) = permissions {
                stage
                    .file
                    .set_permissions(permissions)
                    .map_err(|error| error.to_string())?;
            }
            for chunk in content.as_bytes().chunks(16 * 1024) {
                check()?;
                stage
                    .file
                    .write_all(chunk)
                    .map_err(|error| error.to_string())?;
            }
            stage.publish(&check)
        };
        write().map_err(|error| format!("failed to write LRC file: {error}"))?;
        let _ = self
            .manager
            .environment()
            .log_buffer()
            .add("INFO", "Lyrics", &message);
        Ok(())
    }
}

fn render(response: &LyricsResponse, request: &LyricsRequest) -> String {
    let mut text = lrc::with_metadata(response, &request.track, &request.artist);
    if !lrc::has_usable_content(&text) {
        text = response.plain_lyrics.clone();
    }
    if lrc::has_usable_content(&text) && !lrc::is_instrumental_marker(&text) {
        text
    } else if response.instrumental {
        "[instrumental:true]".into()
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mornye_providers::lyrics::{LyricsFetcher, LyricsService};
    use std::sync::Arc;

    struct FailingProvider(LyricsError);

    impl LyricsFetcher for FailingProvider {
        fn fetch(
            &self,
            provider: &str,
            _: &SearchRequest,
            _: &Check<'_>,
        ) -> Result<LyricsResponse, LyricsError> {
            assert_eq!(provider, "lrclib");
            Err(self.0.clone())
        }
    }

    fn backend_with_provider(error: LyricsError) -> (tempfile::TempDir, Backend) {
        let root = tempfile::tempdir().unwrap();
        let sources = root.path().join("sources");
        std::fs::create_dir(&sources).unwrap();
        let mut backend = Backend::new(
            &sources,
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            crate::RuntimeLimits::default(),
        )
        .unwrap();
        backend.lyrics = Arc::new(LyricsService::new(Arc::new(FailingProvider(error))));
        backend.set_lyrics_providers_json(r#"["lrclib"]"#).unwrap();
        (root, backend)
    }

    #[test]
    fn online_miss_is_empty_only_for_combined_lookup_with_source() {
        let (_root, backend) = backend_with_provider(LyricsError::NotFound("fixture miss".into()));
        let request = LyricsRequest {
            track: "Song".into(),
            artist: "Artist".into(),
            ..LyricsRequest::default()
        };
        let check = || Ok(());
        let result = backend
            .get_lyrics_lrc_with_source(&request, &check)
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&result).unwrap(),
            serde_json::json!({"lyrics": "", "source": "", "sync_type": "", "instrumental": false})
        );
        assert!(backend.get_lyrics_lrc(&request, &check).is_err());
        assert!(
            backend
                .get_lyrics_from_provider("lrclib", &request, &check)
                .is_err()
        );
        // A cached miss must still respect cancellation.
        assert!(
            backend
                .get_lyrics_lrc_with_source(&request, &|| Err("cancelled".into()))
                .is_err()
        );
    }

    #[test]
    fn online_unavailability_is_a_lookup_error() {
        let (_root, backend) =
            backend_with_provider(LyricsError::Unavailable("fixture network failure".into()));
        let request = LyricsRequest {
            track: "Song".into(),
            artist: "Artist".into(),
            ..LyricsRequest::default()
        };
        assert!(
            backend
                .get_lyrics_lrc_with_source(&request, &|| Ok(()))
                .is_err()
        );
    }

    #[test]
    fn text_takes_precedence_over_instrumental_flag() {
        let request = LyricsRequest::default();
        let mut lyrics = LyricsResponse::from_text("[00:01.00]Words", "fixture", "fixture");
        lyrics.instrumental = true;
        let rendered = render(&lyrics, &request);
        assert!(rendered.contains("Words"));
        assert!(!lrc::is_instrumental_marker(&rendered));
        lyrics.lines = None;
        lyrics.plain_lyrics.clear();
        assert_eq!(render(&lyrics, &request), "[instrumental:true]");
    }
}

fn existing(
    files: &ExtensionFiles,
    path: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<String>, String> {
    let result = file::extract(
        path,
        &|path| {
            files
                .resolve_legacy(path)?
                .open(OpenOptions::new().read(true))
                .map_err(|error| error.to_string())
        },
        check,
    );
    check()?;
    Ok(result.ok().filter(|text| lrc::has_usable_content(text)))
}
