//! The installed extension manifest contract, independent of JavaScript execution.

use crate::storage::valid_extension_id;
use mornye_network::url::UrlParts;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

trait GoNull {
    fn set_null(&mut self);
}

impl GoNull for String {
    fn set_null(&mut self) {}
}
impl GoNull for bool {
    fn set_null(&mut self) {}
}
impl GoNull for isize {
    fn set_null(&mut self) {}
}
impl<T> GoNull for Vec<T> {
    fn set_null(&mut self) {
        self.clear();
    }
}
impl<T> GoNull for Option<T> {
    fn set_null(&mut self) {
        *self = None;
    }
}
impl GoNull for Map<String, Value> {
    fn set_null(&mut self) {
        self.clear();
    }
}
impl GoNull for Value {
    fn set_null(&mut self) {
        *self = Value::Null;
    }
}

fn is_false(value: &bool) -> bool {
    !value
}
fn is_zero(value: &isize) -> bool {
    *value == 0
}

// Go treats missing and null scalar fields as their zero values. Keeping wire
// names explicit also prevents Rust naming changes from changing mobile JSON.
macro_rules! manifest_struct {
    ($name:ident { $($(#[$attr:meta])* $field:ident: $ty:ty => $wire:literal),* $(,)? }) => {
        #[derive(Clone, Debug, Default, Serialize)]
        pub struct $name {
            $(
                $(#[$attr])*
                #[serde(rename = $wire)]
                pub $field: $ty,
            )*
        }
        impl GoNull for $name { fn set_null(&mut self) {} }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                struct Visitor;
                impl<'de> serde::de::Visitor<'de> for Visitor {
                    type Value = $name;
                    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                        formatter.write_str("a manifest object")
                    }
                    fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                        Ok($name::default())
                    }
                    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                        let mut result = $name::default();
                        while let Some(key) = map.next_key::<String>()? {
                            $(
                                if key.eq_ignore_ascii_case($wire) {
                                    match map.next_value::<Option<$ty>>()? {
                                        Some(value) => result.$field = value,
                                        None => result.$field.set_null(),
                                    }
                                    continue;
                                }
                            )*
                            map.next_value::<serde::de::IgnoredAny>()?;
                        }
                        Ok(result)
                    }
                }
                deserializer.deserialize_any(Visitor)
            }
        }
    };
}

manifest_struct!(ExtensionPermissions {
    network: Option<Vec<String>> => "network",
    storage: bool => "storage",
    file: bool => "file",
    #[serde(skip_serializing_if = "is_false")]
    allow_http: bool => "allowHttp",
});

manifest_struct!(ExtensionSetting {
    key: String => "key", kind: String => "type", label: String => "label",
    #[serde(skip_serializing_if = "String::is_empty")]
    description: String => "description",
    #[serde(skip_serializing_if = "is_false")]
    required: bool => "required",
    #[serde(skip_serializing_if = "is_false")]
    secret: bool => "secret",
    #[serde(skip_serializing_if = "Value::is_null")]
    default: Value => "default",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    options: Vec<String> => "options",
    #[serde(skip_serializing_if = "String::is_empty")]
    action: String => "action",
});

manifest_struct!(QualitySpecificSetting {
    key: String => "key", kind: String => "type", label: String => "label",
    #[serde(skip_serializing_if = "String::is_empty")]
    description: String => "description",
    #[serde(skip_serializing_if = "is_false")]
    required: bool => "required",
    #[serde(skip_serializing_if = "is_false")]
    secret: bool => "secret",
    #[serde(skip_serializing_if = "Value::is_null")]
    default: Value => "default",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    options: Vec<String> => "options",
});

manifest_struct!(QualityOption {
    id: String => "id",
    #[serde(skip_serializing_if = "String::is_empty")]
    kind: String => "kind",
    label: String => "label", description: String => "description",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    settings: Vec<QualitySpecificSetting> => "settings",
});

manifest_struct!(SearchFilter {
    id: String => "id",
    #[serde(skip_serializing_if = "String::is_empty")]
    label: String => "label",
    #[serde(skip_serializing_if = "String::is_empty")]
    icon: String => "icon",
});

manifest_struct!(SearchBehavior {
    enabled: bool => "enabled",
    #[serde(skip_serializing_if = "String::is_empty")]
    placeholder: String => "placeholder",
    #[serde(skip_serializing_if = "is_false")]
    primary: bool => "primary",
    #[serde(skip_serializing_if = "String::is_empty")]
    icon: String => "icon",
    #[serde(skip_serializing_if = "String::is_empty")]
    thumbnail_ratio: String => "thumbnailRatio",
    #[serde(skip_serializing_if = "is_zero")]
    thumbnail_width: isize => "thumbnailWidth",
    #[serde(skip_serializing_if = "is_zero")]
    thumbnail_height: isize => "thumbnailHeight",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    filters: Vec<SearchFilter> => "filters",
});

manifest_struct!(UrlHandler {
    enabled: bool => "enabled",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    patterns: Vec<String> => "patterns",
});

manifest_struct!(TrackMatching {
    custom_matching: bool => "customMatching",
    #[serde(skip_serializing_if = "String::is_empty")]
    strategy: String => "strategy",
    #[serde(skip_serializing_if = "is_zero")]
    duration_tolerance: isize => "durationTolerance",
});

manifest_struct!(PostProcessingHook {
    id: String => "id", name: String => "name",
    #[serde(skip_serializing_if = "String::is_empty")]
    description: String => "description",
    #[serde(skip_serializing_if = "is_false")]
    default_enabled: bool => "defaultEnabled",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    supported_formats: Vec<String> => "supportedFormats",
});

manifest_struct!(PostProcessing {
    enabled: bool => "enabled",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    hooks: Vec<PostProcessingHook> => "hooks",
});

