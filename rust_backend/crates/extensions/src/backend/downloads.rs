//! Application download planning. The installed manager owns VMs/transfers;
//! this root owns request lifetime, fallback and publication of regular files.

#[cfg(test)]
mod account_tests;
#[cfg(test)]
mod container_tests;
#[cfg(feature = "experimental-private-mov")]
pub(super) mod encrypted;
mod matching;
#[cfg(all(test, feature = "experimental-prepublication-opus"))]
mod opus;
mod metadata;
mod paths;
mod prepared;
#[cfg(test)]
mod relay_tests;
mod relay_order;
mod result;
#[cfg(test)]
mod tests;

use super::Backend;
use crate::download::native_error_response;
use crate::manager::{ProviderAvailabilityRequest, ProviderDownloadRequest};
use crate::manifest::ExtensionManifest;
use mornye_core::cancellation::RequestLease;
use mornye_core::downloads::DownloadRequest;
use mornye_core::metadata::reenrich::text;
use mornye_core::tags::{embed_flac_metadata, extract_cover};
use mornye_providers::resolver::Check;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::{Read, Write};
#[cfg(feature = "experimental-progressive-reader")]
use std::io::Seek;
use std::path::Path;
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use matching::{matches_track, probe_open_file, probe_result, strict_codec_matches};
use metadata::{
    apply_metadata, download_metadata_fields, host_track, preferred_track_id,
    select_download_metadata,
};
use paths::{album_folder, filename, output_path};
use prepared::preparation_key;
use result::{
    DiagnosticCause, compact, failure, inherit_diagnostic_cause, quality_failure, stopped,
    storage_failure, strict_quality_failure, success,
};

pub(super) type PreparedDownloads = BTreeMap<String, Prepared>;

pub(super) struct Prepared {
    key: String,
    request: DownloadRequest,
    metadata_ready: bool,
    created: Instant,
}

enum DownloadOutcome {
    Retry(Value),
    // Successful downloads and host finalization failures are both terminal.
    Final(Value),
}

// Provider-controlled text and URLs must never enter the attempt trace.
fn trace_provider(id: &str) -> &str {
    if !id.is_empty() && id.len() <= 80 && id.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        id
    } else {
        "invalid-provider-id"
    }
}

fn trace_attempt(trace: &mut Vec<Value>, id: &str, stage: &'static str, kind: &str) {
    trace_attempt_details(trace, id, stage, kind, &[]);
}

fn trace_attempt_details(trace: &mut Vec<Value>, id: &str, stage: &'static str, kind: &str, details: &[(&'static str, Value)]) {
    if trace.len() < 64 {
        let kind = provider_error_kind(kind);
        let mut entry = json!({"provider": trace_provider(id), "stage": stage, "error_type": kind});
        for (key, value) in details {
            entry[*key] = value.clone();
        }
        trace.push(entry);
    }
}

fn availability_reason_class(reason: &str) -> &'static str {
    let reason = reason.trim().to_ascii_lowercase();
    if reason.is_empty() {
        "empty"
    } else if ["no matching", "no verified", "no confident", "not found", "no results", "track match"].iter().any(|needle| reason.contains(needle)) {
        "no_match"
    } else if reason.starts_with("search failed") || ["http", "timeout", "network"].iter().any(|needle| reason.contains(needle)) {
        "lookup_failed"
    } else if reason.contains("download cancelled") {
        "cancelled"
    } else if ["no track identity", "no search query", "no recording metadata"].iter().any(|needle| reason.contains(needle)) {
        "identity_missing"
    } else if reason.starts_with("direct ") {
        "direct_unplayable"
    } else {
        "other"
    }
}

fn download_trace_details(id_source: &'static str, id_len: usize, response: &Value) -> Vec<(&'static str, Value)> {
    let mut details = vec![("id_source", Value::from(id_source)), ("id_len", Value::from(id_len.min(255) as u64))];
    if let Some(seconds) = response["retry_after_seconds"].as_i64().filter(|seconds| *seconds > 0) {
        details.push(("retry_after_s", Value::from(seconds.min(86_400))));
    }
    if let Some(status) = response["http_status"].as_u64().filter(|status| (100..=599).contains(status)) {
        details.push(("http_status", Value::from(status)));
    }
    details
}

fn availability_error_stage(message: &str) -> &'static str {
    if provider_diagnostic_input(message).to_ascii_lowercase().contains("timeout") {
        "availability_operation_timeout"
    } else {
        "availability_operation_error"
    }
}

fn with_provider_attempts(mut response: Value, trace: &[Value]) -> Value {
    if !trace.is_empty() {
        response["provider_attempts"] = Value::Array(trace.to_vec());
    }
    response
}

fn retain_provider_failure(best: &mut Option<Value>, candidate: Value) {
    fn priority(response: &Value) -> u8 {
        match text(response, "error_type") {
            "not_found" => 0,
            "" | "unknown" | "extension_error" | "runtime_error" | "script_error" | "api_error"
            | "download_error" | "init_error" | "not_implemented" | "provider_error" => 1,
            _ => 2,
        }
    }

    // Within a category, keep the same last-attempt precedence as before.
    if best
        .as_ref()
        .is_none_or(|prior| priority(&candidate) >= priority(prior))
    {
        *best = Some(candidate);
    }
}

fn provider_error_kind(kind: &str) -> &str {
    match kind {
        ""
        | "unknown"
        | "extension_error"
        | "runtime_error"
        | "script_error"
        | "api_error"
        | "download_error"
        | "init_error"
        | "not_implemented"
        | "not_found"
        | "cancelled"
        | "verification_required"
        | "permission"
        | "rate_limit"
        | "rate_limited"
        | "network"
        | "isp_blocked"
        | "provider_reauth_required"
        | "request_auth_invalid"
        | "provider_auth_failed"
        | "provider_unavailable"
        | "quality_unavailable"
        | "auth"
        | "authentication_error"
        | "subscription_required"
        | "timeout"
        | "transient_network"
        | "storage_error"
        | "file_error"
        | "http_error"
        | "expired_stream"
        | "invalid_url"
        | "provider_error"
        | "integrity_failed" => kind,
        _ => "unknown",
    }
}

fn catalog_absence(reason: &str) -> Option<&'static str> {
    match reason.trim().to_ascii_lowercase().as_str() {
        "" => Some("No matching track available from this provider"),
        "not_found" | "not found" | "track not found" => Some("Track not found"),
        "no results" => Some("No results"),
        "no matching track" => Some("No matching track"),
        "no confident playable match found" | "no confident playable match found on soundcloud" => {
            Some("No confident playable match found")
        }
        "no verified track match found" => Some("No verified track match found"),
        "track not available" => Some("Track not available"),
        _ => None,
    }
}

// Keep only the diagnostic portion for legacy type inference. Provider text
// can include signed URLs, credentials or entire responses.
fn provider_diagnostic_input(message: &str) -> String {
    use regex::Regex;
    use std::sync::LazyLock;

    static URL: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)(?:(?:[a-z][a-z0-9+.-]*:)?//|www\.)\S+").expect("valid diagnostic URL pattern")
    });
    static PAYLOAD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?i)\{|<|\[\s*(?:["'\[\d-]|true|false|null|\])|\b(?:(?:response )?body|raw response|http response|response data|payload)\s*[:=]"#)
            .expect("valid diagnostic payload pattern")
    });
    static BARE_TOKEN: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?i)(\btoken"?\s*[:=]\s*)("(?:\\.|[^"\\])*"|'[^']*'|[^\s,;\]}]+)"#)
            .expect("valid diagnostic token pattern")
    });

    let message = PAYLOAD
        .find(message)
        .map_or(message, |payload| &message[..payload.start()]);
    let message = URL.replace_all(message, "[URL redacted]");
    let message = BARE_TOKEN.replace_all(&message, "${1}[REDACTED]");
    crate::redact::preview(message.as_bytes(), usize::MAX)
}

fn provider_error_message(kind: &str) -> &'static str {
    match kind {
        "verification_required" => "Verification required",
        "permission" => "Permission denied while writing the download",
        "rate_limit" | "rate_limited" => "HTTP 429: Provider rate limit reached",
        "network" | "transient_network" | "timeout" => "Provider network request failed",
        "not_found" => "Track not found",
        "cancelled" => "Download cancelled",
        "isp_blocked" => "Provider access may be blocked by the network",
        "provider_reauth_required" => "Reconnect the provider account",
        "request_auth_invalid" | "provider_auth_failed" | "auth" | "authentication_error" => {
            "Provider authentication failed"
        }
        "provider_unavailable" => "Provider is unavailable",
        "quality_unavailable" => "Requested quality unavailable from this provider",
        "subscription_required" => "Provider subscription required",
        "storage_error" | "file_error" => "Provider could not write the download",
        "http_error" => "Provider HTTP request failed",
        "expired_stream" => "Provider stream request failed; a refreshed stream may be available",
        "integrity_failed" => "Provider download failed integrity validation",
        "not_implemented" => "Provider does not implement this download operation",
        _ => "Provider request failed",
    }
}

