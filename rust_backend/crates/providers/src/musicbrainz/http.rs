use super::{Fetch, MusicBrainzOptions, Outcome, POLL};
use crate::resolver::{Check, ResolverError, urls::query_escape};
use mornye_core::lyrics::decode_response;
use mornye_network::{HttpRequest, HttpStream, NetworkService, NetworkSession, url::UrlParts};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

const MAX_BODY: usize = 16 << 20;
const INTERVAL: Duration = Duration::from_secs(1);
const MAX_RETRY_WAIT: Duration = Duration::from_secs(60);
static GATES: OnceLock<Mutex<BTreeMap<String, Arc<Mutex<Instant>>>>> = OnceLock::new();

fn gate(endpoint: &str) -> Result<Arc<Mutex<Instant>>, ResolverError> {
    // URL's origin normalizes host casing, IDNA, and the default HTTPS port.
    let origin = url::Url::parse(endpoint)
        .map_err(|_| ResolverError::Failed("invalid MusicBrainz origin".into()))?
        .origin()
        .ascii_serialization();
    Ok(GATES
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .entry(origin)
        .or_insert_with(|| Arc::new(Mutex::new(Instant::now())))
        .clone())
}

fn acquire(gate: &Mutex<Instant>, check: &Check<'_>) -> Result<(), ResolverError> {
    loop {
        check().map_err(ResolverError::Cancelled)?;
        let wait = {
            let mut next = gate.lock().unwrap();
            let now = Instant::now();
            if now >= *next {
                *next = now + INTERVAL;
                return Ok(());
            }
            next.saturating_duration_since(now)
        };
        // Do not pin a worker to an unusually long server cooldown.
        if wait > MAX_RETRY_WAIT {
            return Err(ResolverError::Failed(
                "MusicBrainz retry delay exceeds wait limit".into(),
            ));
        }
        std::thread::sleep(wait.min(POLL));
    }
}

fn retry_after(headers: &BTreeMap<String, Vec<String>>) -> Option<Duration> {
    let value = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("retry-after"))?
        .1
        .first()?
        .trim();
    value
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
        .or_else(|| {
            httpdate::parse_http_date(value)
                .ok()
                .map(|date| date.duration_since(SystemTime::now()).unwrap_or_default())
        })
}

fn transient(status: u16) -> bool {
    matches!(status, 408 | 429 | 500 | 502 | 503 | 504)
}

fn user_agent(contact: Option<&str>) -> Result<String, ResolverError> {
    // pubspec is the application version; Cargo's workspace version is unrelated.
    let version = include_str!("../../../../../pubspec.yaml")
        .lines()
        .find_map(|line| line.strip_prefix("version:").map(str::trim))
        .and_then(|value| value.split('+').next())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ResolverError::Failed("missing MUSA application version".into()))?;
    let mut agent = format!("MUSA/{version}");
    if let Some(contact) = contact.map(str::trim).filter(|v| !v.is_empty()) {
        if !contact.is_ascii()
            || contact
                .chars()
                .any(|c| c.is_ascii_control() || c == '(' || c == ')')
        {
            return Err(ResolverError::Failed("invalid MusicBrainz contact".into()));
        }
        agent.push_str(&format!(" ({contact})"));
    }
    Ok(agent)
}

pub(super) struct Http {
    session: Arc<NetworkSession>,
    endpoint: String,
    timeout: Duration,
    retry_delay: Duration,
    user_agent: String,
    gate: Arc<Mutex<Instant>>,
}