manifest_struct!(HealthCheck {
    id: String => "id",
    #[serde(skip_serializing_if = "String::is_empty")]
    label: String => "label",
    url: String => "url",
    #[serde(skip_serializing_if = "String::is_empty")]
    method: String => "method",
    #[serde(skip_serializing_if = "String::is_empty")]
    service_key: String => "serviceKey",
    #[serde(skip_serializing_if = "is_zero")]
    timeout_ms: isize => "timeoutMs",
    #[serde(skip_serializing_if = "is_zero")]
    cache_ttl_seconds: isize => "cacheTtlSeconds",
    #[serde(skip_serializing_if = "is_false")]
    required: bool => "required",
});

manifest_struct!(SignedSessionEndpoints {
    #[serde(skip_serializing_if = "String::is_empty")]
    bootstrap: String => "bootstrap",
    #[serde(skip_serializing_if = "String::is_empty")]
    challenge: String => "challenge",
    #[serde(skip_serializing_if = "String::is_empty")]
    exchange: String => "exchange",
    #[serde(skip_serializing_if = "String::is_empty")]
    refresh: String => "refresh",
});

manifest_struct!(SignedSession {
    namespace: String => "namespace", base_url: String => "baseUrl",
    #[serde(skip_serializing_if = "String::is_empty")]
    app_version: String => "appVersion",
    #[serde(skip_serializing_if = "String::is_empty")]
    platform: String => "platform",
    #[serde(skip_serializing_if = "String::is_empty")]
    callback_url: String => "callbackUrl",
    #[serde(skip_serializing_if = "String::is_empty")]
    scheme_label: String => "schemeLabel",
    #[serde(skip_serializing_if = "String::is_empty")]
    header_prefix: String => "headerPrefix",
    #[serde(skip_serializing_if = "is_zero")]
    time_window_seconds: isize => "timeWindowSeconds",
    endpoints: SignedSessionEndpoints => "endpoints",
});

manifest_struct!(ExtensionManifest {
    name: String => "name", display_name: String => "displayName",
    version: String => "version", description: String => "description",
    #[serde(skip_serializing_if = "String::is_empty")]
    homepage: String => "homepage",
    #[serde(skip_serializing_if = "String::is_empty")]
    icon: String => "icon",
    types: Vec<String> => "type",
    permissions: ExtensionPermissions => "permissions",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    settings: Vec<ExtensionSetting> => "settings",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    quality_options: Vec<QualityOption> => "qualityOptions",
    #[serde(skip_serializing_if = "String::is_empty")]
    min_app_version: String => "minAppVersion",
    #[serde(skip_serializing_if = "is_false")]
    skip_metadata_enrichment: bool => "skipMetadataEnrichment",
    #[serde(skip_serializing_if = "is_false")]
    skip_lyrics: bool => "skipLyrics",
    #[serde(skip_serializing_if = "is_false")]
    stop_provider_fallback: bool => "stopProviderFallback",
    #[serde(skip_serializing_if = "is_false")]
    skip_built_in_fallback: bool => "skipBuiltInFallback",
    #[serde(skip_serializing_if = "Option::is_none")]
    search_behavior: Option<SearchBehavior> => "searchBehavior",
    #[serde(skip_serializing_if = "Option::is_none")]
    url_handler: Option<UrlHandler> => "urlHandler",
    #[serde(skip_serializing_if = "Option::is_none")]
    track_matching: Option<TrackMatching> => "trackMatching",
    #[serde(skip_serializing_if = "Option::is_none")]
    post_processing: Option<PostProcessing> => "postProcessing",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    service_health: Vec<HealthCheck> => "serviceHealth",
    #[serde(skip_serializing_if = "Option::is_none")]
    signed_session: Option<SignedSession> => "signedSession",
    #[serde(skip_serializing_if = "Vec::is_empty")]
    required_runtime_features: Vec<String> => "requiredRuntimeFeatures",
    #[serde(skip_serializing_if = "Map::is_empty")]
    capabilities: Map<String, Value> => "capabilities",
});

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("failed to parse manifest JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("manifest validation error: {field} - {message}")]
    Validation { field: String, message: String },
}

fn invalid(field: impl Into<String>, message: impl Into<String>) -> ManifestError {
    ManifestError::Validation {
        field: field.into(),
        message: message.into(),
    }
}

fn extension_quality_kind(option: &QualityOption, manifest: Option<&ExtensionManifest>) -> String {
    let kind = option.kind.trim().to_ascii_lowercase();
    if matches!(kind.as_str(), "lossless" | "lossy" | "spatial") {
        return kind;
    }

    // Installed manifests from before the kind field was introduced need the
    // same ID/label inference as the Go backend. Descriptions are deliberately
    // excluded because they commonly mention fallback formats.
    let token = option.id.trim().to_ascii_lowercase();
    let text = format!("{token} {}", option.label.to_ascii_lowercase());
    if text.contains("atmos")
        || text.contains("dolby")
        || text.contains("surround")
        || matches!(token.as_str(), "ac4" | "ac-4" | "eac3" | "e-ac-3" | "ec-3")
    {
        return "spatial".to_owned();
    }
    if text.contains("lossless")
        || text.contains("flac")
        || text.contains("alac")
        || text.contains("24-bit")
        || text.contains("16-bit")
        || token == "hi_res"
    {
        return "lossless".to_owned();
    }
    if token == "high"
        || token == "low"
        || text.contains("mp3")
        || text.contains("aac")
        || text.contains("opus")
        || text.contains("vorbis")
    {
        return "lossy".to_owned();
    }
    if matches!(token.as_str(), "best" | "default" | "")
        && let Some(tier) = manifest
            .and_then(|value| value.capabilities.get("downloadFallbackTier"))
            .and_then(Value::as_str)
    {
        match tier.trim().to_ascii_lowercase().as_str() {
            "hi_res" | "lossless" => return "lossless".to_owned(),
            "low_res" => return "lossy".to_owned(),
            _ => {}
        }
    }
    String::new()
}