fn provider_failure(service: &str, message: &str, kind: &str, retry: i64) -> Value {
    #[cfg(feature = "experimental-progressive-reader")]
    if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() {
        let text = message.to_ascii_lowercase();
        let category = if text.contains("no supported full soundcloud stream") { "no_supported_full_stream" } else if text.contains("full playable stream") { "no_full_playable_stream" } else if text.contains("duration") { "duration" } else if text.contains("playlist") || text.contains("hls") { "hls" } else if text.contains("segment") { "segment" } else if text.contains("client id") { "client_id" } else if text.contains("verification") || text.contains("captcha") { "verification" } else if text.contains("timeout") { "timeout" } else if text.contains("403") { "http_403" } else if text.contains("404") { "http_404" } else if text.contains("429") { "http_429" } else { "other" };
        eprintln!("provider_diagnostic={category}");
    }
    let diagnostic = provider_diagnostic_input(message);
    let classified = native_error_response(&diagnostic);
    let kind = kind.trim().to_ascii_lowercase();
    let kind = provider_error_kind(&kind);
    let inferred = text(&classified, "error_type");
    let kind = match kind {
        "" => inferred,
        "unknown" | "runtime_error" | "api_error" | "download_error" | "extension_error"
            if inferred != "unknown" =>
        {
            inferred
        }
        _ => kind,
    };
    let message = if kind != "verification_required" && storage_failure(kind, &diagnostic) {
        provider_error_message("permission")
    } else {
        provider_error_message(kind)
    };
    failure(service, message, kind, retry)
}

fn provider_failure_from_result(service: &str, result: &Value) -> Value {
    let kind = text(result, "error_type");
    let mut response = provider_failure(service, text(result, "error_message"), if kind.trim().is_empty() { "extension_error" } else { kind }, result["retry_after_seconds"].as_i64().unwrap_or_default());
    if let Some(status) = result.get("http_status").and_then(Value::as_u64).filter(|n| (100..=599).contains(n)) {
        response["http_status"] = status.into();
        if text(&response, "error_type") == "expired_stream" {
            response["error"] = format!("Provider stream request returned HTTP {status}; a refreshed stream may be available").into();
        }
    }
    response
}

fn unavailable_provider_failure(service: &str, availability: &Value) -> Value {
    let reason = text(availability, "reason");
    let kind = text(availability, "error_type").trim().to_ascii_lowercase();
    let retry = availability["retry_after_seconds"]
        .as_i64()
        .unwrap_or_default();
    if availability["available"] == false
        && kind.is_empty()
        && let Some(absence) = catalog_absence(reason)
    {
        return failure(service, absence, "not_found", retry);
    }
    let mut response = provider_failure(service, reason, &kind, retry);
    if response["error_type"] == "not_found" && kind != "not_found" {
        // A generic API failure may mention a missing HTTP resource.
        response = failure(service, provider_error_message("unknown"), "unknown", retry);
    }
    response
}

fn stopped_provider_failure(service: &str, availability: &Value, attempt: Option<Value>) -> Value {
    if attempt.is_none() && !text(availability, "error_type").trim().is_empty() {
        let mut response = unavailable_provider_failure(service, availability);
        let message = text(&response, "error");
        response["error"] = format!("Fallback stopped by {service}: {message}").into();
        return response;
    }
    let reason = text(availability, "reason").trim();
    let had_attempt = attempt.is_some();
    let mut response = attempt.unwrap_or_else(|| {
        let diagnostic = provider_diagnostic_input(reason);
        stopped(service, &Value::Null, &diagnostic)
    });
    let reason = if reason.is_empty() && !had_attempt {
        "extension requested no further fallback"
    } else if !reason.is_empty() {
        catalog_absence(reason)
            .unwrap_or_else(|| provider_error_message(text(&response, "error_type")))
    } else {
        text(&response, "error")
    };
    response["error"] = format!("Fallback stopped by {service}: {reason}").into();
    response
}

/// Once local publication succeeds, indexing is recoverable bookkeeping.
/// Keeping this boundary explicit also permits deterministic failure injection
/// without closing a live environment or racing the filesystem in tests.
fn finish_committed_download(
    mut response: Value,
    update_index: impl FnOnce(&Value) -> Result<(), String>,
) -> Value {
    if update_index(&response).is_err() {
        response["index_refresh_pending"] = true.into();
    }
    response
}

// Saved quality descriptions are evidence only for their explicitly identified source.
fn source_with_request_quality(
    request: &DownloadRequest,
    live: Option<ExtensionManifest>,
) -> Option<ExtensionManifest> {
    let provider = request.quality_source_provider.trim();
    let id = request.quality_source_id.trim();
    if provider.is_empty() || id.is_empty()
        || !id.eq_ignore_ascii_case(request.quality.trim())
        || !request.service.trim().eq_ignore_ascii_case(provider)
        || !matches!(request.quality_source_kind.trim(), "" | "lossless" | "lossy" | "spatial")
    { return live; }
    let saved = crate::manifest::QualityOption {
        id: id.into(), label: request.quality_source_label.trim().into(),
        kind: request.quality_source_kind.trim().into(), ..Default::default()
    };
    if crate::manifest::quality_claims_conflict(&saved, &saved) { return live; }
    let mut source = live.unwrap_or_else(|| ExtensionManifest { name: provider.into(), ..Default::default() });
    if !source.name.trim().eq_ignore_ascii_case(provider) { return Some(source); }
    if let Some(existing) = source.find_quality(id) {
        if crate::manifest::quality_claims_conflict(existing, &saved) { return Some(source); }
        // The live declaration is authoritative whenever present.
        return Some(source);
    }
    source.quality_options.push(saved);
    Some(source)
}

fn report_selected_quality(response: &mut Value, request: &DownloadRequest, selected: &str) {
    response["requested_quality"] = request.quality.clone().into();
    if response["already_exists"] != true {
        if request.allow_quality_fallback || request.quality.trim().is_empty() {
            response["resolved_quality"] = selected.into();
        } else {
            // A provider quality ID does not certify the target bitrate of VBR.
            response["provider_selected_quality"] = selected.into();
            if response["quality_verification"].is_null() {
                response["quality_verification"] = "bitrate_unverified".into();
            }
            if permanent_relay(request) {
                // The relay may have changed provider or tier: name what was fetched.
                response["resolved_quality"] = selected.into();
            }
        }
    }
}

fn first_unique_provider_attempt(
    seen: &mut BTreeSet<(String, String, String)>,
    provider: &str,
    track_id: &str,
    quality: &str,
) -> bool {
    seen.insert((provider.trim().to_ascii_lowercase(), track_id.to_owned(), quality.trim().to_ascii_lowercase()))
}

/// Permanent downloads relay by quality class unless the user asked for the
/// exact quality only. Temporary playback keeps its own permissive rules.
fn permanent_relay(request: &DownloadRequest) -> bool {
    request.quality_relay && !request.temporary_playback
}

fn playback_only_provider(id: &str) -> bool {
    matches!(id.trim().to_ascii_lowercase().as_str(), "soundcloud" | "youtube" | "ytmusic-spotiflac" | "youtubemusic")
}

