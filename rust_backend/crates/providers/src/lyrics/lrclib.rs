use super::{Check, LyricsError, LyricsFetcher, SearchRequest};
use mornye_core::app_version::AppVersion;
use mornye_core::lyrics::{LyricsResponse, decode_response, errors, lrclib, matching};
use mornye_network::{HttpRequest, NetworkService, NetworkSession};
use serde::de::DeserializeOwned;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use url::Url;

const RATE_LIMIT: &str = "LRCLIB rate limited";
type Cooldown = Arc<Mutex<Option<Instant>>>;
static COOLDOWNS: OnceLock<Mutex<BTreeMap<String, Cooldown>>> = OnceLock::new();
static REQUEST_GATES: OnceLock<Mutex<BTreeMap<String, Cooldown>>> = OnceLock::new();
const REQUEST_SPACING: Duration = Duration::from_millis(200);

struct RequestSlot<'a>(std::sync::MutexGuard<'a, Option<Instant>>);

impl Drop for RequestSlot<'_> {
    fn drop(&mut self) {
        *self.0 = Some(Instant::now() + REQUEST_SPACING);
    }
}

fn request_gate(endpoint: &Url) -> Cooldown {
    let mut entries = REQUEST_GATES
        .get_or_init(Mutex::default)
        .lock()
        .expect("LRCLIB gates lock");
    entries.retain(|_, entry| {
        Arc::strong_count(entry) > 1
            || entry
                .try_lock()
                .map_or(true, |gate| gate.is_some_and(|next| Instant::now() < next))
    });
    entries
        .entry(endpoint.origin().ascii_serialization())
        .or_insert_with(|| Arc::new(Mutex::new(None)))
        .clone()
}

fn cooldown(endpoint: &Url) -> Cooldown {
    let mut entries = COOLDOWNS
        .get_or_init(Mutex::default)
        .lock()
        .expect("LRCLIB origins lock");
    let now = Instant::now();
    entries.retain(|_, entry| {
        Arc::strong_count(entry) > 1
            || entry
                .lock()
                .expect("LRCLIB cooldown lock")
                .is_some_and(|expiry| now < expiry)
    });
    entries
        .entry(endpoint.origin().ascii_serialization())
        .or_insert_with(|| Arc::new(Mutex::new(None)))
        .clone()
}

fn retry_after(value: Option<&str>, now: SystemTime) -> Duration {
    value
        .and_then(|v| {
            let v = v.trim();
            v.parse::<u64>().ok().map(Duration::from_secs).or_else(|| {
                httpdate::parse_http_date(v)
                    .ok()
                    .map(|date| date.duration_since(now).unwrap_or_default())
            })
        })
        .unwrap_or(Duration::from_secs(60))
}

fn rate_limited(
    status: u16,
    headers: &BTreeMap<String, Vec<String>>,
    now: Instant,
    wall: SystemTime,
    lock: &Mutex<Option<Instant>>,
) -> bool {
    if status != 429 {
        return false;
    }
    let value = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("retry-after"))
        .and_then(|(_, values)| values.first())
        .map(String::as_str);
    let duration = retry_after(value, wall);
    let deadline = now
        .checked_add(duration)
        .unwrap_or_else(|| now + Duration::from_secs(315360000));
    let mut expiry = lock.lock().expect("LRCLIB cooldown lock");
    *expiry = Some(expiry.map_or(deadline, |old| old.max(deadline)));
    true
}

pub struct LrcLibClient {
    session: Arc<NetworkSession>,
    endpoint: Url,
    user_agent: AppVersion,
    cooldown: Arc<Mutex<Option<Instant>>>,
    request_gate: Cooldown,
    #[cfg(test)]
    fixture: Option<Box<Fixture>>,
    #[cfg(test)]
    response_fixture: Option<Box<dyn Fn() -> mornye_network::HttpResponse + Send + Sync>>,
}

#[cfg(test)]
type Fixture = dyn Fn(&str, &[(&str, &str)]) -> Result<Vec<u8>, LyricsError> + Send + Sync;

impl LrcLibClient {
    pub fn new(network: &Arc<NetworkService>, user_agent: impl Into<AppVersion>) -> Self {
        Self::with_endpoint(network, "https://lrclib.net", user_agent)
            .expect("built-in LRCLIB endpoint")
    }