/// Product ordering of download quality: spatial > hi-res > lossless > lossy
/// high > lossy normal > lossy low.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum QualityClass { LossyLow, LossyNormal, LossyHigh, Lossless, HiRes, Spatial }

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RelayCandidate {
    pub level: usize,
    pub family: bool,
    pub id: String,
}

/// `None` when neither the declared kind nor the ID/label says what it is.
pub(crate) fn quality_class(option: &QualityOption, manifest: Option<&ExtensionManifest>) -> Option<QualityClass> {
    let text = format!("{} {}", option.id.trim(), option.label).to_ascii_lowercase();
    let compact = text.replace([' ', '-', '_'], "");
    match extension_quality_kind(option, manifest).as_str() {
        "spatial" => Some(QualityClass::Spatial),
        "lossless" => Some(if ["hires", "24bit", "32bit", "88.2khz", "96khz", "176.4khz", "192khz"]
            .iter().any(|word| compact.contains(word))
        { QualityClass::HiRes } else { QualityClass::Lossless }),
        "lossy" => Some(match quality_claims(option).3.last().copied() {
            Some(rate) if rate >= 256 => QualityClass::LossyHigh,
            Some(rate) if rate >= 128 => QualityClass::LossyNormal,
            Some(_) => QualityClass::LossyLow,
            None if text.contains("high") => QualityClass::LossyHigh,
            None if text.contains("low") => QualityClass::LossyLow,
            None => QualityClass::LossyNormal,
        }),
        _ => None,
    }
}

// Equivalent classes first (the "family"), then each lower class, then the
// stereo classes above the request. Spatial only ever answers a spatial request.
fn relay_class_order(wanted: QualityClass) -> Vec<QualityClass> {
    use QualityClass::*;
    match wanted {
        Spatial => vec![Spatial, HiRes, Lossless, LossyHigh, LossyNormal, LossyLow],
        HiRes => vec![HiRes, Lossless, LossyHigh, LossyNormal, LossyLow],
        Lossless => vec![Lossless, HiRes, LossyHigh, LossyNormal, LossyLow],
        LossyHigh => vec![LossyHigh, LossyNormal, LossyLow, Lossless, HiRes],
        LossyNormal => vec![LossyNormal, LossyHigh, LossyLow, Lossless, HiRes],
        LossyLow => vec![LossyLow, LossyNormal, LossyHigh, Lossless, HiRes],
    }
}

fn relay_family_len(wanted: QualityClass) -> usize {
    match wanted {
        QualityClass::Lossless | QualityClass::HiRes => 2,
        _ => 3,
    }
}

// Contradictory declarations are not evidence of equivalent audio.
fn quality_claims(option: &QualityOption) -> (Vec<&'static str>, Vec<u32>, Vec<u32>, Vec<u32>) {
    let text = format!("{} {}", option.id, option.label).to_ascii_lowercase();
    let codecs = ["opus", "aac", "mp3", "vorbis", "flac", "alac"]
        .into_iter().filter(|codec| text.contains(codec)).collect();
    let compact = text.replace([' ', '-', '_'], "");
    let depths = [16, 24, 32].into_iter()
        .filter(|depth| compact.contains(&format!("{depth}bit"))).collect();
    let mut samples: Vec<u32> = [("44.1khz", 44100), ("44100hz", 44100),
        ("48khz", 48000), ("48000hz", 48000), ("96khz", 96000),
        ("96000hz", 96000), ("192khz", 192000), ("192000hz", 192000)]
        .into_iter().filter_map(|(needle, rate)| compact.contains(needle).then_some(rate)).collect();
    samples.sort_unstable(); samples.dedup();
    let mut rates: Vec<u32> = text.split(|c: char| !c.is_ascii_digit())
        .filter_map(|part| part.parse::<u32>().ok())
        .filter(|rate| matches!(rate, 64 | 96 | 128 | 160 | 192 | 256 | 320)).collect();
    rates.sort_unstable(); rates.dedup();
    (codecs, depths, samples, rates)
}

pub(crate) fn quality_signature(option: &QualityOption) -> Option<(&'static str, u32, u32)> {
    let (codecs, depths, samples, rates) = quality_claims(option);
    if codecs.len() != 1 { return None; }
    let codec = codecs[0];
    if matches!(codec, "flac" | "alac") {
        return (depths.len() == 1 && samples.len() == 1).then(|| (codec, depths[0], samples[0]));
    }
    (rates.len() == 1).then(|| (codec, rates[0], 0))
}

pub(crate) fn quality_claims_conflict(a: &QualityOption, b: &QualityOption) -> bool {
    let spatial_a = a.kind.trim().eq_ignore_ascii_case("spatial");
    let spatial_b = b.kind.trim().eq_ignore_ascii_case("spatial");
    if spatial_a != spatial_b { return true; }
    let (ac, ad, asample, ar) = quality_claims(a);
    let (bc, bd, bsample, br) = quality_claims(b);
    let ambiguous = |c: &Vec<&str>, d: &Vec<u32>, s: &Vec<u32>, r: &Vec<u32>| {
        c.len() > 1 || d.len() > 1 || s.len() > 1 ||
            (c.first().is_some_and(|v| !matches!(*v, "flac" | "alac")) && r.len() > 1)
    };
    if ambiguous(&ac, &ad, &asample, &ar) || ambiguous(&bc, &bd, &bsample, &br) { return true; }
    let kind = |o: &QualityOption| match o.kind.trim().to_ascii_lowercase().as_str() {
        "lossless" => Some("lossless"), "lossy" => Some("lossy"), _ => {
            let text = format!("{} {}", o.id, o.label).to_ascii_lowercase();
            if text.contains("lossless") { Some("lossless") }
            else if text.contains("lossy") { Some("lossy") }
            else { None }
        },
    };
    let inferred = |c: &Vec<&str>| match c.first().copied() {
        Some("flac" | "alac") => Some("lossless"),
        Some("opus" | "aac" | "mp3" | "vorbis") => Some("lossy"), _ => None,
    };
    let ak = kind(a); let bk = kind(b); let ai = inferred(&ac); let bi = inferred(&bc);
    if ak.zip(ai).is_some_and(|(x,y)| x != y) || bk.zip(bi).is_some_and(|(x,y)| x != y)
        || ak.or(ai).zip(bk.or(bi)).is_some_and(|(x,y)| x != y) { return true; }
    let different = |x: &Vec<u32>, y: &Vec<u32>| !x.is_empty() && !y.is_empty() && x != y;
    (!ac.is_empty() && !bc.is_empty() && ac != bc) || different(&ad, &bd)
        || different(&asample, &bsample)
        || (ai == Some("lossy") && bi == Some("lossy") && different(&ar, &br))
}