impl Backend {
    /// Go's strategy facade returns a JSON failure, including transport errors
    /// from the extension facade. The latter retains its Result error boundary.
    pub fn download_by_strategy(&self, raw: &str, check: &Check<'_>) -> Result<String, String> {
        let _operation = self.enter()?;
        let request = match DownloadRequest::parse(raw) {
            Ok(request) => request,
            Err(error) => {
                return Ok(native_error_response(&format!("Invalid request: {error}")).to_string());
            }
        };
        if !request.use_extensions {
            return Ok(native_error_response(
                "Extension providers are disabled; built-in download providers have been retired",
            )
            .to_string());
        }
        Ok(self
            .download_request(request, check,
                #[cfg(feature = "experimental-progressive-reader")] None)
            .unwrap_or_else(|error| native_error_response(&error).to_string()))
    }

    #[cfg(feature = "experimental-progressive-reader")]
    pub fn download_by_strategy_progressive(
        &self, raw: &str, check: &Check<'_>,
        progressive: Arc<crate::download::progressive_candidate::ProgressiveOperation>,
    ) -> Result<String, String> {
        struct Finish(Arc<crate::download::progressive_candidate::ProgressiveOperation>);
        impl Drop for Finish { fn drop(&mut self) { self.0.finish(); } }
        let _finish = Finish(progressive.clone());
        let _operation = self.enter()?;
        if !progressive.is_admitted() {
            return Err("trusted clear-audio admission unavailable".into());
        }
        let request = DownloadRequest::parse(raw).map_err(|error| error.to_string())?;
        if !request.use_extensions || !request.temporary_playback {
            return Err("progressive operation requires temporary extension playback".into());
        }
        self.download_request(request, check, Some(progressive))
    }

    fn download_request(
        &self,
        mut request: DownloadRequest,
        check: &Check<'_>,
        #[cfg(feature = "experimental-progressive-reader")]
        progressive: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>,
    ) -> Result<String, String> {
        request.normalize();
        self.check()?;
        check()?;
        // Descriptor adoption is an application-owner operation. Do not claim
        // a successful regular-file download has written the caller's FD.
        if request.output_fd > 0 {
            return Err(
                "output descriptor ownership is not yet connected to the Rust download planner"
                    .into(),
            );
        }
        self.set_song_link_region(&request.songlink_region)?;
        let state = self.environment().download_state();
        let lease = Arc::new(
            state
                .acquire(&request.item_id)
                .map_err(|error| error.to_string())?,
        );
        #[cfg(feature = "experimental-progressive-reader")]
        if let Some(operation) = &progressive {
            if !operation.bind(&lease) { return Err("progressive operation is closed or already used".into()); }
        }
        lease.check_active().map_err(|error| error.to_string())?;
        let item_id = request.item_id.clone();
        if !item_id.is_empty() {
            state
                .progress
                .start(&item_id)
                .map_err(|error| error.to_string())?;
            state
                .progress
                .preparing(&item_id, "checking_session")
                .map_err(|error| error.to_string())?;
        }
        // One lease reaches availability, auth, VM and file finalization,
        // including requests without an item ID. Join the VM before returning.
        let result = std::thread::scope(|scope| {
            let (finished, completion) = mpsc::sync_channel(1);
            let request_lease = lease.clone();
            let worker = std::thread::Builder::new()
                .name("download-planner".into())
                .spawn_scoped(scope, move || {
                    let result = self.plan_download(request, request_lease,
                        #[cfg(feature = "experimental-progressive-reader")] progressive);
                    let _ = finished.send(());
                    result
                })
                .map_err(|error| error.to_string())?;
            let mut cancelled = None;
            while !worker.is_finished() {
                if let Err(error) = self.check().and_then(|()| check()) {
                    cancelled = Some(error);
                    lease.release();
                    break;
                }
                // Completion wakes the caller immediately; timeouts retain the
                // owner/caller cancellation heartbeat while work is active.
                if !matches!(
                    completion.recv_timeout(Duration::from_millis(5)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
            let result = worker
                .join()
                .map_err(|_| "download planner panicked".to_owned())?;
            // Publication won the cancellation race. Preserve its actual result
            // even when the outer owner cancelled while the worker was returning.
            if lease.has_committed() {
                return result;
            }
            if let Some(error) = cancelled {
                return Err(error);
            }
            self.check()?;
            check()?;
            lease.check_active().map_err(|error| error.to_string())?;
            result
        });
        if !item_id.is_empty() {
            if result
                .as_ref()
                .is_ok_and(|result| result["success"] == true)
            {
                let _ = state.progress.complete(&item_id);
            } else {
                let _ = state.progress.remove(&item_id);
            }
        }
        result.map(|value| compact(value).to_string())
    }

    fn plan_download(
        &self,
        mut request: DownloadRequest,
        lease: Arc<RequestLease>,
        #[cfg(feature = "experimental-progressive-reader")]
        progressive: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>,
    ) -> Result<Value, String> {
        let check = || {
            self.check()
                .and_then(|()| lease.check_active().map_err(|error| error.to_string()))
        };
        let key = preparation_key(&request);
        let session_provider = if request.service.trim().is_empty() {
            request.source.trim()
        } else {
            request.service.trim()
        }
        .to_owned();
        let selected_account = !request.service.trim().is_empty()
            && self
                .account_download_enabled(&session_provider)
                .map_err(|error| error.to_string())?;
        check()?;
        if !request.temporary_playback && playback_only_provider(&session_provider)
            && (!request.use_fallback || selected_account)
        {
            return Ok(failure(&session_provider,
                "SoundCloud and YouTube are available only for temporary playback, not permanent downloads",
                "provider_unavailable", 0));
        }
        if selected_account {
            // Keep the request on the selected account even if the extension
            // is disabled or removed after this policy check.
            request.use_fallback = false;
            if self.download_manifest(&session_provider).is_err() {
                return Ok(failure(
                    &session_provider,
                    "Provider is unavailable",
                    "provider_unavailable",
                    0,
                ));
            }
        }
        let mut provider_attempts = Vec::new();
        let preflight = if !request.temporary_playback && playback_only_provider(&session_provider) {
            Ok(false)
        } else {
            self.preflight_download(&session_provider, lease.clone())
        };
        check()?;
        let mut preflight_failure = match preflight {
            Ok(true) => { trace_attempt(&mut provider_attempts, &session_provider, "preflight_verification_required", "verification_required"); Some(failure(
                &session_provider,
                "Verification required before download",
                "verification_required",
                0,
            )) },
            Err(error) => { trace_attempt(&mut provider_attempts, &session_provider, "preflight_error", ""); Some(provider_failure(
                &session_provider,
                &error.to_string(),
                "",
                0,
            )) },
            Ok(false) => None,
        };
        if preflight_failure.is_some()
            && (!request.use_fallback
                || self
                    .account_download_enabled(&session_provider)
                    .map_err(|error| error.to_string())?
                || self
                    .download_manifest(&session_provider)
                    .is_ok_and(|m| m.stops_provider_fallback()))
        {
            let response = preflight_failure.take().unwrap();
            if response["error_type"] == "verification_required" {
                self.cache_prepared(&key, &request, false);
            }
            return Ok(with_provider_attempts(response, &provider_attempts));
        }
        let prepared = self.take_prepared(&key, &mut request);
        if !request.item_id.is_empty() {
            let _ = self
                .environment()
                .download_state()
                .progress
                .preparing(&request.item_id, "resolving_metadata");
        }
        let mut selected = request.service.trim().to_owned();
        let priorities: Value = serde_json::from_str(
            &self
                .provider_priorities()
                .map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        let mut priority: Vec<String> = self
            .relay_priority(&priorities, request.temporary_playback)
            .map_err(|error| error.to_string())?;
        if !request.use_fallback {
            if selected.is_empty() {
                selected = request.source.trim().to_owned();
            }
            if !selected.is_empty() {
                priority = vec![selected.clone()];
            }
        } else if !request.service.is_empty() {
            priority.retain(|id| !id.eq_ignore_ascii_case(&request.service));
            priority.insert(0, request.service.clone());
        }

        if prepared == Some(false)
            && (request.temporary_playback || !playback_only_provider(&selected))
            && !request.use_fallback
            && let Some(response) =
                self.download_verified_retry(&request, &selected, lease.clone(),
                    #[cfg(feature = "experimental-progressive-reader")] progressive.clone())?
        {
            return Ok(response);
        }

        // A source catalog can explicitly prohibit replacing its recording.
        let mut source_availability = None;
        if !selected_account
            && !request.source.is_empty()
            && (request.temporary_playback || !playback_only_provider(&request.source))
            && selected != request.source
            && self
                .download_manifest(&request.source)
                .is_ok_and(|m| m.has_type("download_provider"))
        {
            let availability = self.download_availability(&request.source, &request, lease.clone());
            check()?;
            if let Ok(availability) = availability
                && availability["skip_fallback"] == true
            {
                selected = request.source.clone();
                source_availability = Some(availability);
            }
        }
        if prepared != Some(true) {
            self.enrich_download_source(&mut request, lease.clone())?;
        }

        let mut interactive = None;
        let mut best_failure = None;
        let mut quality_retries = Vec::new();
        let relay = permanent_relay(&request);
        let mut relay_pool: Vec<(DownloadRequest, ExtensionManifest, Value)> = Vec::new();
        let mut quality_blocked = BTreeSet::new();
        let mut preflight_blocked = BTreeSet::new();
        let mut attempts = VecDeque::new();
        let mut attempted_provider_tracks = BTreeSet::new();
        let mut playback_only_blocked = false;
        if !request.source.is_empty() && selected == request.source {
            attempts.push_back((request.source.clone(), true));
        }
        let mut fallback = Some(priority);
        loop {
            if attempts.is_empty() {
                let Some(priority) = fallback.take() else {
                    break;
                };
                let protected = if selected.is_empty() {
                    &request.source
                } else {
                    &selected
                };
                let mut priority = self.prioritize_healthy_downloads(priority, protected, &selected)?;
                if request.temporary_playback && request.use_fallback {
                    priority.sort_by_key(|id| playback_only_provider(id) && !id.eq_ignore_ascii_case(&selected));
                }
                attempts.extend(priority.into_iter().map(|id| (id, false)));
            }
            let Some((id, direct)) = attempts.pop_front() else {
                break;
            };
            check()?;
            if !request.temporary_playback && playback_only_provider(&id) {
                playback_only_blocked = true;
                continue;
            }
            if id.is_empty()
                || preflight_blocked.contains(&id.to_ascii_lowercase())
                || (!direct && id == request.source && request.source != selected)
                || (!direct
                    && id != selected
                    && !self
                        .fallback_allowed(&id)
                        .map_err(|error| error.to_string())?)
            {
                continue;
            }
            let Ok(manifest) = self.download_manifest(&id) else {
                continue;
            };
            if !manifest.has_type("download_provider") {
                continue;
            }
            trace_attempt(&mut provider_attempts, &id, "availability", "");
            let account_mode = self
                .account_download_enabled(&id)
                .map_err(|error| error.to_string())?;
            if id.eq_ignore_ascii_case(&session_provider)
                && let Some(mut response) = preflight_failure.take()
            {
                // Even an unavailable provider can explicitly forbid replacement.
                let availability = self.download_availability(&id, &request, lease.clone());
                check()?;
                match availability {
                    Ok(value) if value["skip_fallback"] != true => {}
                    Err(error) => {
                        let availability_failure = provider_failure(&id, &error, "", 0);
                        if availability_failure["error_type"] == "verification_required" {
                            response = availability_failure;
                        }
                    }
                    _ => {
                        if response["error_type"] == "verification_required" {
                            self.cache_prepared(&key, &request, true);
                        }
                        return Ok(response);
                    }
                }
                preflight_blocked.insert(id.to_ascii_lowercase());
                quality_blocked.insert(id.to_ascii_lowercase());
                if response["error_type"] == "verification_required" {
                    interactive = Some(response);
                } else {
                    retain_provider_failure(&mut best_failure, response);
                }
                continue;
            }
            let availability = if direct {
                source_availability
                    .clone()
                    .unwrap_or_else(|| json!({"available":true}))
            } else {
                let available = self.preflight_download(&id, lease.clone()).map_err(|error| {
                    trace_attempt(&mut provider_attempts, &id, "preflight_error", "");
                    error.to_string()
                })
                    .and_then(|verification| {
                        if verification {
                            trace_attempt(&mut provider_attempts, &id, "preflight_verification_required", "verification_required");
                            Err(format!("verification_required: extension '{id}' needs signed-session verification"))
                        } else {
                            self.download_availability(&id, &request, lease.clone()).map_err(|error| {
                                trace_attempt(&mut provider_attempts, &id, availability_error_stage(&error), "");
                                error
                            })
                        }
                    });
                check()?;
                match available {
                    Ok(value) => value,
                    Err(error) => {
                        quality_blocked.insert(id.to_ascii_lowercase());
                        let response = provider_failure(&id, &error, "", 0);
                        if account_mode {
                            return Ok(with_provider_attempts(response, &provider_attempts));
                        }
                        if response["error_type"] == "verification_required" {
                            // Preserve a known prohibition, but retain the
                            // challenge while trying independent providers.
                            let policy = self.download_availability(&id, &request, lease.clone());
                            check()?;
                            if !request.use_fallback
                                || manifest.stops_provider_fallback()
                                || policy.is_ok_and(|value| value["skip_fallback"] == true)
                            {
                                self.cache_prepared(&key, &request, true);
                                return Ok(with_provider_attempts(response, &provider_attempts));
                            }
                            preflight_blocked.insert(id.to_ascii_lowercase());
                            interactive = Some(response);
                            continue;
                        }
                        retain_provider_failure(&mut best_failure, response);
                        continue;
                    }
                }
            };
            let stop = availability["skip_fallback"] == true || account_mode;
            if availability["available"] != true {
                trace_attempt_details(&mut provider_attempts, &id, "availability_response_unavailable", text(&availability, "error_type"), &[("reason_class", Value::from(availability_reason_class(text(&availability, "reason"))))]);
                quality_blocked.insert(id.to_ascii_lowercase());
                let response = unavailable_provider_failure(&id, &availability);
                if response["error_type"] == "verification_required" {
                    if stop || manifest.stops_provider_fallback() || !request.use_fallback {
                        self.cache_prepared(&key, &request, true);
                        return Ok(with_provider_attempts(response, &provider_attempts));
                    }
                    preflight_blocked.insert(id.to_ascii_lowercase());
                    interactive = Some(response);
                    continue;
                }
                if stop {
                    return Ok(with_provider_attempts(stopped_provider_failure(&id, &availability, None), &provider_attempts));
                }
                retain_provider_failure(&mut best_failure, response);
                continue;
            }
            let (track_id, id_source) = if direct {
                let explicit = text(&availability, "track_id");
                let from_availability = !explicit.trim().is_empty();
                let explicit = if from_availability { explicit } else { &request.provider_track_id };
                let resolved = preferred_track_id(&request, &manifest, explicit);
                let source = if resolved.trim().is_empty() {
                    "empty"
                } else if from_availability {
                    "availability"
                } else if !request.provider_track_id.trim().is_empty() {
                    "request"
                } else {
                    "native_alias"
                };
                (resolved, source)
            } else {
                let resolved = text(&availability, "track_id").to_owned();
                let source = if resolved.trim().is_empty() { "empty" } else { "availability" };
                (resolved, source)
            };
            let mut attempt = request.clone();
            attempt.download_provider = id.clone();
            attempt.provider_track_id = track_id;
            let id_len = attempt.provider_track_id.chars().count();
            if !first_unique_provider_attempt(&mut attempted_provider_tracks, &id, &attempt.provider_track_id, &attempt.quality) {
                continue;
            }
            if !direct {
                attempt.output_ext.clear();
            }
            let outcome =
                self.download_resolved(&attempt, &manifest, &availability, lease.clone(),
                    #[cfg(feature = "experimental-progressive-reader")] progressive.clone())?;
            if !lease.has_committed() {
                check()?;
            }
            let response = match outcome {
                DownloadOutcome::Final(response) => {
                    if response["success"] == false {
                        trace_attempt_details(&mut provider_attempts, &id, "download", text(&response, "error_type"), &download_trace_details(id_source, id_len, &response));
                        return Ok(with_provider_attempts(response, &provider_attempts));
                    }
                    return Ok(response);
                }
                DownloadOutcome::Retry(response) => response,
            };
            let message = text(&response, "error");
            let kind = text(&response, "error_type");
            trace_attempt_details(&mut provider_attempts, &id, "download", kind, &download_trace_details(id_source, id_len, &response));
            let retry = response["retry_after_seconds"].as_i64().unwrap_or_default();
            if account_mode
                || self
                    .account_download_enabled(&id)
                    .map_err(|error| error.to_string())?
            {
                return Ok(with_provider_attempts(inherit_diagnostic_cause(
                    failure(&id, &format!("Download failed: {message}"), kind, retry),
                    &response,
                ), &provider_attempts));
            }
            if kind == "verification_required" {
                quality_blocked.insert(id.to_ascii_lowercase());
                preflight_blocked.insert(id.to_ascii_lowercase());
                let response = failure(&id, &format!("Download failed: {message}"), kind, retry);
                if stop || manifest.stops_provider_fallback() || !request.use_fallback {
                    self.cache_prepared(&key, &request, true);
                    return Ok(with_provider_attempts(response, &provider_attempts));
                }
                interactive = Some(response);
                continue;
            }
            if storage_failure(kind, message) {
                return Ok(with_provider_attempts(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    "permission",
                    retry,
                ), &provider_attempts));
            }
            if stop {
                return Ok(with_provider_attempts(stopped_provider_failure(&id, &availability, Some(response)), &provider_attempts));
            }
            if direct && manifest.stops_provider_fallback() {
                return Ok(with_provider_attempts(inherit_diagnostic_cause(
                    failure(&id, &format!("Download failed: {message}"), kind, retry),
                    &response,
                ), &provider_attempts));
            }
            if kind != "quality_unavailable" {
                quality_blocked.insert(id.to_ascii_lowercase());
            }
            if relay {
                if kind == "quality_unavailable"
                    && !relay_pool.iter().any(|(_, prior, _)| prior.name.eq_ignore_ascii_case(&manifest.name))
                {
                    // The tier this pass already asked for must not be repeated.
                    let source = self.quality_source(&attempt, &manifest);
                    if let Some(first) = manifest
                        .relay_candidates(&attempt.quality, source.as_ref())
                        .into_iter()
                        .find(|candidate| candidate.family)
                    {
                        first_unique_provider_attempt(&mut attempted_provider_tracks, &manifest.name, &attempt.provider_track_id, &first.id);
                    }
                    relay_pool.push((attempt, manifest, availability));
                }
            } else if request.allow_quality_fallback
                && kind == "quality_unavailable"
                && !quality_retries.iter().any(
                    |(_, prior, _, _): &(DownloadRequest, ExtensionManifest, Value, String)| {
                        prior.name.eq_ignore_ascii_case(&manifest.name)
                    },
                )
            {
                let source = [&attempt.service, &attempt.source]
                    .into_iter()
                    .filter_map(|id| self.download_manifest(id.trim()).ok())
                    .find(|source| source.find_quality(attempt.quality.trim()).is_some());
                let attempted_quality = manifest
                    .resolve_download_quality(&attempt.quality, source.as_ref())
                    .unwrap_or_else(|_| attempt.quality.clone());
                quality_retries.push((attempt, manifest, availability, attempted_quality));
            }
            retain_provider_failure(&mut best_failure, response);
        }
        check()?;
        // Relay descent: class by class, every provider (in relay order) is
        // asked for its tier of that class before any provider is asked for a
        // lower one. Each tier is still verified against what it claims.
        let mut relay_plan = Vec::new();
        for (order, (attempt, manifest, _)) in relay_pool.iter().enumerate() {
            let source = self.quality_source(attempt, manifest);
            for candidate in manifest.relay_candidates(&attempt.quality, source.as_ref()) {
                relay_plan.push((candidate.level, order, candidate.id));
            }
        }
        relay_plan.sort_by_key(|(level, order, _)| (*level, *order));
        for (_, order, quality) in relay_plan {
            check()?;
            let (base, manifest, availability) = &relay_pool[order];
            let name = manifest.name.to_ascii_lowercase();
            if quality_blocked.contains(&name)
                || self.account_download_enabled(&manifest.name).map_err(|error| error.to_string())?
                || !first_unique_provider_attempt(&mut attempted_provider_tracks, &manifest.name, &base.provider_track_id, &quality)
            {
                continue;
            }
            let mut attempt = base.clone();
            attempt.quality = quality;
            let outcome =
                self.download_attempt(&attempt, manifest, availability, lease.clone(),
                    #[cfg(feature = "experimental-progressive-reader")] progressive.clone())?;
            if !lease.has_committed() {
                check()?;
            }
            match outcome {
                DownloadOutcome::Final(mut response) => {
                    if response["success"] == false {
                        trace_attempt(&mut provider_attempts, &manifest.name, "download", text(&response, "error_type"));
                        return Ok(with_provider_attempts(response, &provider_attempts));
                    }
                    response["requested_quality"] = request.quality.clone().into();
                    if response["already_exists"] != true {
                        response["resolved_quality"] = attempt.quality.clone().into();
                    }
                    response["quality_fallback_used"] = (response["already_exists"] != true
                        && !request.quality.trim().is_empty()
                        && !attempt.quality.eq_ignore_ascii_case(request.quality.trim()))
                    .into();
                    response["provider"] = manifest.name.clone().into();
                    return Ok(response);
                }
                DownloadOutcome::Retry(response) => {
                    let kind = text(&response, "error_type");
                    trace_attempt(&mut provider_attempts, &manifest.name, "download", kind);
                    if storage_failure(kind, text(&response, "error")) {
                        return Ok(with_provider_attempts(response, &provider_attempts));
                    }
                    if kind == "verification_required" {
                        quality_blocked.insert(name);
                        if !request.use_fallback
                            || availability["skip_fallback"] == true
                            || manifest.stops_provider_fallback()
                        {
                            self.cache_prepared(&key, &request, true);
                            return Ok(with_provider_attempts(response, &provider_attempts));
                        }
                        interactive = Some(response);
                        continue;
                    }
                    if kind != "quality_unavailable" {
                        // Another tier cannot cure an auth, network or catalog failure.
                        quality_blocked.insert(name);
                    }
                    retain_provider_failure(&mut best_failure, response);
                }
            }
        }
        for (mut attempt, manifest, availability, attempted_quality) in quality_retries {
            check()?;
            // A forced alternate tier is only valid on the original provider.
            if !request.temporary_playback && !manifest.name.eq_ignore_ascii_case(request.service.trim()) {
                continue;
            }
            if quality_blocked.contains(&manifest.name.to_ascii_lowercase()) {
                continue;
            }
            if self
                .account_download_enabled(&manifest.name)
                .map_err(|error| error.to_string())?
            {
                break;
            }
            let Some(quality) = manifest.first_alternative_quality(&attempted_quality) else {
                continue;
            };
            attempt.quality = quality.to_owned();
            let outcome =
                self.download_attempt(&attempt, &manifest, &availability, lease.clone(),
                    #[cfg(feature = "experimental-progressive-reader")] progressive.clone())?;
            if !lease.has_committed() {
                check()?;
            }
            match outcome {
                DownloadOutcome::Final(mut response) => {
                    if response["success"] == true {
                        response["requested_quality"] = request.quality.clone().into();
                        if response["already_exists"] != true {
                            response["resolved_quality"] = attempt.quality.clone().into();
                        }
                        response["quality_fallback_used"] =
                            (response["already_exists"] != true).into();
                        response["provider"] = manifest.name.clone().into();
                    }
                    if response["success"] == false {
                        trace_attempt(&mut provider_attempts, &manifest.name, "download", text(&response, "error_type"));
                        return Ok(with_provider_attempts(response, &provider_attempts));
                    }
                    return Ok(response);
                }
                DownloadOutcome::Retry(response) => {
                    let kind = text(&response, "error_type");
                    trace_attempt(&mut provider_attempts, &manifest.name, "download", kind);
                    if storage_failure(kind, text(&response, "error")) {
                        return Ok(with_provider_attempts(response, &provider_attempts));
                    }
                    if kind == "verification_required" {
                        quality_blocked.insert(manifest.name.to_ascii_lowercase());
                        if !request.use_fallback
                            || availability["skip_fallback"] == true
                            || manifest.stops_provider_fallback()
                        {
                            self.cache_prepared(&key, &request, true);
                            return Ok(with_provider_attempts(response, &provider_attempts));
                        }
                        interactive = Some(response);
                        continue;
                    }
                    retain_provider_failure(&mut best_failure, response);
                }
            }
        }
        if let Some(response) = interactive.or_else(|| {
            preflight_failure.take_if(|response| response["error_type"] == "verification_required")
        }) {
            self.cache_prepared(&key, &request, true);
            return Ok(with_provider_attempts(response, &provider_attempts));
        }
        if let Some(response) = preflight_failure {
            retain_provider_failure(&mut best_failure, response);
        }
        let mut response = match best_failure {
            Some(best) => inherit_diagnostic_cause(
                failure(
                    text(&best, "service"),
                    &format!("All providers failed. Last error: {}", text(&best, "error")),
                    text(&best, "error_type"),
                    best["retry_after_seconds"].as_i64().unwrap_or_default(),
                ),
                &best,
            ),
            None if playback_only_blocked => failure(
                "",
                "SoundCloud and YouTube are available only for temporary playback, not permanent downloads",
                "provider_unavailable",
                0,
            ),
            None => failure(
                "",
                "No extension download providers available",
                "provider_unavailable",
                0,
            ),
        };
        if !provider_attempts.is_empty() {
            response["provider_attempts"] = provider_attempts.into();
        }
        Ok(response)
    }

    /// A preflight challenge can be satisfied without consulting optional
    /// metadata providers again. A different download source still gets its
    /// normal opportunity to prohibit fallback before any selected download.
    fn download_verified_retry(
        &self,
        request: &DownloadRequest,
        selected: &str,
        lease: Arc<RequestLease>,
        #[cfg(feature = "experimental-progressive-reader")]
        progressive: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>,
    ) -> Result<Option<Value>, String> {
        if selected.is_empty()
            || (!request.source.is_empty()
                && !request.source.eq_ignore_ascii_case(selected)
                && self
                    .download_manifest(&request.source)
                    .is_ok_and(|manifest| manifest.has_type("download_provider")))
        {
            return Ok(None);
        }
        let Ok(manifest) = self.download_manifest(selected) else {
            return Ok(None);
        };
        if !manifest.has_type("download_provider") {
            return Ok(None);
        }
        let direct = request.source.eq_ignore_ascii_case(selected);
        let availability = if direct {
            json!({"available":true})
        } else {
            let result = self.download_availability(selected, request, lease.clone());
            lease.check_active().map_err(|error| error.to_string())?;
            match result {
                Ok(value) => value,
                Err(error) => {
                    let response = provider_failure(selected, &error, "", 0);
                    return Ok(
                        (response["error_type"] == "verification_required").then_some(response)
                    );
                }
            }
        };
        if availability["available"] != true {
            return Ok((availability["skip_fallback"] == true)
                .then(|| stopped_provider_failure(selected, &availability, None)));
        }
        let mut attempt = request.clone();
        attempt.download_provider = selected.into();
        attempt.provider_track_id =
            preferred_track_id(request, &manifest, text(&availability, "track_id"));
        if !direct {
            attempt.output_ext.clear();
        }
        let outcome = self.download_resolved(&attempt, &manifest, &availability, lease.clone(),
            #[cfg(feature = "experimental-progressive-reader")] progressive)?;
        if !lease.has_committed() {
            lease.check_active().map_err(|error| error.to_string())?;
        }
        let response = match outcome {
            DownloadOutcome::Final(response) => return Ok(Some(response)),
            DownloadOutcome::Retry(response) => response,
        };
        let message = text(&response, "error");
        let kind = text(&response, "error_type");
        let retry = response["retry_after_seconds"].as_i64().unwrap_or_default();
        if kind == "verification_required" || storage_failure(kind, message) {
            return Ok(Some(failure(
                selected,
                &format!("Download failed: {message}"),
                if kind == "verification_required" {
                    kind
                } else {
                    "permission"
                },
                retry,
            )));
        }
        // Ordinary failures may recover after source enrichment supplies a
        // better native track ID. Preserve the normal strict/fallback path.
        Ok(None)
    }

    fn download_resolved(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
        availability: &Value,
        lease: Arc<RequestLease>,
        #[cfg(feature = "experimental-progressive-reader")]
        progressive: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>,
    ) -> Result<DownloadOutcome, String> {
        let source = if request.service.trim().eq_ignore_ascii_case(&manifest.name) {
            Some(manifest.clone())
        } else {
            self.download_manifest(request.service.trim()).ok()
        };
        // A changed live declaration cannot silently replace the user's saved
        // quality intent, even when both providers now advertise the new value.
        let relay = permanent_relay(request);
        if !request.temporary_playback
            && !relay
            && !request.quality_source_provider.trim().is_empty()
            && request.service.trim().eq_ignore_ascii_case(request.quality_source_provider.trim())
            && !request.quality_source_id.trim().is_empty()
            && request.quality_source_id.trim().eq_ignore_ascii_case(request.quality.trim())
        {
            let saved = crate::manifest::QualityOption {
                id: request.quality_source_id.trim().into(),
                kind: request.quality_source_kind.trim().into(),
                label: request.quality_source_label.trim().into(),
                ..Default::default()
            };
            if source.as_ref().and_then(|s| s.find_quality(&request.quality))
                .is_some_and(|live| crate::manifest::quality_claims_conflict(live, &saved))
            {
                return Ok(DownloadOutcome::Final(quality_failure(
                    &request.download_provider,
                    "saved quality contradicts the current source manifest",
                    DiagnosticCause::QualitySelectionUnavailable,
                )));
            }
        }
        let source = if !request.quality_source_provider.trim().is_empty()
            && request.quality_source_id.trim().eq_ignore_ascii_case(request.quality.trim())
            && request.service.trim().eq_ignore_ascii_case(request.quality_source_provider.trim())
        {
            let live = self.download_manifest(request.quality_source_provider.trim()).ok();
            source_with_request_quality(request, live).or(source)
        } else { source };
        let quality_result = if relay {
            manifest
                .relay_candidates(&request.quality, source.as_ref())
                .into_iter()
                .find(|candidate| candidate.family)
                .map(|candidate| candidate.id)
                .ok_or_else(|| format!(
                    "provider {} has no quality equivalent to requested quality {:?}",
                    manifest.name, request.quality.trim()
                ))
        } else if request.allow_quality_fallback
            && (request.temporary_playback || manifest.name.eq_ignore_ascii_case(request.service.trim())) {
            manifest.resolve_download_quality(&request.quality, source.as_ref())
        } else if request.use_fallback && request.allow_saved_quality_id_fallback {
            manifest.resolve_saved_quality_id(&request.quality, source.as_ref())
        } else {
            manifest.resolve_strict_download_quality(&request.quality, source.as_ref())
        };
        let quality = match quality_result {
            Ok(quality) => quality,
            Err(error) => {
                return Ok(DownloadOutcome::Retry(quality_failure(
                    &request.download_provider,
                    &error,
                    DiagnosticCause::QualitySelectionUnavailable,
                )));
            }
        };
        let mut attempt = request.clone();
        attempt.quality = quality;
        let mut outcome = self.download_attempt(&attempt, manifest, availability, lease,
            #[cfg(feature = "experimental-progressive-reader")] progressive)?;
        if let DownloadOutcome::Final(response) = &mut outcome {
            if response["success"] == true {
                report_selected_quality(response, request, &attempt.quality);
                response["quality_fallback_used"] = ((request.allow_quality_fallback
                    || (relay && !request.quality.trim().is_empty()))
                    && !attempt.quality.eq_ignore_ascii_case(request.quality.trim())
                    && response["already_exists"] != true)
                    .into();
                response["provider"] = manifest.name.clone().into();
            }
        }
        Ok(outcome)
    }

    /// The manifest that explains what the requested quality ID means: the
    /// selected service, completed by the saved declaration when it applies.
    fn quality_source(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
    ) -> Option<ExtensionManifest> {
        let source = if request.service.trim().eq_ignore_ascii_case(&manifest.name) {
            Some(manifest.clone())
        } else {
            self.download_manifest(request.service.trim()).ok()
        };
        if !request.quality_source_provider.trim().is_empty()
            && request.quality_source_id.trim().eq_ignore_ascii_case(request.quality.trim())
            && request.service.trim().eq_ignore_ascii_case(request.quality_source_provider.trim())
        {
            let live = self.download_manifest(request.quality_source_provider.trim()).ok();
            source_with_request_quality(request, live).or(source)
        } else {
            source
        }
    }

    fn download_availability(
        &self,
        id: &str,
        request: &DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<Value, String> {
        let input = ProviderAvailabilityRequest {
            isrc: request.isrc.clone(),
            track_name: request.track_name.clone(),
            artist_name: request.artist_name.clone(),
            spotify_id: request.spotify_id.clone(),
            deezer_id: request.deezer_id.clone(),
            tidal_id: request.tidal_id.clone(),
            qobuz_id: request.qobuz_id.clone(),
            duration_ms: request.duration_ms as isize,
            item_id: request.item_id.clone(),
            track: host_track(request).as_object().cloned(),
        };
        self.check_availability_with_lease(id, input, 30_000, Some(lease))
            .map_err(|error| error.to_string())
            .and_then(|raw| serde_json::from_str::<Value>(&raw).map_err(|error| error.to_string()))
    }

    fn enrich_download_source(
        &self,
        request: &mut DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<(), String> {
        if request.source.is_empty() {
            return Ok(());
        }
        if self
            .download_manifest(&request.source)
            .is_ok_and(|manifest| manifest.has_type("metadata_provider"))
        {
            let mut input = host_track(request);
            input["id"] = request.spotify_id.clone().into();
            for (key, value) in [
                ("provider_id", &request.source),
                ("spotify_id", &request.spotify_id),
                ("tidal_id", &request.tidal_id),
                ("qobuz_id", &request.qobuz_id),
                ("deezer_id", &request.deezer_id),
            ] {
                input[key] = value.clone().into();
            }
            let result = self.enrich_track_with_lease(
                &request.source,
                &input.to_string(),
                &request.item_id,
                30_000,
                Some(lease.clone()),
            );
            lease.check_active().map_err(|error| error.to_string())?;
            if let Ok(raw) = result
                && let Ok(track) = serde_json::from_str::<Value>(&raw)
            {
                apply_metadata(request, &track, true);
            }
        }
        if !request.track_name.is_empty()
            && !request.artist_name.is_empty()
            && (request.album_name.is_empty()
                || request.release_date.is_empty()
                || request.isrc.is_empty())
        {
            let result = self.search_metadata_providers_with_lease(
                &format!("{} {}", request.track_name, request.artist_name),
                5,
                true,
                &request.item_id,
                30_000,
                Some(lease.clone()),
            );
            lease.check_active().map_err(|error| error.to_string())?;
            if let Ok(raw) = result
                && let Ok(tracks) = serde_json::from_str::<Vec<Value>>(&raw)
                && let Some(track) = select_download_metadata(request, &tracks)
            {
                apply_metadata(request, track, false);
            }
        }
        Ok(())
    }

    fn download_attempt(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
        availability: &Value,
        lease: Arc<RequestLease>,
        #[cfg(feature = "experimental-progressive-reader")]
        progressive: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>,
    ) -> Result<DownloadOutcome, String> {
        #[cfg(feature = "experimental-progressive-reader")]
        struct AttemptScope { operation: Option<Arc<crate::download::progressive_candidate::ProgressiveOperation>>, completed: bool }
        #[cfg(feature = "experimental-progressive-reader")]
        impl Drop for AttemptScope {
            fn drop(&mut self) { if !self.completed { if let Some(operation) = &self.operation { operation.reject_current(); } } }
        }
        #[cfg(feature = "experimental-progressive-reader")]
        let mut progressive_scope = {
            if let Some(operation) = &progressive { operation.reject_current(); }
            AttemptScope { operation: progressive.clone(), completed: false }
        };
        let check = || {
            self.check()
                .and_then(|()| lease.check_active().map_err(|error| error.to_string()))
        };
        let environment = self.environment();
        let files = environment.native_files()?;
        let directory = environment
            .data_directory()
            .join(&manifest.name)
            .join("downloads");
        let path = output_path(request, &directory, &request.album_name, &check)?;
        let output = files.resolve_legacy(&path)?;
        output.native_display()?;
        let guard = files.lock(&output, &check)?;
        // The output lock serializes this destination. Unknown prior attempts
        // are never reclaimed here: a replaced registry/process-local owner is
        // not proof that an external producer stopped. Only their live owner
        // and typed terminal acknowledgements may clean them up.
        let staging_prefix = format!(
            ".mornye-download-{}-",
            crate::binary::encode(
                &Sha256::digest(output.display().to_lowercase().as_bytes()),
                "hex"
            )
            .expect("hex encoding")
        );
        if !request.allow_quality_variant
            && (request.album_folder_template.is_empty()
                || !album_folder(request, &request.album_name).is_empty())
            && output
                .metadata()
                .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
        {
            let mut result = json!({"file_path":path});
            probe_result(&files, &mut result, false, &check)?;
            if !strict_codec_matches(request, manifest, &result) {
                return Ok(DownloadOutcome::Final(strict_quality_failure(
                    &manifest.name,
                    "existing file codec does not match the requested quality; existing file was preserved",
                    &result,
                )));
            }
            let mut response = success(request, &result, &path, true, manifest, &check)?;
            response
                .as_object_mut()
                .unwrap()
                .remove("skip_metadata_enrichment");
            return Ok(DownloadOutcome::Final(response));
        }
        // Give the extension its own temporary directory. A mismatched track,
        // failed provider or cancellation can never overwrite an old library file.
        let temporary_parent =
            files.resolve_legacy(&directory.join(".parent").to_string_lossy())?;
        temporary_parent.native_display()?;
        temporary_parent
            .mkdir_parent()
            .map_err(|error| format!("failed to create directory: {error}"))?;
        let temporary = tempfile::Builder::new()
            .prefix(&staging_prefix)
            .tempdir_in(&directory)
            .map_err(|error| format!("failed to create directory: {error}"))?;
        let temporary = environment.ffmpeg_commands()
            .protect_download_staging(&manifest.name, temporary)
            .map_err(|error| error.to_string())?;
        let _grant = environment.grant_temporary_download_directory(temporary.path())?;
        let name = filename(request, &request.output_ext, &check)?;
        let staging_path = temporary.path().join(name).to_string_lossy().into_owned();
        let mut prepared = availability["prepared_context"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        prepared.insert("host_track".into(), host_track(request));
        if !request.item_id.is_empty() {
            let _ = environment
                .download_state()
                .progress
                .preparing(&request.item_id, "resolving_stream");
        }
        #[cfg(feature = "experimental-private-mov")]
        let private_capability = self.private_mov_finalizer.read().expect("private finalizer lock");
        #[cfg(feature = "experimental-private-mov")]
        let private_finalizer = private_capability.clone();
        #[cfg(feature = "experimental-private-mov")]
        let mut private_decryption = None;
        let provider_request = ProviderDownloadRequest {
            track_id: request.provider_track_id.clone(),
            quality: request.quality.clone(),
            output_path: staging_path,
            item_id: request.item_id.clone(),
            prepared_context: Some(prepared),
        };
        #[cfg(feature = "experimental-private-mov")]
        let response = if private_finalizer.is_some() {
            #[cfg(feature = "experimental-progressive-reader")]
            if progressive.is_some() { return Err("progressive private finalization is unavailable".into()); }
            self.download_private_with_lease(&manifest.name, provider_request, 60_000, Some(lease.clone()))
                .map(|response| {
                    private_decryption = response.decryption;
                    response.metadata
                })
        } else {
            #[cfg(feature = "experimental-progressive-reader")]
            let raw = if let Some(operation) = &progressive {
                self.download_with_progressive_lease(&manifest.name, provider_request, 60_000, lease.clone(), operation.clone())
            } else { self.download_with_lease(&manifest.name, provider_request, 60_000, Some(lease.clone())) };
            #[cfg(not(feature = "experimental-progressive-reader"))]
            let raw = self.download_with_lease(&manifest.name, provider_request, 60_000, Some(lease.clone()));
            raw
                .and_then(|raw| {
                    let raw = zeroize::Zeroizing::new(raw);
                    serde_json::from_str(&raw).map_err(|_| crate::manager::ManagerError("invalid download result".into()))
                })
        };
        #[cfg(not(feature = "experimental-private-mov"))]
        let response = {
            #[cfg(feature = "experimental-progressive-reader")]
            let raw = if let Some(operation) = &progressive {
                self.download_with_progressive_lease(&manifest.name, provider_request, 60_000, lease.clone(), operation.clone())
            } else { self.download_with_lease(&manifest.name, provider_request, 60_000, Some(lease.clone())) };
            #[cfg(not(feature = "experimental-progressive-reader"))]
            let raw = self.download_with_lease(&manifest.name, provider_request, 60_000, Some(lease.clone()));
            raw.and_then(|raw| {
            let raw = zeroize::Zeroizing::new(raw);
            serde_json::from_str(&raw).map_err(|_| crate::manager::ManagerError("invalid download result".into()))
            })
        };
        #[cfg(feature = "experimental-private-mov")]
        drop(private_capability);
        check()?;
        let mut result: Value = match response {
            Ok(value) => value,
            Err(error) => {
                return Ok(DownloadOutcome::Retry(provider_failure(
                    &manifest.name,
                    &error.to_string(),
                    "",
                    0,
                )));
            }
        };
        if result["success"] != true {
            return Ok(DownloadOutcome::Retry(provider_failure_from_result(&manifest.name, &result)));
        }
        let skip_names = request.source.trim().eq_ignore_ascii_case(&manifest.name)
            || manifest
                .track_matching
                .as_ref()
                .is_some_and(|matching| matching.custom_matching);
        if !matches_track(request, &result, skip_names) {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                &format!("provider {} returned a different track", manifest.name),
                "not_found",
                0,
            )));
        }
        let returned = text(&result, "file_path").trim();
        let returned = returned
            .strip_prefix("EXISTS:")
            .unwrap_or(returned)
            .to_owned();
        let input = files.resolve_legacy(&returned)?;
        input.native_display()?;
        // The provider receives a fresh attempt directory. Its already_exists
        // flag (or EXISTS: prefix) cannot confer ownership of a library file or
        // authorize handing an external file to a destructive finalizer.
        if !crate::files::clean(Path::new(&returned)).starts_with(temporary.path()) {
            #[cfg(feature = "experimental-progressive-reader")]
            if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("backend_stage=outside_staging"); }
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                "provider output is outside its download staging directory",
                "file_error",
                0,
            )));
        }
        if !input
            .metadata()
            .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
        {
            #[cfg(feature = "experimental-progressive-reader")]
            if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("backend_stage=empty_or_missing"); }
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                "provider returned no audio file",
                "file_error",
                0,
            )));
        }
        result["file_path"] = returned.clone().into();
        #[cfg(feature = "experimental-private-mov")]
        let privately_encrypted = private_decryption.is_some();
        #[cfg(not(feature = "experimental-private-mov"))]
        let privately_encrypted = false;
        #[cfg(feature = "experimental-progressive-reader")]
        if progressive.is_some() && (privately_encrypted || result.get("decryption").is_some_and(|v| !v.is_null()) || result.get("decryption_key").is_some_and(|v| !v.is_null() && v != "")) {
            if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("backend_stage=encrypted"); }
            return Ok(DownloadOutcome::Retry(failure(&manifest.name, "encrypted progressive audio is unavailable", "file_error", 0)));
        }
        let mut relay_unverified = false;
        if !request.allow_quality_fallback
            && !request.quality.trim().is_empty()
            && (privately_encrypted || result
                .get("decryption")
                .is_some_and(|value| !value.is_null())
                || result
                    .get("decryption_key")
                    .is_some_and(|value| !value.is_null() && value != ""))
        {
            #[cfg(feature = "experimental-private-mov")]
            if let Some(finalizer) = private_finalizer
                && encrypted::supports_request(request)
                && let Some(decryption) = private_decryption
            {
                return encrypted::finalize_local(self, finalizer, request, manifest, decryption, &input, &output, &path, lease.clone(), &check);
            }
            // A relayed download accepts provider-encrypted audio: it cannot be
            // measured before decryption, so it is published as unverified and
            // the application measures the decrypted file.
            if !permanent_relay(request) || privately_encrypted {
                return Ok(DownloadOutcome::Retry(quality_failure(
                    &manifest.name,
                    "encrypted audio cannot yet be validated before publication for a strict quality request",
                    DiagnosticCause::EncryptedValidationGuard,
                )));
            }
            relay_unverified = true;
        }
        // A private descriptor may never fall through to the old post-publication
        // finalizers, including permissive/unspecified-quality requests.
        if privately_encrypted {
            return Ok(DownloadOutcome::Final(quality_failure(
                &manifest.name,
                "private encrypted finalization is unavailable for this request",
                DiagnosticCause::EncryptedFinalizationUnavailable,
            )));
        }
        let mut enriched = request.clone();
        if !manifest.skip_metadata_enrichment {
            self.enrich_download_extended(&mut enriched, &check)?;
        }
        let request = &enriched;
        // Experimental streaming must validate and later consume the same
        // provider-owned inode; probing a path and reopening it allows a
        // replacement between validation and finalization.
        #[cfg(feature = "experimental-progressive-reader")]
        let mut progressive_source = input.open_native_read().map_err(|error| error.to_string())?;
        #[cfg(feature = "experimental-progressive-reader")]
        let container = probe_open_file(
            &mut progressive_source,
            &returned,
            &mut result,
            request.album_name.trim().is_empty()
                && request.album_folder_template.contains("{album}"),
            &check,
        )?;
        #[cfg(not(feature = "experimental-progressive-reader"))]
        let container = probe_result(
            &files,
            &mut result,
            request.album_name.trim().is_empty()
                && request.album_folder_template.contains("{album}"),
            &check,
        )?;
        if !relay_unverified && !strict_codec_matches(request, manifest, &result) {
            return Ok(DownloadOutcome::Retry(strict_quality_failure(
                &manifest.name,
                "provider returned audio whose codec does not match the requested quality (or could not be verified)",
                &result,
            )));
        }
        let mut response = success(request, &result, &path, false, manifest, &check)?;
        if relay_unverified {
            response["quality_verification"] = "encrypted_unverified".into();
        }
        if text(&response, "actual_extension") == ".flac" && container != "flac" {
            // Unrecognized bytes behind a FLAC label, such as an error page,
            // cannot take FLAC tags. Another provider may return real audio.
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                &format!(
                    "provider {} returned a file that is not FLAC audio",
                    manifest.name
                ),
                "file_error",
                0,
            )));
        }
        if !request.item_id.is_empty() {
            let _ = environment
                .download_state()
                .progress
                .finalizing(&request.item_id);
        }

