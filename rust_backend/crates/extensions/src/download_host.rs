use crate::download::{self, DownloadOptions};
use crate::runtime::{Control, ExtensionServices};
use rquickjs::{Ctx, Function, Object, Value};
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    register_segments(ctx, host, Arc::clone(&control), services)?;
    let Some(files) = &services.files else {
        return Ok(());
    };
    let files = Arc::clone(files);
    let downloads = Arc::clone(&services.downloads);
    let network = services.network.clone();
    let policy = services.transfer_policy.clone();
    let app_version = services.app_version.clone();
    host.set(
        "downloadCall",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  url: String,
                  path: String,
                  options: Value<'js>,
                  headers: String| {
                let result: Result<serde_json::Value, String> = (|| {
                    let check = || control.check().map_err(|error| error.to_string());
                    check()?;
                    let network = network.as_ref().ok_or("network access unavailable")?;
                    network.validate_url(&url)?;
                    let path = files.resolve(&path)?;
                    let options = options.as_object();
                    let value = |key: &str| -> Result<Value<'js>, String> {
                        options.map_or_else(
                            || Ok(Value::new_undefined(ctx.clone())),
                            |object| object.get(key).map_err(|error| error.to_string()),
                        )
                    };
                    let direct_network = if value("directMedia")?.as_bool() == Some(true) {
                        Some(network.direct_media())
                    } else {
                        None
                    };
                    let network = direct_network.as_ref().unwrap_or(network.as_ref());
                    let chunked = value("chunked")?;
                    let chunk_size = if chunked.as_bool() == Some(true) {
                        Some(1 << 20)
                    } else {
                        chunked
                            .as_number()
                            .filter(|value| *value > 0.0)
                            .map(|value| {
                                let size = value as i64;
                                if size <= 0 { 1 << 20 } else { size as u64 }
                            })
                    };
                    let mut policy = policy.clone();
                    if let Some(attempts) = value("maxAttempts")?
                        .as_number()
                        .filter(|number| *number > 0.0)
                    {
                        policy.max_attempts = (attempts as i64).clamp(1, 8);
                    }
                    let resume = value("resume")?
                        .as_bool()
                        .unwrap_or(policy.resume_policy == "validated");
                    let has_track = options
                        .map(|object| object.contains_key("trackItemBytes"))
                        .transpose()
                        .map_err(|error| error.to_string())?
                        .unwrap_or(false);
                    let track = value(if has_track {
                        "trackItemBytes"
                    } else {
                        "track_item_bytes"
                    })?
                    .as_bool()
                    .unwrap_or(true);
                    let persistent = value("persistentCheckpoint")?
                        .as_bool()
                        .map_or(policy.persistent_checkpoint, |enabled| enabled && resume);
                    let callback = value("onProgress")?;
                    let callback = callback.as_function();
                    let mut progress = |bytes, total| {
                        if let Some(callback) = callback
                            && callback.call::<_, ()>((bytes, total)).is_err()
                        {
                            // Go ignores download progress callback errors. Clear the
                            // pending JS exception; cancellation is checked by the host.
                            ctx.catch();
                        }
                    };
                    let headers =
                        serde_json::from_str(&headers).map_err(|error| error.to_string())?;
                    // The provider may hand over the key it already holds so a
                    // host-admitted generic audio lease can decrypt CENC as bytes
                    // arrive. It never enables the capability (the operation does),
                    // a malformed descriptor is ignored, and nothing is returned.
                    #[cfg(feature = "experimental-progressive-reader")]
                    let observer = {
                        let gate = control.progressive_candidate();
                        if let Some(gate) = &gate
                            && let Some(key) = cenc_key_option(&value("decryption")?)
                        {
                            gate.provide_cenc_key(key);
                        }
                        gate.map(|gate| gate as Arc<dyn download::progressive::PrefixObserver>)
                    };
                    #[cfg(not(feature = "experimental-progressive-reader"))]
                    let observer: Option<Arc<dyn download::progressive::PrefixObserver>> = None;
                    Ok(
                        match download::download(
                            &files,
                            &path,
                            network,
                            &url,
                            DownloadOptions {
                                item: download::progress::ItemProgressTarget::new(
                                    Arc::clone(&downloads.progress),
                                    control.item_id(),
                                    track,
                                ),
                                headers,
                                // Go snapshots the UA for a chunked transfer;
                                // ordinary retries read the current app version.
                                app_version: if chunk_size.is_some() {
                                    app_version.get().into()
                                } else {
                                    app_version.clone()
                                },
                                resume,
                                persistent,
                                policy,
                                budget: control.resolution(),
                                chunk_size,
                                prefix_observer: observer,
                            },
                            &check,
                            &|duration| {
                                let _charge = control.resolution().map(|budget| budget.enter(true));
                                control.sleep(duration);
                                check()
                            },
                            &mut progress,
                        ) {
                            Ok(result) => result,
                            Err(error) => serde_json::to_value(error).expect("transfer error JSON"),
                        },
                    )
                })();
                #[cfg(feature = "experimental-progressive-reader")]
                if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() {
                    match &result {
                        Ok(value) => { let success = value.get("success").and_then(|v| v.as_bool()).unwrap_or(false); let kind = value.get("error_type").and_then(|v| v.as_str()).unwrap_or("none"); let safe = if kind.len() <= 32 && kind.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') { kind } else { "other" }; eprintln!("operation=download success={success} category={safe}"); },
                        Err(_) => eprintln!("operation=download success=false category=host_exception"),
                    }
                }
                match result {
                    Ok(result) => result,
                    Err(error) => serde_json::json!({"success":false,"error":error}),
                }
                .to_string()
            },
        )?,
    )?;
    Ok(())
}