impl ExtensionManifest {
    pub fn parse(json: &str) -> Result<Self, ManifestError> {
        let manifest: Self = serde_json::from_str(json)?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        if self.name.trim().is_empty() {
            return Err(invalid("name", "name is required"));
        }
        if !valid_extension_id(&self.name) {
            return Err(invalid(
                "name",
                "name must be a lowercase extension ID containing only letters, numbers, '.', '_' or '-'",
            ));
        }
        if self.version.trim().is_empty() {
            return Err(invalid("version", "version is required"));
        }
        if self.description.trim().is_empty() {
            return Err(invalid("description", "description is required"));
        }
        if self.types.is_empty() {
            return Err(invalid("type", "at least one type is required"));
        }
        for kind in &self.types {
            if !matches!(
                kind.as_str(),
                "metadata_provider" | "download_provider" | "lyrics_provider"
            ) {
                return Err(invalid(
                    "type",
                    format!(
                        "invalid extension type: {kind} (must be 'metadata_provider', 'download_provider', or 'lyrics_provider')"
                    ),
                ));
            }
        }
        for (index, setting) in self.settings.iter().enumerate() {
            let failure = if setting.key.trim().is_empty() {
                Some(("key", "setting key is required"))
            } else if setting.kind.is_empty() {
                Some(("type", "setting type is required"))
            } else if setting.kind == "select" && setting.options.is_empty() {
                Some(("options", "select type requires options"))
            } else if setting.kind == "button" && setting.action.is_empty() {
                Some(("action", "button type requires action (JS function name)"))
            } else {
                None
            };
            if let Some((field, message)) = failure {
                return Err(invalid(format!("settings[{index}].{field}"), message));
            }
        }
        for (index, quality) in self.quality_options.iter().enumerate() {
            if !matches!(quality.kind.as_str(), "" | "lossless" | "lossy" | "spatial") {
                return Err(invalid(
                    format!("qualityOptions[{index}].kind"),
                    "quality kind must be lossless, lossy, or spatial",
                ));
            }
        }
        for (index, check) in self.service_health.iter().enumerate() {
            let failure = if check.id.trim().is_empty() {
                Some(("id", "health check id is required"))
            } else if check.url.trim().is_empty() {
                Some(("url", "health check url is required"))
            } else if !matches!(
                check.method.trim().to_uppercase().as_str(),
                "" | "GET" | "HEAD"
            ) {
                Some(("method", "health check method must be GET or HEAD"))
            } else {
                None
            };
            if let Some((field, message)) = failure {
                return Err(invalid(format!("serviceHealth[{index}].{field}"), message));
            }
        }
        if let Some(session) = &self.signed_session {
            if !self.permissions.storage {
                return Err(invalid(
                    "permissions.storage",
                    "signedSession requires storage permission",
                ));
            }
            if session.namespace.trim().is_empty() {
                return Err(invalid("signedSession.namespace", "namespace is required"));
            }
            let base = session.base_url.trim();
            if base.is_empty() {
                return Err(invalid("signedSession.baseUrl", "baseUrl is required"));
            }
            if !base.to_lowercase().starts_with("https://") {
                return Err(invalid("signedSession.baseUrl", "baseUrl must use https"));
            }
            let parsed = UrlParts::parse(base)
                .filter(|url| !url.hostname.is_empty())
                .ok_or_else(|| invalid("signedSession.baseUrl", "baseUrl is invalid"))?;
            if !self.is_domain_allowed(&parsed.hostname) {
                return Err(invalid(
                    "signedSession.baseUrl",
                    "baseUrl host must be listed in permissions.network",
                ));
            }
        }
        if self.has_capability("rawFfmpeg") && !self.permissions.file {
            return Err(invalid(
                "permissions.file",
                "rawFfmpeg capability requires file permission",
            ));
        }
        crate::transfer_policy::validate(&self.capabilities)
            .map_err(|message| invalid("capabilities.downloadTransfer", message))?;
        if let Some(mode) = self.capabilities.get("accountDownloadMode") {
            let valid = mode.as_object().is_some_and(|mode| {
                mode.get("setting")
                    .and_then(Value::as_str)
                    .is_some_and(|key| !key.is_empty() && !key.starts_with('_') && key.len() <= 64)
                    && mode
                        .get("value")
                        .and_then(Value::as_str)
                        .is_some_and(|value| !value.is_empty() && value.len() <= 64)
            });
            if !valid {
                return Err(invalid(
                    "capabilities.accountDownloadMode",
                    "expected a setting and value",
                ));
            }
        }
        if let Some(timeout) = self.capabilities.get("actionTimeoutSeconds")
            && !timeout
                .as_u64()
                .is_some_and(|seconds| (1..=120).contains(&seconds))
        {
            return Err(invalid(
                "capabilities.actionTimeoutSeconds",
                "expected 1 to 120 seconds",
            ));
        }
        Ok(())
    }

