//! Pure listening-session accounting. The caller owns clocks, calendar and I/O.

pub const PLAY_THRESHOLD_MS: i64 = 30_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    pub day: String,
    pub milliseconds: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delta {
    pub day: String,
    pub track_key: String,
    pub milliseconds: i64,
    pub plays: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdvanceError {
    NonPositiveDuration,
    SessionOverflow,
}

/// Detached, versioned state. Import validates reachability before use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub version: u8,
    pub track: Option<String>,
    pub playing: bool,
    pub enabled: bool,
    pub session_ms: i64,
    pub counted: bool,
}

#[derive(Debug, Clone)]
pub struct ListeningEngine {
    track_key: Option<String>,
    playing: bool,
    enabled: bool,
    session_ms: i64,
    counted: bool,
}

impl Default for ListeningEngine {
    fn default() -> Self {
        Self {
            track_key: None,
            playing: false,
            enabled: true,
            session_ms: 0,
            counted: false,
        }
    }
}

impl ListeningEngine {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            version: 1,
            track: self.track_key.clone(),
            playing: self.playing,
            enabled: self.enabled,
            session_ms: self.session_ms,
            counted: self.counted,
        }
    }

    pub fn from_snapshot(state: Snapshot) -> Result<Self, &'static str> {
        if state.version != 1
            || state.session_ms < 0
            || state.counted != (state.session_ms >= PLAY_THRESHOLD_MS)
            || (state.track.is_none() && state.session_ms != 0)
        {
            return Err("Invalid listening state");
        }
        Ok(Self {
            track_key: state.track,
            playing: state.playing,
            enabled: state.enabled,
            session_ms: state.session_ms,
            counted: state.counted,
        })
    }

    /// Rejects nonpositive durations even when inactive. When active, checks
    /// the whole batch for session overflow before changing state.
    pub fn advance(&mut self, segments: &[Segment]) -> Result<Vec<Delta>, AdvanceError> {
        if segments.iter().any(|s| s.milliseconds <= 0) {
            return Err(AdvanceError::NonPositiveDuration);
        }
        let Some(track_key) = self
            .track_key
            .as_ref()
            .filter(|_| self.playing && self.enabled)
        else {
            return Ok(Vec::new());
        };
        let mut total = self.session_ms;
        for segment in segments {
            total = total
                .checked_add(segment.milliseconds)
                .ok_or(AdvanceError::SessionOverflow)?;
        }
        let mut session_ms = self.session_ms;
        let mut counted = self.counted;
        let mut deltas = Vec::with_capacity(segments.len());
        for segment in segments {
            session_ms += segment.milliseconds; // checked for the entire batch above
            let plays = i64::from(!counted && session_ms >= PLAY_THRESHOLD_MS);
            counted |= plays == 1;
            deltas.push(Delta {
                day: segment.day.clone(),
                track_key: track_key.clone(),
                milliseconds: segment.milliseconds,
                plays,
            });
        }
        self.session_ms = total;
        self.counted = counted;
        Ok(deltas)
    }

    pub fn update(&mut self, track_key: Option<String>, playing: bool, ended: bool) {
        if self.track_key != track_key || ended {
            self.reset_session();
        }
        self.track_key = track_key;
        self.playing = playing && !ended;
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn reset_session(&mut self) {
        self.session_ms = 0;
        self.counted = false;
    }
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;

    #[test]
    fn snapshots_preserve_opaque_track_keys_of_any_length() {
        let mut engine = ListeningEngine::new();
        engine.update(Some("x".repeat(1025)), true, false);
        let snapshot = engine.snapshot();
        assert_eq!(
            ListeningEngine::from_snapshot(snapshot.clone())
                .unwrap()
                .snapshot(),
            snapshot
        );
    }
}