impl Http {
    pub fn new(
        network: &Arc<NetworkService>,
        options: &MusicBrainzOptions,
    ) -> Result<Self, ResolverError> {
        let endpoint = UrlParts::parse(&options.endpoint)
            .ok_or_else(|| ResolverError::Failed("invalid MusicBrainz origin".into()))?;
        if endpoint.scheme != "https"
            || endpoint.hostname.is_empty()
            || endpoint.has_credentials
            || !matches!(endpoint.raw_path.as_str(), "" | "/")
            || !endpoint.raw_query.is_empty()
            || !endpoint.fragment.is_empty()
        {
            return Err(ResolverError::Failed(
                "MusicBrainz endpoint requires an HTTPS origin without credentials".into(),
            ));
        }
        if options.http_timeout.is_zero() {
            return Err(ResolverError::Failed(
                "MusicBrainz HTTP timeout must be positive".into(),
            ));
        }
        Ok(Self {
            session: network.native_session(options.http_timeout),
            endpoint: options.endpoint.trim_end_matches('/').into(),
            timeout: options.http_timeout,
            retry_delay: options.retry_delay,
            user_agent: user_agent(options.contact.as_deref())?,
            gate: gate(options.endpoint.trim_end_matches('/'))?,
        })
    }

    fn wait_retry(&self, delay: Duration, check: &Check<'_>) -> Result<(), ResolverError> {
        let started = Instant::now();
        while started.elapsed() < delay {
            check().map_err(ResolverError::Cancelled)?;
            std::thread::sleep(delay.saturating_sub(started.elapsed()).min(POLL));
        }
        check().map_err(ResolverError::Cancelled)
    }
}

fn failure(message: String, check: &Check<'_>) -> ResolverError {
    if let Err(cancelled) = check() {
        ResolverError::Cancelled(cancelled)
    } else if message == "network policy changed" {
        ResolverError::Cancelled(message)
    } else {
        ResolverError::Transport(message)
    }
}

impl Fetch for Http {
    fn fetch(&self, isrc: &str, check: &Check<'_>) -> Outcome {
        let url = format!(
            "{}/ws/2/recording?query={}&fmt=json&inc=tags+releases+artist-credits",
            self.endpoint,
            query_escape(&format!("isrc:{isrc}"))
        );
        self.fetch_with(check, || {
            self.session
                .open_stream(
                    HttpRequest {
                        url: url.clone(),
                        method: "GET".into(),
                        body: String::new(),
                        headers: BTreeMap::new(),
                        default_json: false,
                        user_agent: self.user_agent.clone(),
                    },
                    self.timeout,
                    self.timeout,
                    check,
                )
                .map(|stream| Box::new(stream) as Box<dyn ResponseStream>)
        })
    }
}

trait ResponseStream {
    fn status(&self) -> u16;
    fn headers(&self) -> &BTreeMap<String, Vec<String>>;
    fn read_body(&mut self, check: &Check<'_>) -> Result<Vec<u8>, ResolverError>;
}

impl ResponseStream for HttpStream {
    fn status(&self) -> u16 {
        self.response.status
    }
    fn headers(&self) -> &BTreeMap<String, Vec<String>> {
        &self.response.headers
    }
    fn read_body(&mut self, check: &Check<'_>) -> Result<Vec<u8>, ResolverError> {
        read_json(self, check)
    }
}

impl Http {
    fn fetch_with(
        &self,
        check: &Check<'_>,
        mut open: impl FnMut() -> Result<Box<dyn ResponseStream>, String>,
    ) -> Outcome {
        let mut delay = self.retry_delay;
        for attempt in 0..3 {
            if attempt > 0 {
                self.wait_retry(delay, check)?;
            }
            acquire(&self.gate, check)?;
            let stream = open();
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(message) => {
                    let error = failure(message, check);
                    if matches!(error, ResolverError::Cancelled(_)) || attempt == 2 {
                        return Err(error);
                    }
                    continue;
                }
            };
            let status = stream.status();
            if status != 200 {
                let server_delay = if matches!(status, 429 | 503) {
                    retry_after(stream.headers())
                } else {
                    None
                };
                // Failed statuses retry without waiting for their body to finish.
                drop(stream);
                if let Some(server_delay) = server_delay {
                    let deadline = Instant::now().checked_add(server_delay).ok_or_else(|| {
                        ResolverError::Failed("MusicBrainz retry delay is too large".into())
                    })?;
                    let mut next = self.gate.lock().unwrap();
                    *next = (*next).max(deadline);
                }
                if !transient(status)
                    || attempt == 2
                    || server_delay.is_some_and(|d| d > MAX_RETRY_WAIT)
                {
                    return Err(ResolverError::Failed(format!(
                        "MusicBrainz API returned status: {status}"
                    )));
                }
                delay = self.retry_delay.max(server_delay.unwrap_or_default());
                continue;
            }
            // Decode/body failures occur after Client.Do in Go and are not retried.
            let body = stream.read_body(check)?;
            let result = decode_response(&body)
                .map(Arc::new)
                .map_err(|error| ResolverError::Failed(error.to_string()));
            check().map_err(ResolverError::Cancelled)?;
            return result;
        }
        unreachable!("last MusicBrainz attempt returns its result")
    }
}