    pub fn has_capability(&self, name: &str) -> bool {
        self.capabilities.get(name) == Some(&Value::Bool(true))
    }

    pub(crate) fn account_download_enabled(&self, settings: &Map<String, Value>) -> bool {
        self.capabilities
            .get("accountDownloadMode")
            .is_some_and(|mode| {
                let Some(setting) = mode["setting"].as_str() else {
                    return false;
                };
                let Some(value) = mode["value"].as_str() else {
                    return false;
                };
                settings.get(setting).and_then(Value::as_str) == Some(value)
            })
    }

    pub(crate) fn action_timeout_ms(&self, default: u64) -> u64 {
        self.capabilities
            .get("actionTimeoutSeconds")
            .and_then(Value::as_u64)
            .map_or(default, |seconds| seconds.clamp(1, 120) * 1000)
    }

    pub fn find_quality(&self, requested: &str) -> Option<&QualityOption> {
        let requested = requested.trim();
        if requested.is_empty() {
            return None;
        }
        self.quality_options
            .iter()
            .find(|option| option.id.trim().eq_ignore_ascii_case(requested))
    }

    pub(crate) fn first_alternative_quality(&self, requested: &str) -> Option<&str> {
        self.quality_options
            .iter()
            .map(|option| option.id.trim())
            .find(|id| !id.is_empty() && !id.eq_ignore_ascii_case(requested.trim()))
    }

    /// The class the user asked for. An empty request means "best available".
    pub(crate) fn requested_quality_class(
        requested: &str,
        source: Option<&ExtensionManifest>,
    ) -> QualityClass {
        let requested = requested.trim();
        if requested.is_empty() {
            return QualityClass::HiRes;
        }
        let declared = source.and_then(|manifest| manifest.find_quality(requested)).cloned();
        let option = declared.unwrap_or_else(|| QualityOption { id: requested.to_owned(), ..Default::default() });
        quality_class(&option, source).unwrap_or(QualityClass::Lossless)
    }

    /// Every quality this provider can be asked for on behalf of `requested`,
    /// ordered by the relay policy. `level` is comparable between providers:
    /// lower levels are tried on every provider before a higher one anywhere.
    /// Entries with `family == true` are equivalent to the request; the rest
    /// are a degradation (or, last, an upgrade nobody asked for).
    pub(crate) fn relay_candidates(
        &self,
        requested: &str,
        source: Option<&ExtensionManifest>,
    ) -> Vec<RelayCandidate> {
        let requested = requested.trim();
        if self.quality_options.is_empty() {
            // Legacy providers without a declared list keep their contract.
            return vec![RelayCandidate { level: 0, family: true, id: requested.to_owned() }];
        }
        let wanted = Self::requested_quality_class(requested, source);
        let order = relay_class_order(wanted);
        let family = relay_family_len(wanted);
        let same_provider = source.is_some_and(|source| source.name.eq_ignore_ascii_case(&self.name));
        let wanted_rate = source
            .and_then(|manifest| manifest.find_quality(requested))
            .cloned()
            .or_else(|| (!requested.is_empty()).then(|| QualityOption { id: requested.to_owned(), ..Default::default() }))
            .and_then(|option| quality_claims(&option).3.last().copied());
        let mut candidates: Vec<(usize, u32, bool, usize, RelayCandidate)> = Vec::new();
        for (index, option) in self.quality_options.iter().enumerate() {
            let id = option.id.trim();
            if id.is_empty() || quality_claims_conflict(option, option)
                || candidates.iter().any(|(.., prior)| prior.id.eq_ignore_ascii_case(id))
            {
                continue;
            }
            let exact = !requested.is_empty() && id.eq_ignore_ascii_case(requested);
            let class = quality_class(option, Some(self));
            let level = if exact && same_provider {
                // The user's own choice on the chosen provider always leads.
                Some(0)
            } else {
                class.and_then(|class| order.iter().position(|allowed| *allowed == class))
            };
            // Unclassifiable tiers are a last resort, never an equivalent.
            let level = level.unwrap_or(order.len());
            if level == order.len() && class == Some(QualityClass::Spatial) {
                continue; // Spatial is never a substitute for a stereo request.
            }
            let distance = match (wanted_rate, quality_claims(option).3.last().copied()) {
                (Some(wanted_rate), Some(rate))
                    if level < family && wanted <= QualityClass::LossyHigh => wanted_rate.abs_diff(rate),
                _ => 0,
            };
            candidates.push((level, distance, !exact, index, RelayCandidate {
                level, family: level < family, id: id.to_owned(),
            }));
        }
        candidates.sort_by_key(|(level, distance, inexact, index, _)| (*level, *distance, *inexact, *index));
        candidates.into_iter().map(|(.., candidate)| candidate).collect()
    }

    pub fn resolve_download_quality(
        &self,
        requested: &str,
        source: Option<&ExtensionManifest>,
    ) -> Result<String, String> {
        let requested = requested.trim();
        if self.quality_options.is_empty() {
            return Ok(requested.to_owned());
        }

        let source_quality = source.and_then(|manifest| manifest.find_quality(requested));
        let source_option = source_quality.cloned().unwrap_or_else(|| QualityOption {
            id: requested.to_owned(),
            ..QualityOption::default()
        });
        let kind = extension_quality_kind(&source_option, source);

        if let Some(exact) = self.find_quality(requested) {
            let target_kind = extension_quality_kind(exact, Some(self));
            if source.is_some_and(|manifest| manifest.name == self.name)
                || (!kind.is_empty() && kind == target_kind)
                || (kind.is_empty() && target_kind != "spatial")
            {
                return Ok(exact.id.trim().to_owned());
            }
        }

        let kind = if kind.is_empty() {
            "lossless"
        } else {
            kind.as_str()
        };
        let allowed_kinds: Vec<&str> = if matches!(kind, "spatial" | "lossy") {
            vec![kind, "lossless"]
        } else {
            vec![kind]
        };
        for allowed in allowed_kinds {
            if let Some(candidate) = self.quality_options.iter().find(|candidate| {
                let id = candidate.id.trim();
                !id.is_empty() && extension_quality_kind(candidate, Some(self)) == *allowed
            }) {
                return Ok(candidate.id.trim().to_owned());
            }
        }
        Err(format!(
            "provider {} has no compatible {} quality for {:?}",
            self.name, kind, requested
        ))
    }