    /// Native configuration only; JavaScript cannot choose provider endpoints.
    pub fn with_endpoint(
        network: &Arc<NetworkService>,
        endpoint: &str,
        user_agent: impl Into<AppVersion>,
    ) -> Result<Self, LyricsError> {
        let endpoint =
            Url::parse(endpoint).map_err(|error| LyricsError::Other(error.to_string()))?;
        if endpoint.scheme() != "https"
            || endpoint.host_str().is_none()
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
        {
            return Err(LyricsError::Other(
                "LRCLIB requires an HTTPS endpoint without credentials".into(),
            ));
        }
        let cooldown = cooldown(&endpoint);
        let request_gate = request_gate(&endpoint);
        Ok(Self {
            session: network.native_session(Duration::from_secs(15)),
            endpoint,
            user_agent: user_agent.into(),
            cooldown,
            request_gate,
            #[cfg(test)]
            fixture: None,
            #[cfg(test)]
            response_fixture: None,
        })
    }

    fn get<T: DeserializeOwned>(
        &self,
        path: &str,
        parameters: &[(&str, &str)],
        check: &Check<'_>,
    ) -> Result<T, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        if tokio::runtime::Handle::try_current().is_ok() {
            return Err(LyricsError::Other(
                "blocking HTTP host called from async executor".into(),
            ));
        }
        // Serialize requests per origin, including across separate clients. Poll
        // while waiting so callers can cancel without waiting for the network.
        let gate = loop {
            check().map_err(LyricsError::Cancelled)?;
            match self.request_gate.try_lock() {
                Ok(gate) => break gate,
                Err(std::sync::TryLockError::WouldBlock) => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err(LyricsError::Other("LRCLIB request gate poisoned".into()));
                }
            }
        };
        while let Some(next) = *gate {
            let remaining = next.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            check().map_err(LyricsError::Cancelled)?;
            std::thread::sleep(remaining.min(Duration::from_millis(20)));
        }
        check().map_err(LyricsError::Cancelled)?;
        if self
            .cooldown
            .lock()
            .expect("LRCLIB cooldown lock")
            .is_some_and(|expiry| Instant::now() < expiry)
        {
            return Err(LyricsError::Unavailable(RATE_LIMIT.into()));
        }
        let _slot = RequestSlot(gate);
        #[cfg(test)]
        if let Some(fixture) = &self.fixture {
            return decode_response(&fixture(path, parameters)?)
                .map_err(|error| LyricsError::Other(error.to_string()));
        }
        let mut url = self.endpoint.clone();
        url.set_path(path);
        url.set_query(None);
        url.set_fragment(None);
        url.query_pairs_mut()
            .extend_pairs(parameters.iter().copied());
        self.session
            .validate_url(url.as_str())
            .map_err(LyricsError::Other)?;
        #[cfg(test)]
        let response = if let Some(fixture) = &self.response_fixture {
            Some(fixture())
        } else {
            None
        };
        #[cfg(not(test))]
        let response: Option<mornye_network::HttpResponse> = None;
        let response = if let Some(response) = response {
            response
        } else {
            self.session
                .request(
                    HttpRequest {
                        url: url.into(),
                        method: "GET".into(),
                        body: String::new(),
                        headers: BTreeMap::new(),
                        default_json: false,
                        user_agent: {
                            let version = self.user_agent.get();
                            let version = if version.is_empty() {
                                "unknown"
                            } else {
                                version.as_str()
                            };
                            let contact = option_env!("MUSA_LRCLIB_CONTACT").unwrap_or("").trim();
                            if contact.is_empty() {
                                format!("MUSA/{version}")
                            } else {
                                format!("MUSA/{version} ({contact})")
                            }
                        },
                    },
                    check,
                )
                .map_err(|error| {
                    if let Err(cancelled) = check() {
                        return LyricsError::Cancelled(cancelled);
                    }
                    if error == "network policy changed" {
                        return LyricsError::Cancelled(error);
                    }
                    if error.starts_with("response body exceeds ")
                        || error.starts_with("invalid ")
                        || error == "blocking HTTP host called from async executor"
                    {
                        LyricsError::Other(format!("failed to fetch lyrics: {error}"))
                    } else {
                        LyricsError::Unavailable(format!("failed to fetch lyrics: {error}"))
                    }
                })?
        };
        let limited = rate_limited(
            response.status,
            &response.headers,
            Instant::now(),
            SystemTime::now(),
            &self.cooldown,
        );
        check().map_err(LyricsError::Cancelled)?;
        if limited {
            return Err(LyricsError::Unavailable(RATE_LIMIT.into()));
        }
        if response.status == 404 {
            return Err(LyricsError::NotFound("lyrics not found".into()));
        }
        if response.status != 200 {
            return Err(LyricsError::classified(
                errors::http_status(response.status),
                format!("unexpected status code: {}", response.status),
            ));
        }
        let result = decode_response(&response.body).map_err(|error| {
            let message = format!("failed to decode response: {error}");
            // Go's streaming decoder reports a truncated JSON value as
            // io.ErrUnexpectedEOF, which its connectivity classifier cools down.
            // An entirely empty body instead produces io.EOF and remains Other.
            if error.is_eof()
                && response
                    .body
                    .iter()
                    .any(|byte| !matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
            {
                LyricsError::Unavailable(message)
            } else {
                LyricsError::Other(message)
            }
        });
        check().map_err(LyricsError::Cancelled)?;
        result
    }

    pub fn metadata(
        &self,
        artist: &str,
        track: &str,
        expected: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        // /get exposes one result, so without duration it cannot establish
        // uniqueness. Fall through to /search and inspect its returned candidates.
        if !matching::known_duration(expected.duration) {
            return Err(LyricsError::NotFound(
                "LRCLIB requires a unique search result without duration".into(),
            ));
        }
        let duration = expected.duration.to_string();
        let response: lrclib::LrcLibResponse = self.get(
            "/api/get",
            &[
                ("artist_name", artist),
                ("track_name", track),
                ("duration", &duration),
            ],
            check,
        )?;
        if !matching::known_duration(response.duration)
            || !response.matches("", &expected.track, &expected.artist, expected.duration)
        {
            return Err(LyricsError::NotFound(
                "LRCLIB returned mismatched track metadata".into(),
            ));
        }
        Ok(response.into_lyrics())
    }

    pub fn search(
        &self,
        query: &str,
        track: &str,
        artist: &str,
        duration: f64,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let results: Option<Vec<lrclib::LrcLibResponse>> =
            self.get("/api/search", &[("q", query)], check)?;
        let results = results.unwrap_or_default();
        if results.is_empty() {
            return Err(LyricsError::NotFound("no lyrics found".into()));
        }
        lrclib::select(&results, query, track, artist, duration)
            .map(lrclib::LrcLibResponse::into_lyrics)
            .ok_or_else(|| LyricsError::NotFound("no matching lyrics found".into()))
    }

    pub fn fetch_lyrics(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        if tokio::runtime::Handle::try_current().is_ok() {
            return Err(LyricsError::Other(
                "blocking HTTP host called from async executor".into(),
            ));
        }
        let primary = matching::lrclib_primary_artist(&request.artist);
        let simplified = matching::lrclib_title(&request.track, true);
        let mut metadata = vec![(primary, request.track.as_str(), "LRCLIB")];
        if primary != request.artist {
            metadata.push((&request.artist, &request.track, "LRCLIB"));
        }
        if simplified != request.track {
            metadata.push((primary, &simplified, "LRCLIB (simplified)"));
        }
        let mut lookup_failed = false;
        for (artist, track, source) in metadata {
            let result = self.metadata(artist, track, request, check);
            if let Some(lyrics) = accepted(result, source, &mut lookup_failed)? {
                return Ok(lyrics);
            }
        }
        let mut searches = vec![(request.track.as_str(), "LRCLIB Search")];
        if simplified != request.track {
            searches.push((&simplified, "LRCLIB Search (simplified)"));
        }
        for (track, source) in searches {
            let result = self.search(
                &format!("{primary} {track}"),
                &request.track,
                &request.artist,
                request.duration,
                check,
            );
            if let Some(lyrics) = accepted(result, source, &mut lookup_failed)? {
                return Ok(lyrics);
            }
        }
        if lookup_failed {
            Err(LyricsError::Other("LRCLIB: lyrics lookup failed".into()))
        } else {
            Err(LyricsError::NotFound("LRCLIB: no lyrics found".into()))
        }
    }
}

