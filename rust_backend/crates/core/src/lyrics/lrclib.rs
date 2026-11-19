use super::{LyricsLine, LyricsResponse, lrc, matching};
use serde::Serialize;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LrcLibResponse {
    pub id: isize,
    pub name: String,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration: f64,
    pub instrumental: bool,
    pub plain_lyrics: String,
    pub synced_lyrics: String,
}

crate::json::lenient_deserialize!(LrcLibResponse {
    "id" => id, "name" => name, "trackname" => track_name,
    "artistname" => artist_name, "albumname" => album_name, "duration" => duration,
    "instrumental" => instrumental, "plainlyrics" => plain_lyrics,
    "syncedlyrics" => synced_lyrics,
});

impl LrcLibResponse {
    pub fn track_name(&self) -> &str {
        if self.track_name.trim().is_empty() {
            self.name.trim()
        } else {
            self.track_name.trim()
        }
    }

    pub fn matches(&self, _query: &str, track: &str, artist: &str, duration: f64) -> bool {
        if track.trim().is_empty() || artist.trim().is_empty() {
            return false;
        }
        let timed = matching::known_duration(self.duration) && matching::known_duration(duration);
        if timed && (self.duration - duration).abs() > 2.0 {
            return false;
        }
        let expected = matching::lrclib_title(track, timed);
        let candidate = matching::lrclib_title(self.track_name(), timed);
        !expected.is_empty()
            && expected == candidate
            && if timed {
                matching::lrclib_artists_match(&self.artist_name, artist)
            } else {
                // Without timing evidence, do not broaden featured artists or
                // titles. select() additionally requires a unique candidate.
                let expected = matching::normalize_loose_artist(artist);
                !expected.is_empty()
                    && expected == matching::normalize_loose_artist(&self.artist_name)
            }
    }

    pub fn into_lyrics(&self) -> LyricsResponse {
        let mut result = LyricsResponse {
            instrumental: self.instrumental,
            plain_lyrics: self.plain_lyrics.clone(),
            provider: "LRCLIB".into(),
            ..LyricsResponse::default()
        };
        if !self.synced_lyrics.is_empty() {
            result.lines = lrc::parse_synced(&self.synced_lyrics);
            result.sync_type = "LINE_SYNCED".into();
        } else if !self.plain_lyrics.is_empty() {
            result.sync_type = "UNSYNCED".into();
            let lines: Vec<_> = self
                .plain_lyrics
                .split('\n')
                .filter(|line| !line.trim().is_empty())
                .map(|line| LyricsLine {
                    words: line.into(),
                    ..LyricsLine::default()
                })
                .collect();
            result.lines = (!lines.is_empty()).then_some(lines);
        }
        result.normalize_timing();
        result
    }
}

pub fn select<'a>(
    results: &'a [LrcLibResponse],
    query: &str,
    track: &str,
    artist: &str,
    duration: f64,
) -> Option<&'a LrcLibResponse> {
    let candidates: Vec<_> = results
        .iter()
        .filter(|result| {
            result.matches(query, track, artist, duration)
                && (result.instrumental
                    || !result.synced_lyrics.trim().is_empty()
                    || !result.plain_lyrics.trim().is_empty())
        })
        .collect();
    if !matching::known_duration(duration)
        || candidates
            .iter()
            .any(|result| !matching::known_duration(result.duration))
    {
        return (candidates.len() == 1).then(|| candidates[0]);
    }
    candidates.into_iter().min_by(|a, b| {
        (a.duration - duration)
            .abs()
            .total_cmp(&(b.duration - duration).abs())
            .then_with(|| a.synced_lyrics.is_empty().cmp(&b.synced_lyrics.is_empty()))
    })
}

#[cfg(test)]
mod identity_tests {
    use super::*;

    fn candidate(title: &str, duration: f64) -> LrcLibResponse {
        LrcLibResponse {
            track_name: title.into(),
            artist_name: "Beyoncé".into(),
            duration,
            synced_lyrics: "[00:01]Words".into(),
            ..Default::default()
        }
    }