    pub fn resolve_strict_download_quality(
        &self,
        requested: &str,
        source: Option<&ExtensionManifest>,
    ) -> Result<String, String> {
        let requested = requested.trim();
        if requested.is_empty() {
            return self.resolve_download_quality(requested, source);
        }
        if source.is_some_and(|source| source.name.eq_ignore_ascii_case(&self.name)) {
            if self.quality_options.is_empty() {
                return Ok(requested.to_owned());
            }
            return self
                .find_quality(requested)
                .filter(|option| !quality_claims_conflict(option, option))
                .map(|option| option.id.trim().to_owned())
                .ok_or_else(|| {
                    format!(
                        "provider {} does not offer requested quality {:?}",
                        self.name, requested
                    )
                });
        }
        let declared = source
            .and_then(|source| source.find_quality(requested))
            .cloned()
            .unwrap_or_else(|| QualityOption {
                id: requested.to_owned(),
                ..Default::default()
            });
        let signature = quality_signature(&declared);
        if let Some(candidate) = self
            .quality_options
            .iter()
            .find(|candidate| signature.is_some() && quality_signature(candidate) == signature
                && !quality_claims_conflict(&declared, candidate))
        {
            return Ok(candidate.id.trim().to_owned());
        }
        Err(format!(
            "provider {} has no proven equivalent codec and quality parameters for requested quality {:?}",
            self.name, requested
        ))
    }

    /// Legacy saved IDs use the same proof requirements as explicit quality.
    pub fn resolve_saved_quality_id(
        &self,
        requested: &str,
        source: Option<&ExtensionManifest>,
    ) -> Result<String, String> {
        self.resolve_strict_download_quality(requested, source)
    }

    pub fn has_type(&self, kind: &str) -> bool {
        self.types.iter().any(|value| value == kind)
    }
    pub fn stops_provider_fallback(&self) -> bool {
        self.stop_provider_fallback || self.skip_built_in_fallback
    }

    pub fn is_domain_allowed(&self, domain: &str) -> bool {
        let domain = domain.trim().to_lowercase();
        self.permissions
            .network
            .as_deref()
            .unwrap_or_default()
            .iter()
            .any(|allowed| {
                let allowed = allowed.trim().to_lowercase();
                allowed == "*"
                    || allowed == domain
                    || (allowed.starts_with("*.") && domain.ends_with(&allowed[1..]))
            })
    }