        let mut resolved = request.clone();
        resolved.output_ext = text(&response, "actual_extension").to_owned();
        if !request.output_path.is_empty() {
            // SAF uses a local working path too. Keep its directory and stem,
            // but use the provider's actual container before final publication.
            resolved.output_path = Path::new(&request.output_path)
                .with_extension(resolved.output_ext.trim_start_matches('.'))
                .to_string_lossy()
                .into_owned();
        }
        let final_path = output_path(&resolved, &directory, text(&response, "album"), &check)?;
        // Keep the original lock for an unchanged destination. Release it
        // before acquiring a different path lock to avoid lock-order cycles.
        let destination = files.resolve_legacy(&final_path)?;
        destination.native_display()?;
        let _guard = if final_path == path {
            guard
        } else {
            drop(guard);
            files.lock(&destination, &check)?
        };
        if final_path != path && destination.metadata().is_ok() {
            return Ok(DownloadOutcome::Final(failure(
                &manifest.name,
                &format!("resolve album folder: open {final_path}: file exists"),
                "file_error",
                0,
            )));
        }
        #[cfg(feature = "experimental-progressive-reader")]
        let mut source = progressive_source;
        #[cfg(not(feature = "experimental-progressive-reader"))]
        let mut source = input
            .open_native_read()
            .map_err(|error| error.to_string())?;
        let info = source.metadata().map_err(|error| error.to_string())?;
        if !info.is_file() || info.len() == 0 {
            return Err("provider returned no audio file".into());
        }
        #[cfg(feature = "experimental-progressive-reader")]
        source.seek(std::io::SeekFrom::Start(0)).map_err(|error| error.to_string())?;
        // ReplayGain, decryption/conversion, external LRC and extension hooks
        // are executed by the existing Android/Dart finalizers. This is the
        // Go backend's local FLAC embed step; provider lyrics are reused.
        let embed = request.embed_metadata && resolved.output_ext == ".flac";
        #[cfg(feature = "experimental-progressive-reader")]
        if progressive.is_some() && embed {
            return Ok(DownloadOutcome::Retry(failure(&manifest.name, "modified progressive audio is unavailable", "file_error", 0)));
        }
        let cover = if embed {
            let url = [request.cover_url.as_str(), text(&response, "cover_url")]
                .into_iter()
                .map(str::trim)
                .find(|url| !url.is_empty())
                .unwrap_or_default();
            if url.is_empty() {
                None
            } else {
                self.cover
                    .download(url, request.cover_max_dimension, &check)
                    .ok()
            }
        } else {
            None
        };
        check()?;
        let strict_local = !request.allow_quality_fallback && !request.quality.trim().is_empty();
        // Strict publication must own its bytes independently of the provider;
        // a hard link would keep a writable alias to the validated artifact.
        let (mut staged, promoted) = if embed || strict_local {
            destination.stage().map(|stage| (stage, false))
        } else {
            destination.stage_from(&input, &source)
        }
        .map_err(|error| format!("failed to create file: {error}"))?;
        if embed {
            let cover = cover.as_deref().filter(|bytes| !bytes.is_empty());
            embed_flac_metadata(
                &mut source,
                &mut staged.file,
                &download_metadata_fields(request, &response),
                &request.artist_tag_mode,
                cover,
                &check,
            )?;
            if cover.is_some()
                && extract_cover(&mut staged.file, "flac", &check)?
                    .data
                    .is_empty()
            {
                return Err(
                    "metadata embedded but cover verification failed: empty embedded cover".into(),
                );
            }
        } else if !promoted {
            let mut buffer = [0_u8; 65536];
            loop {
                check()?;
                let size = source
                    .read(&mut buffer)
                    .map_err(|error| error.to_string())?;
                if size == 0 {
                    break;
                }
                staged
                    .file
                    .write_all(&buffer[..size])
                    .map_err(|error| error.to_string())?;
            }
        }
        if strict_local {
            let mut measured = json!({});
            probe_open_file(&mut staged.file, &final_path, &mut measured, false, &check)?;
            if !strict_codec_matches(request, manifest, &measured) {
                return Ok(DownloadOutcome::Final(strict_quality_failure(
                    &manifest.name,
                    "final staged audio does not match the requested quality",
                    &measured,
                )));
            }
            for (field, measured_field) in [
                ("audio_codec", "audio_codec"),
                ("actual_container", "actual_container"),
                ("actual_bit_depth", "bit_depth"),
                ("actual_sample_rate", "sample_rate"),
                ("actual_bitrate", "bitrate"),
            ] {
                response[field] = measured[measured_field].clone();
            }
        }
        // Every new regular-file download owns a new name, including temporary
        // fallback and unspecified quality. Reusing an existing valid artifact
        // is handled by the explicit already-exists branch before production.
        check()?;
        #[cfg(feature = "experimental-progressive-reader")]
        let published = if let Some(operation) = &progressive {
            match operation.current() {
                Some(candidate) => staged.publish_new_with_candidate(&lease, &candidate, &source),
                None => Err(std::io::Error::other("progressive candidate unavailable")),
            }
        } else { staged.publish_new_with_lease(&lease) };
        #[cfg(not(feature = "experimental-progressive-reader"))]
        let published = staged.publish_new_with_lease(&lease);
        if let Err(error) = published {
            #[cfg(feature = "experimental-progressive-reader")]
            if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("backend_stage=publication_failed"); }
            check()?;
            return Ok(DownloadOutcome::Final(failure(
                &manifest.name,
                if error.kind() == std::io::ErrorKind::AlreadyExists {
                    "download destination already exists; existing file was preserved"
                } else {
                    "local download publication failed"
                },
                "file_error",
                0,
            )));
        }
        #[cfg(feature = "experimental-progressive-reader")]
        { progressive_scope.completed = true; }
        response["file_path"] = final_path.clone().into();
        response = finish_committed_download(response, |response| {
            if request.output_dir.is_empty() || text(response, "isrc").trim().is_empty() {
                return Ok(());
            }
            // Shared index only; never build a planner-specific cache.
            environment
                .invalidate_isrc_cache(&request.output_dir)
                .map_err(|error| error.to_string())?;
            environment
                .add_to_isrc_index(
                    destination
                        .absolute
                        .parent()
                        .unwrap_or(Path::new("."))
                        .to_string_lossy()
                        .as_ref(),
                    text(response, "isrc").trim(),
                    &final_path,
                    &|| Ok(()),
                )
                .map_err(|error| error.to_string())
        });
        Ok(DownloadOutcome::Final(response))
    }

    fn enrich_download_extended(
        &self,
        request: &mut DownloadRequest,
        check: &Check<'_>,
    ) -> Result<(), String> {
        if request.isrc.is_empty() {
            return Ok(());
        }
        let needs_artist = request.album_artist.trim().is_empty();
        let needs_tags =
            request.genre.is_empty() || request.label.is_empty() || request.copyright.is_empty();
        let artist = || {
            self.fetch_music_brainz_album_artist_by_isrc(&request.isrc, &request.album_name, check)
        };
        let tags = || {
            self.metadata_operation(10, check, |check| {
                self.deezer
                    .get_extended_metadata_by_isrc(request.isrc.trim(), check)
            })
        };
        // These lookups are independent. Join the extra worker before returning
        // so cancellation and owner shutdown still cover both requests.
        let (artist, metadata) = if needs_artist && needs_tags && !request.isrc.trim().is_empty() {
            std::thread::scope(|scope| {
                let worker = std::thread::Builder::new()
                    .name("download-album-artist".into())
                    .spawn_scoped(scope, artist);
                let Ok(worker) = worker else {
                    let artist = artist();
                    check()?;
                    return Ok((Some(artist), Some(tags())));
                };
                let metadata = tags();
                let artist = worker
                    .join()
                    .map_err(|_| "album artist lookup panicked".to_owned())?;
                Ok::<_, String>((Some(artist), Some(metadata)))
            })?
        } else {
            let artist = needs_artist.then(artist);
            check()?;
            let metadata = (needs_tags && !request.isrc.trim().is_empty()).then(tags);
            (artist, metadata)
        };
        check()?;
        if let Some(Ok(artist)) = artist
            && !artist.trim().is_empty()
        {
            request.album_artist = artist.trim().into();
        }
        if let Some(metadata) = metadata {
            if let Ok(metadata) = metadata {
                for (target, value) in [
                    (&mut request.genre, &metadata.genre),
                    (&mut request.label, &metadata.label),
                    (&mut request.copyright, &metadata.copyright),
                ] {
                    if target.is_empty() {
                        *target = value.clone();
                    }
                }
            }
            if request.genre.is_empty() {
                let genre = self.fetch_music_brainz_genre_by_isrc(request.isrc.trim(), check);
                check()?;
                if let Ok(genre) = genre {
                    request.genre = genre;
                }
            }
        }
        check()
    }
}