fn accepted(
    result: Result<LyricsResponse, LyricsError>,
    source: &str,
    lookup_failed: &mut bool,
) -> Result<Option<LyricsResponse>, LyricsError> {
    match result {
        Ok(mut lyrics) if !lyrics.lines().is_empty() || lyrics.instrumental => {
            lyrics.source = source.into();
            Ok(Some(lyrics))
        }
        Err(error @ (LyricsError::Unavailable(_) | LyricsError::Cancelled(_))) => Err(error),
        Err(LyricsError::Other(_)) => {
            *lookup_failed = true;
            Ok(None)
        }
        _ => Ok(None),
    }
}

impl LyricsFetcher for LrcLibClient {
    fn fetch(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        if provider != "lrclib" {
            return Err(LyricsError::Other(format!("unknown provider: {provider}")));
        }
        self.fetch_lyrics(request, check)
    }
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn request_gate_is_shared_by_origin_and_wait_is_cancellable() {
        let network = NetworkService::new().unwrap();
        let first =
            LrcLibClient::with_endpoint(&network, "https://gate.example/a", "test").unwrap();
        let second =
            LrcLibClient::with_endpoint(&network, "https://gate.example/b", "test").unwrap();
        assert!(Arc::ptr_eq(&first.request_gate, &second.request_gate));
        let held = first.request_gate.lock().unwrap();
        let (waiting, observed) = std::sync::mpsc::channel();
        let cancelled = std::sync::atomic::AtomicBool::new(false);
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| {
                let checks = std::sync::atomic::AtomicUsize::new(0);
                second.fetch_lyrics(&request("Song", 240.0), &|| {
                    // The fourth check occurs after the first failed try_lock.
                    if checks.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 3 {
                        waiting.send(()).unwrap();
                    }
                    if cancelled.load(std::sync::atomic::Ordering::SeqCst) {
                        Err("cancelled".into())
                    } else {
                        Ok(())
                    }
                })
            });
            let signalled = observed.recv_timeout(Duration::from_secs(2));
            cancelled.store(true, std::sync::atomic::Ordering::SeqCst);
            drop(held);
            let result = waiter.join().unwrap();
            assert!(signalled.is_ok(), "waiter did not reach the contended gate");
            assert!(matches!(result, Err(LyricsError::Cancelled(_))));
        });
    }

    fn release_after_signal(
        signal: &std::sync::mpsc::Receiver<()>,
        release: &(Mutex<bool>, std::sync::Condvar),
    ) -> Result<(), std::sync::mpsc::RecvTimeoutError> {
        let result = signal.recv_timeout(Duration::from_secs(2));
        let (lock, ready) = release;
        *lock.lock().unwrap() = true;
        ready.notify_all();
        result
    }

    #[test]
    fn missing_signal_still_releases_fixture() {
        let (sender, receiver) = std::sync::mpsc::channel();
        drop(sender);
        let release = (Mutex::new(false), std::sync::Condvar::new());
        assert!(release_after_signal(&receiver, &release).is_err());
        assert!(*release.0.lock().unwrap());
    }

    #[test]
    fn requests_are_serialized_and_spaced_after_error() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let network = NetworkService::new().unwrap();
        let mut client =
            LrcLibClient::with_endpoint(&network, "https://serial-fixture.example", "test")
                .unwrap();
        let active = Arc::new(AtomicUsize::new(0));
        let calls = Arc::new(AtomicUsize::new(0));
        let observed_calls = AtomicUsize::new(0);
        let times = Arc::new(Mutex::new(Vec::new()));
        let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (waiting_tx, waiting_rx) = std::sync::mpsc::channel();
        let fixture_active = active.clone();
        let fixture_calls = calls.clone();
        let fixture_times = times.clone();
        let fixture_release = release.clone();
        client.fixture = Some(Box::new(move |_, _| {
            assert_eq!(fixture_active.fetch_add(1, Ordering::SeqCst), 0);
            let call = fixture_calls.fetch_add(1, Ordering::SeqCst);
            fixture_times.lock().unwrap().push(Instant::now());
            if call == 0 {
                entered_tx.send(()).unwrap();
                let (lock, ready) = &*fixture_release;
                let guard = lock.lock().unwrap();
                let (guard, _) = ready
                    .wait_timeout_while(guard, Duration::from_secs(3), |released| !*released)
                    .unwrap();
                drop(guard);
                fixture_times.lock().unwrap().push(Instant::now());
            }
            fixture_active.fetch_sub(1, Ordering::SeqCst);
            Err(LyricsError::Unavailable("fixture error".into()))
        }));
        std::thread::scope(|scope| {
            let first = scope.spawn(|| client.fetch_lyrics(&request("First", 240.0), &|| Ok(())));
            let entered = entered_rx.recv_timeout(Duration::from_secs(2));
            let second = scope.spawn(|| {
                let checks = AtomicUsize::new(0);
                client.fetch_lyrics(&request("Second", 240.0), &|| {
                    if checks.fetch_add(1, Ordering::SeqCst) == 3 {
                        observed_calls.store(calls.load(Ordering::SeqCst), Ordering::SeqCst);
                        waiting_tx.send(()).unwrap();
                    }
                    Ok(())
                })
            });
            let waiting = release_after_signal(&waiting_rx, &release);
            let first_result = first.join().unwrap();
            let second_result = second.join().unwrap();
            assert!(entered.is_ok(), "first fixture did not start");
            assert!(
                waiting.is_ok(),
                "second request did not reach the contended gate"
            );
            assert_eq!(observed_calls.load(Ordering::SeqCst), 1);
            assert!(matches!(first_result, Err(LyricsError::Unavailable(_))));
            assert!(matches!(second_result, Err(LyricsError::Unavailable(_))));
        });
        let times = times.lock().unwrap();
        assert_eq!(times.len(), 3);
        assert!(times[2].duration_since(times[1]) >= REQUEST_SPACING);
    }

    #[test]
    fn request_slot_releases_and_sets_spacing_on_error() {
        let gate = Mutex::new(None);
        let before = Instant::now();
        let result: Result<(), ()> = (|| {
            let _slot = RequestSlot(gate.lock().unwrap());
            Err(())
        })();
        assert!(result.is_err());
        let after = Instant::now();
        let deadline = gate.try_lock().unwrap().unwrap();
        assert!(deadline >= before + REQUEST_SPACING && deadline <= after + REQUEST_SPACING);
        assert_eq!(REQUEST_SPACING, Duration::from_millis(200));
    }

    #[test]
    fn rate_limit_survives_cancellation_after_response() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let network = NetworkService::new().unwrap();
        let mut first =
            LrcLibClient::with_endpoint(&network, "https://cancel-429.example", "test").unwrap();
        let second =
            LrcLibClient::with_endpoint(&network, "https://cancel-429.example", "test").unwrap();
        let cancelled = Arc::new(AtomicBool::new(false));
        let fixture_cancelled = cancelled.clone();
        first.response_fixture = Some(Box::new(move || {
            fixture_cancelled.store(true, Ordering::SeqCst);
            mornye_network::HttpResponse {
                status: 429,
                status_text: "Too Many Requests".into(),
                url: String::new(),
                headers: BTreeMap::from([("Retry-After".into(), vec!["300".into()])]),
                body: Vec::new(),
            }
        }));
        let result = first.fetch_lyrics(&request("Song", 240.0), &|| {
            if cancelled.load(Ordering::SeqCst) {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert!(matches!(result, Err(LyricsError::Cancelled(_))));
        assert!(
            second
                .cooldown
                .lock()
                .unwrap()
                .unwrap()
                .saturating_duration_since(Instant::now())
                > Duration::from_secs(299)
        );
        *second.request_gate.lock().unwrap() = None; // avoid a real delay in the fixture
        assert!(matches!(
            second.fetch_lyrics(&request("Song", 240.0), &|| Ok(())),
            Err(LyricsError::Unavailable(_))
        ));
    }

    #[test]
    fn async_executor_is_rejected_before_waiting_for_gate() {
        let network = NetworkService::new().unwrap();
        let client =
            LrcLibClient::with_endpoint(&network, "https://async-gate.example", "test").unwrap();
        let _held = client.request_gate.lock().unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let result =
            runtime.block_on(async { client.fetch_lyrics(&request("Song", 240.0), &|| Ok(())) });
        assert!(
            matches!(result, Err(LyricsError::Other(message)) if message.contains("async executor"))
        );
    }

    fn request(track: &str, duration: f64) -> SearchRequest {
        SearchRequest {
            track: track.into(),
            artist: "Artist".into(),
            duration,
            ..Default::default()
        }
    }

    fn response(track: &str, duration: f64) -> serde_json::Value {
        serde_json::json!({"trackName": track, "artistName": "Artist", "duration": duration,
            "syncedLyrics": "[00:01.00]Fixture lyrics"})
    }

    fn client(
        fixture: impl Fn(&str, &[(&str, &str)]) -> Result<Vec<u8>, LyricsError> + Send + Sync + 'static,
    ) -> LrcLibClient {
        let network = NetworkService::new().unwrap();
        let mut client = LrcLibClient::new(&network, "test");
        client.fixture = Some(Box::new(fixture));
        client
    }

    #[test]
    fn failed_lookup_is_an_error_if_search_does_not_recover() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        for status in [200, 403] {
            for recovered in [false, true] {
                let network = NetworkService::new().unwrap();
                let mut client = LrcLibClient::new(&network, "test");
                let calls = Arc::new(AtomicUsize::new(0));
                let observed = calls.clone();
                client.response_fixture = Some(Box::new(move || {
                    let (status, body) = match observed.fetch_add(1, Ordering::SeqCst) {
                        0 => (status, b"{\"duration\":\"private fixture\"}".to_vec()),
                        1 if recovered => (
                            200,
                            serde_json::to_vec(&vec![response("Song", 240.0)]).unwrap(),
                        ),
                        1 => (404, Vec::new()),
                        _ => panic!("unexpected query after search"),
                    };
                    mornye_network::HttpResponse {
                        status,
                        status_text: String::new(),
                        url: "https://lrclib.net/api/get".into(),
                        headers: BTreeMap::new(),
                        body,
                    }
                }));
                let result = client.fetch_lyrics(&request("song", 240.0), &|| Ok(()));
                assert_eq!(calls.load(Ordering::SeqCst), 2);
                if recovered {
                    assert_eq!(result.unwrap().source, "LRCLIB Search");
                } else {
                    let error = result.unwrap_err();
                    assert!(matches!(error, LyricsError::Other(_)), "{error:?}");
                    assert!(!error.to_string().contains("private fixture"));
                }
            }
        }
    }

    #[test]
    fn search_returns_instrumental_and_stops_after_first_match() {
        for duration in [0.0, 240.0] {
            let paths = Arc::new(Mutex::new(Vec::new()));
            let observed = paths.clone();
            let client = client(move |path, _| {
                observed.lock().unwrap().push(path.to_string());
                if path == "/api/get" {
                    return Err(LyricsError::NotFound("fixture".into()));
                }
                Ok(serde_json::to_vec(&serde_json::json!([{
                    "trackName": "Song", "artistName": "Artist", "duration": 240.0,
                    "instrumental": true, "plainLyrics": null, "syncedLyrics": null
                }]))
                .unwrap())
            });
            let result = client
                .fetch_lyrics(&request("Song", duration), &|| Ok(()))
                .unwrap();
            assert!(result.instrumental);
            assert!(result.lines().is_empty());
            assert_eq!(result.source, "LRCLIB Search");
            assert_eq!(
                paths
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|p| *p == "/api/search")
                    .count(),
                1
            );
        }
    }

    #[test]
    fn retry_after_honours_delta_and_http_date_without_waiting() {
        let lock = Mutex::new(None);
        let now = Instant::now();
        let wall = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut headers = BTreeMap::new();
        headers.insert("Retry-After".into(), vec!["180".into()]);
        assert!(rate_limited(429, &headers, now, wall, &lock));
        assert_eq!(*lock.lock().unwrap(), Some(now + Duration::from_secs(180)));
        headers.insert(
            "Retry-After".into(),
            vec![httpdate::fmt_http_date(wall + Duration::from_secs(240))],
        );
        assert!(rate_limited(429, &headers, now, wall, &lock));
        assert_eq!(*lock.lock().unwrap(), Some(now + Duration::from_secs(240)));
        assert!(!rate_limited(200, &headers, now, wall, &lock));
    }

    #[test]
    fn cooldown_is_shared_only_for_equivalent_origins() {
        let network = NetworkService::new().unwrap();
        let a =
            LrcLibClient::with_endpoint(&network, "https://LIMIT-A.example/path", "test").unwrap();
        let same =
            LrcLibClient::with_endpoint(&network, "https://limit-a.example:443/other", "test")
                .unwrap();
        let other =
            LrcLibClient::with_endpoint(&network, "https://limit-b.example", "test").unwrap();
        assert!(Arc::ptr_eq(&a.cooldown, &same.cooldown));
        assert!(!Arc::ptr_eq(&a.cooldown, &other.cooldown));
        let headers = BTreeMap::from([("Retry-After".into(), vec!["300".into()])]);
        assert!(rate_limited(
            429,
            &headers,
            Instant::now(),
            SystemTime::now(),
            &a.cooldown
        ));
        assert!(same.cooldown.lock().unwrap().is_some());
        assert!(other.cooldown.lock().unwrap().is_none());
        assert!(matches!(
            same.fetch_lyrics(&request("Song", 240.0), &|| Err("cancelled".into())),
            Err(LyricsError::Cancelled(_))
        ));
    }

    #[test]
    fn concurrent_clients_share_one_origin_cooldown() {
        let endpoint = Url::parse("https://concurrent-limit.example").unwrap();
        let handles = std::thread::scope(|scope| {
            (0..16)
                .map(|_| scope.spawn(|| cooldown(&endpoint)))
                .collect::<Vec<_>>()
                .into_iter()
                .map(|thread| thread.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert!(handles.iter().all(|entry| Arc::ptr_eq(entry, &handles[0])));
        let headers = BTreeMap::from([("Retry-After".into(), vec!["120".into()])]);
        std::thread::scope(|scope| {
            for entry in &handles {
                let headers = &headers;
                scope.spawn(move || {
                    assert!(rate_limited(
                        429,
                        headers,
                        Instant::now(),
                        SystemTime::now(),
                        entry
                    ))
                });
            }
        });
        assert!(
            handles[0]
                .lock()
                .unwrap()
                .unwrap()
                .saturating_duration_since(Instant::now())
                > Duration::from_secs(119)
        );
    }

    #[test]
    fn simulated_http_429_suppresses_following_requests_and_respects_cancel() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let network = NetworkService::new().unwrap();
        let mut client = LrcLibClient::new(&network, "5.3.1");
        client.cooldown = Arc::new(Mutex::new(None));
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        client.response_fixture = Some(Box::new(move || {
            observed.fetch_add(1, Ordering::SeqCst);
            mornye_network::HttpResponse {
                status: 429,
                status_text: "Too Many Requests".into(),
                url: "https://lrclib.net/api/get".into(),
                headers: BTreeMap::from([("Retry-After".into(), vec!["300".into()])]),
                body: Vec::new(),
            }
        }));
        assert!(matches!(
            client.fetch_lyrics(&request("Song", 240.0), &|| Ok(())),
            Err(LyricsError::Unavailable(_))
        ));
        assert!(matches!(
            client.fetch_lyrics(&request("Song", 240.0), &|| Ok(())),
            Err(LyricsError::Unavailable(_))
        ));
        assert!(matches!(
            client.fetch_lyrics(&request("Song", 240.0), &|| Err("cancelled".into())),
            Err(LyricsError::Cancelled(_))
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(
            client
                .cooldown
                .lock()
                .unwrap()
                .unwrap()
                .saturating_duration_since(Instant::now())
                > Duration::from_secs(299)
        );
    }

    #[test]
    fn lrclib_live_original_404_never_publishes_studio_fallback() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let observed = calls.clone();
        let client = client(move |path, parameters| {
            let mut calls = observed.lock().unwrap();
            calls.push((
                path.to_owned(),
                parameters
                    .iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect::<Vec<_>>(),
            ));
            if calls.len() == 1 {
                return Err(LyricsError::NotFound("HTTP 404".into()));
            }
            let studio = response("Song", 180.0);
            Ok(serde_json::to_vec(&if path == "/api/search" {
                serde_json::json!([studio])
            } else {
                studio
            })
            .unwrap())
        });
        assert!(matches!(
            client.fetch_lyrics(&request("Song (Live)", 240.0), &|| Ok(())),
            Err(LyricsError::NotFound(_))
        ));
        let calls = calls.lock().unwrap();
        assert!(calls.len() <= 5, "lookup must remain bounded");
        assert_eq!(
            calls[0].1,
            vec![
                ("artist_name".into(), "Artist".into()),
                ("track_name".into(), "Song (Live)".into()),
                ("duration".into(), "240".into())
            ]
        );
    }

    #[test]
    fn lrclib_metadata_checks_original_version_and_duration() {
        for (title, duration) in [("Song", 240.0), ("Song (Live)", 180.0)] {
            let client = client(move |path, _| {
                let item = response(title, duration);
                Ok(serde_json::to_vec(&if path == "/api/search" {
                    serde_json::json!([item])
                } else {
                    item
                })
                .unwrap())
            });
            assert!(matches!(
                client.fetch_lyrics(&request("Song (Live)", 240.0), &|| Ok(())),
                Err(LyricsError::NotFound(_))
            ));
        }
        let exact = client(|_, _| Ok(serde_json::to_vec(&response("Song (Live)", 241.0)).unwrap()));
        assert!(
            !exact
                .fetch_lyrics(&request("Song (Live)", 240.0), &|| Ok(()))
                .unwrap()
                .lines()
                .is_empty()
        );
    }

    #[test]
    fn lrclib_missing_duration_uses_unique_search_without_inventing_time() {
        for ambiguous in [false, true] {
            let client = client(move |path, parameters| {
                assert_eq!(path, "/api/search");
                assert!(!parameters.iter().any(|(key, _)| *key == "duration"));
                let mut items = vec![response("Song (Live)", 240.0)];
                if ambiguous {
                    items.push(response("Song (Live)", 180.0));
                }
                Ok(serde_json::to_vec(&items).unwrap())
            });
            let result = client.fetch_lyrics(&request("Song (Live)", 0.0), &|| Ok(()));
            assert_eq!(result.is_ok(), !ambiguous);
        }
    }

    #[test]
    fn lrclib_rate_limit_and_cancellation_stop_without_more_requests() {
        let limited = client(|_, _| Err(LyricsError::Unavailable("HTTP 429".into())));
        assert!(matches!(
            limited.fetch_lyrics(&request("Song", 240.0), &|| Ok(())),
            Err(LyricsError::Unavailable(_))
        ));
        let client = client(|_, _| panic!("cancelled request reached transport"));
        assert!(matches!(
            client.fetch_lyrics(&request("Song", 240.0), &|| Err("cancelled".into())),
            Err(LyricsError::Cancelled(_))
        ));
    }

    #[test]
    fn lrclib_requests_and_validates_full_band_credit() {
        for returned_artist in ["Florence", "Florence & the Machine"] {
            let client = client(move |path, parameters| {
                if path == "/api/get" {
                    assert!(parameters.contains(&("artist_name", "Florence & the Machine")));
                } else {
                    assert!(parameters.iter().any(
                        |(key, value)| *key == "q" && value.contains("Florence & the Machine")
                    ));
                }
                let mut item = response("Song", 240.0);
                item["artistName"] = returned_artist.into();
                Ok(serde_json::to_vec(&if path == "/api/search" {
                    serde_json::json!([item])
                } else {
                    item
                })
                .unwrap())
            });
            let mut request = request("Song", 240.0);
            request.artist = "Florence & the Machine".into();
            assert_eq!(
                client.fetch_lyrics(&request, &|| Ok(())).is_ok(),
                returned_artist == "Florence & the Machine"
            );
        }
    }
}