    pub fn matches_url(&self, url: &str) -> bool {
        let Some(handler) = &self.url_handler else {
            return false;
        };
        if !handler.enabled {
            return false;
        }
        let url = url.trim().to_lowercase();
        let parsed = UrlParts::parse(&url);
        handler.patterns.iter().any(|pattern| {
            let pattern = pattern.trim().to_lowercase();
            if pattern.is_empty() {
                return false;
            }
            if !pattern.contains('/') && pattern.ends_with(':') {
                return url.starts_with(&pattern);
            }
            let Some(parsed) = parsed.as_ref().filter(|url| !url.hostname.is_empty()) else {
                return false;
            };
            let pattern = pattern
                .split_once("://")
                .map_or(pattern.as_str(), |(_, rest)| rest);
            let (host, path) = pattern.split_once('/').unwrap_or((pattern, ""));
            !host.is_empty()
                && (parsed.hostname == host || parsed.hostname.ends_with(&format!(".{host}")))
                && (path.is_empty() || parsed.path.starts_with(format!("/{path}").as_bytes()))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn relay_provider(name: &str, options: &[(&str, &str, &str)]) -> ExtensionManifest {
        ExtensionManifest {
            name: name.into(),
            quality_options: options.iter().map(|(id, kind, label)| QualityOption {
                id: (*id).into(), kind: (*kind).into(), label: (*label).into(), ..Default::default()
            }).collect(),
            ..Default::default()
        }
    }

    // Shapes of the bundled manifests; none of their labels proves a codec
    // signature, which is why the strict rule could never cross providers.
    fn relay_catalog() -> [ExtensionManifest; 4] {
        [
            relay_provider("tidal-web", &[("DOLBY_ATMOS", "spatial", "Dolby Atmos"), ("HI_RES_LOSSLESS", "lossless", "HiRes FLAC"),
                ("LOSSLESS", "lossless", "Lossless"), ("HIGH", "lossy", "High"), ("LOW", "lossy", "Low")]),
            relay_provider("qobuz-web", &[("HI_RES_LOSSLESS", "lossless", "24-Bit Max"), ("HI_RES", "lossless", "24-Bit"), ("LOSSLESS", "lossless", "Lossless")]),
            relay_provider("deezer", &[("flac", "", "FLAC / Hi-Res")]),
            relay_provider("amazon", &[("best", "lossless", "FLAC Best Available"), ("opus", "lossy", "Opus 320kbps"),
                ("eac3", "spatial", "Dolby Digital Plus"), ("ac4", "spatial", "Dolby Atmos (AC-4)")]),
        ]
    }

    fn equivalent(target: &ExtensionManifest, requested: &str, source: &ExtensionManifest) -> Option<String> {
        target.relay_candidates(requested, Some(source)).into_iter().find(|c| c.family).map(|c| c.id)
    }

    #[test]
    fn relay_maps_a_request_to_the_equivalent_class_of_each_provider() {
        let [tidal, qobuz, deezer, amazon] = relay_catalog();
        for (requested, expected) in [
            ("LOSSLESS", [Some("LOSSLESS"), Some("LOSSLESS"), Some("flac"), Some("best")]),
            // Hi-res stays hi-res where it exists, otherwise lossless.
            ("HI_RES_LOSSLESS", [Some("HI_RES_LOSSLESS"), Some("HI_RES_LOSSLESS"), Some("flac"), Some("best")]),
            // Spatial stays spatial where it exists, otherwise lossless.
            ("DOLBY_ATMOS", [Some("DOLBY_ATMOS"), Some("HI_RES_LOSSLESS"), Some("flac"), Some("eac3")]),
            // Lossy never silently becomes a different family.
            ("HIGH", [Some("HIGH"), None, None, Some("opus")]),
            // No explicit choice means the best stereo tier available.
            ("", [Some("HI_RES_LOSSLESS"), Some("HI_RES_LOSSLESS"), Some("flac"), Some("best")]),
        ] {
            for (target, expected) in [&tidal, &qobuz, &deezer, &amazon].into_iter().zip(expected) {
                assert_eq!(equivalent(target, requested, &tidal).as_deref(), expected, "{requested} on {}", target.name);
            }
        }
        // The strict rule, kept for the opt-in mode, still refuses all of them.
        assert!(qobuz.resolve_strict_download_quality("LOSSLESS", Some(&tidal)).is_err());
    }

    #[test]
    fn relay_descends_by_class_and_never_substitutes_spatial_for_stereo() {
        let [tidal, qobuz, _, amazon] = relay_catalog();
        let ids = |target: &ExtensionManifest, requested: &str| -> Vec<(usize, bool, String)> {
            target.relay_candidates(requested, Some(&tidal)).into_iter().map(|c| (c.level, c.family, c.id)).collect()
        };
        assert_eq!(ids(&tidal, "LOSSLESS"), [(0, true, "LOSSLESS".into()), (1, true, "HI_RES_LOSSLESS".into()),
            (2, false, "HIGH".into()), (4, false, "LOW".into())]);
        assert_eq!(ids(&amazon, "LOSSLESS"), [(0, true, "best".into()), (2, false, "opus".into())]);
        // A lossy request reaches lossless only after every lossy class.
        assert_eq!(ids(&qobuz, "HIGH"), [(3, false, "LOSSLESS".into()), (4, false, "HI_RES_LOSSLESS".into()), (4, false, "HI_RES".into())]);
        assert_eq!(ids(&tidal, "DOLBY_ATMOS")[..3], [(0, true, "DOLBY_ATMOS".into()), (1, true, "HI_RES_LOSSLESS".into()), (2, true, "LOSSLESS".into())]);
        // A provider without a declared list keeps its legacy contract.
        assert_eq!(ids(&relay_provider("legacy", &[]), "LOSSLESS"), [(0, true, "LOSSLESS".into())]);
    }

    #[test]
    fn relay_picks_the_closest_lossy_bitrate_and_skips_contradictory_tiers() {
        let source = relay_provider("a", &[("opus320", "lossy", "Opus 320 kbps")]);
        let target = relay_provider("b", &[("aac128", "lossy", "AAC 128 kbps"), ("aac256", "lossy", "AAC 256 kbps"),
            ("bad", "lossless", "AAC 320 kbps")]);
        assert_eq!(equivalent(&target, "opus320", &source).as_deref(), Some("aac256"));
        assert!(target.relay_candidates("opus320", Some(&source)).iter().all(|c| c.id != "bad"));
        assert_eq!(quality_class(&source.quality_options[0], Some(&source)), Some(QualityClass::LossyHigh));
        assert!(QualityClass::Spatial > QualityClass::HiRes && QualityClass::HiRes > QualityClass::Lossless
            && QualityClass::Lossless > QualityClass::LossyHigh && QualityClass::LossyHigh > QualityClass::LossyNormal
            && QualityClass::LossyNormal > QualityClass::LossyLow);
    }

    #[test]
    fn saved_generic_id_requires_proven_equivalence_between_providers() {
        let source = ExtensionManifest { name: "source".into(), quality_options: vec![QualityOption { id: "best".into(), ..Default::default() }], ..Default::default() };
        let target = ExtensionManifest { name: "other".into(), quality_options: vec![QualityOption { id: "LOSSLESS".into(), ..Default::default() }], ..Default::default() };
        assert!(target.resolve_strict_download_quality("LOSSLESS", Some(&source)).is_err());
        assert!(target.resolve_saved_quality_id("LOSSLESS", Some(&source)).is_err());
        assert!(target.resolve_saved_quality_id("LOSSLESS", None).is_err());
        assert_eq!(target.resolve_saved_quality_id("LOSSLESS", Some(&target)).unwrap(), "LOSSLESS");
        assert!(target.resolve_saved_quality_id("HIGH", Some(&source)).is_err());
    }

    #[test]
    fn saved_same_id_rejects_opposing_kind_and_codec_claims() {
        let option = |id: &str, label: &str, kind: &str| QualityOption {
            id: id.into(), label: label.into(), kind: kind.into(), ..Default::default()
        };
        let manifest = |name: &str, quality: QualityOption| ExtensionManifest {
            name: name.into(), quality_options: vec![quality], ..Default::default()
        };
        let source = manifest("a", option("LOSSLESS", "FLAC 16-bit 44.1kHz", "lossless"));
        let target = manifest("b", option("LOSSLESS", "AAC 320 kbps", "lossy"));
        assert!(target.resolve_saved_quality_id("LOSSLESS", Some(&source)).is_err());
        let target = manifest("b", option("LOSSLESS", "FLAC 24-bit 96kHz", "lossless"));
        assert!(target.resolve_saved_quality_id("LOSSLESS", Some(&source)).is_err());
        let source = manifest("a", option("chosen", "AAC 128 kbps", "lossless"));
        let target = manifest("b", option("other", "AAC 128 kbps", "lossy"));
        assert!(target.resolve_strict_download_quality("chosen", Some(&source)).is_err());
        assert!(target.resolve_saved_quality_id("chosen", Some(&source)).is_err());
        let source = manifest("a", option("LOSSLESS", "", "lossless"));
        let target = manifest("b", option("LOSSLESS", "", "lossy"));
        assert!(target.resolve_saved_quality_id("LOSSLESS", Some(&source)).is_err());
    }

    #[test]
    fn same_provider_rejects_internal_conflicts_but_allows_missing_metadata() {
        let option = |id: &str, label: &str, kind: &str| QualityOption {
            id: id.into(), label: label.into(), kind: kind.into(), ..Default::default()
        };
        let manifest = |quality| ExtensionManifest { name: "a".into(), quality_options: vec![quality], ..Default::default() };
        let bad = manifest(option("choice", "AAC 128 kbps", "lossless"));
        assert!(bad.resolve_strict_download_quality("choice", Some(&bad)).is_err());
        let incomplete = manifest(option("choice", "", ""));
        assert!(incomplete.resolve_strict_download_quality("choice", Some(&incomplete)).is_ok());
    }

    #[test]
    fn spatial_is_not_equivalent_to_stereo_or_unknown() {
        let option = |kind: &str| QualityOption { id: "tier".into(), label: "AAC 128 kbps".into(), kind: kind.into(), ..Default::default() };
        let manifest = |name: &str, kind: &str| ExtensionManifest { name: name.into(), quality_options: vec![option(kind)], ..Default::default() };
        let source = manifest("a", "spatial");
        for kind in ["lossy", "", "lossless"] {
            let target = manifest("b", kind);
            assert!(target.resolve_strict_download_quality("tier", Some(&source)).is_err());
            assert!(target.resolve_saved_quality_id("tier", Some(&source)).is_err());
        }
        let target = manifest("b", "spatial");
        assert!(target.resolve_strict_download_quality("tier", Some(&source)).is_ok());
    }

    #[test]
    fn conflicting_codec_or_parameters_never_prove_equivalence() {
        let option = |id: &str, label: &str| QualityOption { id: id.into(), label: label.into(), ..Default::default() };
        assert_eq!(quality_signature(&option("aac_128", "AAC 320 kbps")), None);
        assert_eq!(quality_signature(&option("aac_128", "Opus 128 kbps")), None);
        assert_eq!(quality_signature(&option("flac_24bit_96khz", "FLAC 16-bit 96 kHz")), None);
    }

    #[test]
    fn explicit_lossless_equivalence_requires_same_codec_depth_and_sample_rate() {
        let option = |id: &str, label: &str| QualityOption {
            id: id.into(),
            label: label.into(),
            ..Default::default()
        };
        let source = ExtensionManifest {
            name: "a".into(),
            quality_options: vec![option("cd", "FLAC 16-bit 44.1 kHz")],
            ..Default::default()
        };
        let target = ExtensionManifest {
            name: "b".into(),
            quality_options: vec![
                option("hi", "FLAC 24-bit 96 kHz"),
                option("cd2", "FLAC 16-bit 44.1 kHz"),
            ],
            ..Default::default()
        };
        assert_eq!(
            target
                .resolve_strict_download_quality("cd", Some(&source))
                .unwrap(),
            "cd2"
        );
        assert_ne!(
            quality_signature(&option("unknown", "FLAC")),
            quality_signature(&option("cd", "FLAC 16-bit 44.1 kHz"))
        );
        assert_eq!(
            quality_signature(&option("aac_160", "AAC 160 kbps")),
            quality_signature(&option("other", "AAC 160 kbps"))
        );
    }

    #[test]
    fn strict_quality_never_maps_a_lossy_request_to_a_different_codec_or_rate() {
        let source = ExtensionManifest {
            name: "source".into(),
            quality_options: vec![QualityOption {
                id: "opus320".into(),
                label: "Opus 320 kbps".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let target = ExtensionManifest {
            name: "target".into(),
            quality_options: vec![
                QualityOption {
                    id: "aac320".into(),
                    label: "AAC 320 kbps".into(),
                    ..Default::default()
                },
                QualityOption {
                    id: "opus128".into(),
                    label: "Opus 128 kbps".into(),
                    ..Default::default()
                },
                QualityOption {
                    id: "other".into(),
                    label: "Opus 320 kbps".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert_eq!(
            target
                .resolve_strict_download_quality("opus320", Some(&source))
                .unwrap(),
            "other"
        );
        let incompatible = ExtensionManifest {
            quality_options: target.quality_options[..2].to_vec(),
            ..target
        };
        assert!(
            incompatible
                .resolve_strict_download_quality("opus320", Some(&source))
                .is_err()
        );
    }

    fn manifest(network: Value) -> Result<ExtensionManifest, ManifestError> {
        ExtensionManifest::parse(
            &serde_json::json!({
                "name":"generic-media","version":"1.0.0","description":"Generic fixture",
                "type":["download_provider"],"permissions":{"storage":true,"network":network},
                "signedSession":{"namespace":"generic","baseUrl":"https://accounts.example.test"}
            })
            .to_string(),
        )
    }

    #[test]
    fn any_domain_wildcard_covers_listed_hosts() {
        let any = manifest(serde_json::json!(["*"])).unwrap();
        assert!(any.is_domain_allowed("accounts.example.test"));
        assert!(any.is_domain_allowed("192.168.178.20"));
        let scoped = manifest(serde_json::json!(["*.example.test"])).unwrap();
        assert!(!scoped.is_domain_allowed("example.org"));
        assert!(manifest(serde_json::json!(["example.org"])).is_err());
    }
}