    #[test]
    fn search_selects_explicit_instrumental_without_text_and_keeps_identity_guards() {
        let mut instrumental = candidate("Song", 240.0);
        instrumental.instrumental = true;
        instrumental.synced_lyrics.clear();
        for duration in [0.0, 240.0] {
            let results = [instrumental.clone()];
            let selected = select(&results, "", "Song", "Beyoncé", duration).unwrap();
            let lyrics = selected.into_lyrics();
            assert!(lyrics.instrumental);
            assert!(lyrics.lines().is_empty());
            assert!(select(&results, "", "Song (Live)", "Beyoncé", duration).is_none());
        }
        assert!(select(&[instrumental.clone()], "", "Song", "Beyoncé", 180.0).is_none());
        let ambiguous = [instrumental, candidate("Song", 240.0)];
        assert!(select(&ambiguous, "", "Song", "Beyoncé", 0.0).is_none());
    }

    #[test]
    fn lrclib_rejects_other_versions_even_with_equal_duration() {
        for version in ["Live", "Acoustic", "Radio Edit", "Single Version", "Remix"] {
            let title = format!("Song ({version})");
            assert!(
                !candidate("Song", 240.0).matches("", &title, "Beyoncé", 240.0),
                "{version}"
            );
            assert!(
                !candidate(&title, 240.0).matches("", "Song", "Beyoncé", 240.0),
                "{version}"
            );
            assert!(
                candidate(&title, 240.0).matches("", &title, "Beyoncé", 240.0),
                "{version}"
            );
        }
    }

    #[test]
    fn lrclib_requires_close_known_duration_and_full_identity() {
        for duration in [180.0, 235.0] {
            assert!(
                !candidate("Song", duration).matches("", "Song", "Beyoncé", 240.0),
                "candidate {duration}"
            );
            assert!(
                !candidate("Song", 240.0).matches("", "Song", "Beyoncé", duration),
                "request {duration}"
            );
        }
        assert!(candidate("Song", 241.0).matches("", "Song", "Beyoncé", 240.0));
        assert!(!candidate("Song", 240.0).matches("Song Beyoncé", "Song", "", 240.0));
        assert!(!candidate("Song", 240.0).matches("Song Beyoncé", "", "", 240.0));
    }

    #[test]
    fn lrclib_unknown_duration_requires_unique_exact_original_identity() {
        for duration in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            let results = [candidate("Song (Live)", 240.0)];
            assert!(select(&results, "", "Song (Live)", "Beyoncé", duration).is_some());
            let ambiguous = [
                candidate("Song (Live)", 240.0),
                candidate("Song (Live)", 180.0),
            ];
            assert!(select(&ambiguous, "", "Song (Live)", "Beyoncé", duration).is_none());
            assert!(select(&results, "", "Song", "Beyoncé", duration).is_none());
        }
        let missing_candidate_time = [candidate("Song", 0.0)];
        assert!(select(&missing_candidate_time, "", "Song", "Beyoncé", 240.0).is_some());
        let featured = [candidate("Song (feat. Guest)", 240.0)];
        assert!(select(&featured, "", "Song", "Beyoncé", 0.0).is_none());
    }

    #[test]
    fn lrclib_preserves_accents_and_benign_featured_artist_decoration() {
        assert!(candidate("Café (feat. Guest)", 240.0).matches("", "Café", "Beyonce", 240.0));
        assert!(candidate("Cafe\u{301}", 240.0).matches("", "Café", "Beyoncé", 240.0));
        assert!(!candidate("Song (Other Remix)", 240.0).matches(
            "",
            "Song (Club Remix)",
            "Beyoncé",
            240.0
        ));
    }

    #[test]
    fn lrclib_preserves_full_band_names_and_explicit_collaborations() {
        for band in ["Florence & the Machine", "Earth, Wind & Fire"] {
            let mut result = candidate("Song", 240.0);
            result.artist_name = band.into();
            assert!(result.matches("", "Song", band, 240.0));
            let solo = band.split([',', '&']).next().unwrap().trim();
            assert!(!result.matches("", "Song", solo, 240.0));
            result.artist_name = solo.into();
            assert!(!result.matches("", "Song", band, 240.0));
        }
        let mut result = candidate("Song", 240.0);
        result.artist_name = "Beyoncé feat. Guest".into();
        assert!(result.matches("", "Song", "Beyonce", 240.0));
        assert!(result.matches("", "Song", "Beyoncé ft. Guest", 240.0));
        assert!(!result.matches("", "Song", "Beyoncé feat. Other", 240.0));
        assert!(!result.matches("", "Song", "Beyoncé", 0.0));
        result.artist_name = "Beyoncé & Guest".into();
        assert!(!result.matches("", "Song", "Beyoncé", 240.0));
    }
}