// Locate the first complete compound/string JSON value in one linear scan.
// Go's Decoder.Decode can return before EOF, including a trailing stalled body.
// Full syntax and field validation remain the typed decoder's responsibility.
#[derive(Default)]
struct Boundary {
    started: bool,
    compound: bool,
    depth: usize,
    quoted: bool,
    escaped: bool,
}

impl Boundary {
    fn byte(&mut self, byte: u8) -> bool {
        if !self.started {
            if matches!(byte, b' ' | b'\t' | b'\r' | b'\n') {
                return false;
            }
            self.started = true;
            self.compound = matches!(byte, b'{' | b'[' | b'"');
        }
        if self.quoted {
            if self.escaped {
                self.escaped = false;
            } else if byte == b'\\' {
                self.escaped = true;
            } else if byte == b'"' {
                self.quoted = false;
                return self.depth == 0;
            }
        } else {
            match byte {
                b'"' => self.quoted = true,
                b'{' | b'[' => self.depth += 1,
                b'}' | b']' => {
                    self.depth = self.depth.saturating_sub(1);
                    return self.depth == 0;
                }
                b' ' | b'\t' | b'\r' | b'\n' if !self.compound => return true,
                _ => {}
            }
        }
        false
    }
}

fn read_json(stream: &mut HttpStream, check: &Check<'_>) -> Result<Vec<u8>, ResolverError> {
    let mut boundary = Boundary::default();
    let mut body = Vec::new();
    let mut buffer = [0; 16 << 10];
    loop {
        let count = stream
            .read(&mut buffer, check)
            .map_err(|message| failure(message, check))?;
        if count == 0 {
            return Ok(body);
        }
        let end = buffer[..count].iter().position(|byte| boundary.byte(*byte));
        let length = end.map_or(count, |index| index + 1);
        if body.len() + length > MAX_BODY {
            return Err(ResolverError::Failed(
                "MusicBrainz response exceeds limit".into(),
            ));
        }
        body.extend_from_slice(&buffer[..length]);
        if end.is_some() {
            return Ok(body);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct FakeResponse {
        status: u16,
        headers: BTreeMap<String, Vec<String>>,
    }
    impl ResponseStream for FakeResponse {
        fn status(&self) -> u16 {
            self.status
        }
        fn headers(&self) -> &BTreeMap<String, Vec<String>> {
            &self.headers
        }
        fn read_body(&mut self, _: &Check<'_>) -> Result<Vec<u8>, ResolverError> {
            Ok(br#"{"recordings":[]}"#.to_vec())
        }
    }
    fn fixture_response(status: u16, retry: Option<&str>) -> Box<dyn ResponseStream> {
        let mut headers = BTreeMap::new();
        if let Some(value) = retry {
            headers.insert("retry-after".into(), vec![value.into()]);
        }
        Box::new(FakeResponse { status, headers })
    }
    fn fixture_http(name: &str) -> Http {
        let network = NetworkService::new().unwrap();
        let options = MusicBrainzOptions {
            endpoint: format!("https://{name}.invalid"),
            retry_delay: Duration::ZERO,
            ..Default::default()
        };
        Http::new(&network, &options).unwrap()
    }

    #[test]
    fn fetch_pipeline_retries_rate_limit_and_stops_on_client_error() {
        let http = fixture_http("pipeline-retry");
        let mut calls = Vec::new();
        let result = http.fetch_with(&|| Ok(()), || {
            calls.push(Instant::now());
            Ok(if calls.len() == 1 {
                fixture_response(429, Some("1"))
            } else {
                fixture_response(200, None)
            })
        });
        assert!(result.is_ok());
        assert_eq!(calls.len(), 2);
        assert!(calls[1].duration_since(calls[0]) >= Duration::from_millis(990));
        let http = fixture_http("pipeline-client-error");
        let mut count = 0;
        assert!(
            http.fetch_with(&|| Ok(()), || {
                count += 1;
                Ok(fixture_response(400, None))
            })
            .is_err()
        );
        assert_eq!(count, 1);
    }

    #[test]
    fn fetch_pipeline_shared_gate_and_cancel_waiting_retry() {
        let first = fixture_http("pipeline-shared");
        let second = fixture_http("pipeline-shared");
        let mut calls = Vec::new();
        first
            .fetch_with(&|| Ok(()), || {
                calls.push(Instant::now());
                Ok(fixture_response(200, None))
            })
            .unwrap();
        second
            .fetch_with(&|| Ok(()), || {
                calls.push(Instant::now());
                Ok(fixture_response(200, None))
            })
            .unwrap();
        assert!(calls[1].duration_since(calls[0]) >= Duration::from_millis(990));
        let http = fixture_http("pipeline-cancel");
        let start = Instant::now();
        let mut count = 0;
        let result = http.fetch_with(
            &|| {
                if start.elapsed() >= Duration::from_millis(50) {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            },
            || {
                count += 1;
                Ok(fixture_response(429, Some("2")))
            },
        );
        assert!(matches!(result, Err(ResolverError::Cancelled(_))));
        assert_eq!(count, 1);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn identity_and_retry_policy() {
        assert_eq!(user_agent(None).unwrap(), "MUSA/5.3.1");
        assert_eq!(
            user_agent(Some("maintainer@example.test")).unwrap(),
            "MUSA/5.3.1 (maintainer@example.test)"
        );
        assert!(user_agent(Some("bad\r\nheader")).is_err());
        for status in [400, 401, 403, 404] {
            assert!(!transient(status));
        }
        for status in [408, 429, 500, 502, 503, 504] {
            assert!(transient(status));
        }
        let headers = BTreeMap::from([("Retry-After".into(), vec!["12".into()])]);
        assert_eq!(retry_after(&headers), Some(Duration::from_secs(12)));
        let past = BTreeMap::from([(
            "retry-after".into(),
            vec!["Wed, 21 Oct 2015 07:28:00 GMT".into()],
        )]);
        assert_eq!(retry_after(&past), Some(Duration::ZERO));
    }

    #[test]
    fn gate_is_shared_and_cancellable() {
        let first = gate("https://fixture.invalid").unwrap();
        let second = gate("https://FIXTURE.invalid:443/").unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert!(!Arc::ptr_eq(
            &first,
            &gate("https://fixture.invalid:444").unwrap()
        ));
        assert!(!Arc::ptr_eq(
            &first,
            &gate("https://other.invalid").unwrap()
        ));
        acquire(&first, &|| Ok(())).unwrap();
        let cancelled = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let worker = scope.spawn(|| {
                acquire(&second, &|| {
                    if cancelled.load(Ordering::Acquire) {
                        Err("cancelled".into())
                    } else {
                        Ok(())
                    }
                })
            });
            std::thread::sleep(Duration::from_millis(40));
            cancelled.store(true, Ordering::Release);
            assert!(matches!(
                worker.join().unwrap(),
                Err(ResolverError::Cancelled(_))
            ));
        });
        let start = Instant::now();
        acquire(&second, &|| Ok(())).unwrap();
        assert!(start.elapsed() >= Duration::from_millis(850));
    }
}