/// Reads `decryption: {strategy: 'ffmpeg.mov_key', key: <32 hex>}` from the
/// download options. Only an explicit AES-128 key is accepted.
#[cfg(feature = "experimental-progressive-reader")]
fn cenc_key_option<'js>(descriptor: &Value<'js>) -> Option<zeroize::Zeroizing<Vec<u8>>> {
    let object = descriptor.as_object()?;
    let text = |name: &str| object.get::<_, Option<String>>(name).ok().flatten().unwrap_or_default();
    if !matches!(text("strategy").trim(), "" | "ffmpeg.mov_key")
        || !matches!(text("input_format").trim(), "" | "mov" | "mp4")
    {
        return None;
    }
    let key = zeroize::Zeroizing::new(text("key"));
    let key = key.trim();
    // Same encodings the final decryption accepts for an AES-128 key: 32 hex
    // digits or 16 bytes in base64. Anything else is ignored.
    let (encoding, valid) = if key.len() == 32 {
        ("hex", key.bytes().all(|byte| byte.is_ascii_hexdigit()))
    } else {
        ("base64", key.len() == 24 && key.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'=')))
    };
    if !valid {
        return None;
    }
    crate::binary::decode_string(key, encoding).ok().filter(|bytes| bytes.len() == 16).map(zeroize::Zeroizing::new)
}

fn register_segments<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    let Some(files) = &services.files else {
        return Ok(());
    };
    let files = Arc::clone(files);
    let downloads = Arc::clone(&services.downloads);
    let network = services.network.clone();
    let policy = services.transfer_policy.clone();
    let app_version = services.app_version.clone();
    host.set(
        "downloadSegmentsCall",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, segments: String, path: String, options: Value<'js>| {
                let result = (|| {
                    let check = || control.check().map_err(|error| error.to_string());
                    check().map_err(|error| download::Failure::new("cancelled", error, 0))?;
                    let network = network.as_ref().ok_or_else(|| {
                        download::Failure::new("permission", "network access unavailable", 0)
                    })?;
                    let mut segments: Vec<download::segments::Segment> =
                        serde_json::from_str(&segments)
                            .map_err(|error| download::Failure::new("invalid_request", error, 0))?;
                    for (index, segment) in segments.iter_mut().enumerate() {
                        segment.url = segment.url.trim().to_owned();
                        if segment.url.is_empty() {
                            return Err(download::Failure::new(
                                "invalid_request",
                                format!("segment {index} URL is empty"),
                                0,
                            ));
                        }
                    }
                    for segment in &segments {
                        network
                            .validate_url(&segment.url)
                            .map_err(|error| download::Failure::new("permission", error, 0))?;
                    }
                    let path = files
                        .resolve(&path)
                        .map_err(|error| download::Failure::new("permission", error, 0))?;
                    let options = options.as_object();
                    let value = |key: &str| -> Result<Value<'js>, download::Failure> {
                        options.map_or_else(
                            || Ok(Value::new_undefined(ctx.clone())),
                            |object| {
                                object.get(key).map_err(|error| {
                                    download::Failure::new("invalid_request", error, 0)
                                })
                            },
                        )
                    };
                    let mut policy = policy.clone();
                    for (name, target) in [
                        ("maxAttempts", &mut policy.max_attempts),
                        ("maxParallel", &mut policy.max_parallel_segments),
                    ] {
                        if let Some(number) = value(name)?.as_number() {
                            let rounded = crate::transfer_policy::rounded_int(number);
                            if rounded > 0 {
                                *target = rounded.clamp(1, 8);
                            }
                        }
                    }
                    let persistent = value("persistentCheckpoint")?
                        .as_bool()
                        .unwrap_or(policy.persistent_checkpoint);
                    let callback = value("onProgress")?;
                    let callback = callback.as_function();
                    let mut progress = |bytes, completed, count| {
                        if let Some(callback) = callback
                            && callback
                                .call::<_, ()>((bytes, 0, completed, count))
                                .is_err()
                        {
                            ctx.catch();
                        }
                    };
                    download::segments::download(
                        &files,
                        &path,
                        network,
                        &segments,
                        DownloadOptions {
                            item: download::progress::ItemProgressTarget::new(
                                Arc::clone(&downloads.progress),
                                control.item_id(),
                                true,
                            ),
                            headers: Default::default(),
                            app_version: app_version.clone(),
                            resume: false,
                            persistent,
                            policy,
                            budget: control.resolution(),
                            chunk_size: None,
                            prefix_observer: None,
                        },
                        &check,
                        &mut progress,
                    )
                })();
                #[cfg(feature = "experimental-progressive-reader")]
                if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() {
                    match &result {
                        Ok(value) => { let success = value.get("success").and_then(|v| v.as_bool()).unwrap_or(false); eprintln!("operation=segments success={success}"); },
                        Err(error) => { let value = serde_json::to_value(error).unwrap_or_default(); let kind = value.get("error_type").and_then(|v| v.as_str()).unwrap_or("other"); let safe = if kind.len() <= 32 && kind.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') { kind } else { "other" }; eprintln!("operation=segments success=false category={safe}"); },
                    }
                }
                match result {
                    Ok(result) => result,
                    Err(error) => serde_json::to_value(error).expect("transfer error JSON"),
                }
                .to_string()
            },
        )?,
    )
}
