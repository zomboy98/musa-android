package com.zarz.mornye

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** Projects failure diagnostics at the snapshot boundary, after worker retry decisions. */
internal object NativeWorkerSnapshotDiagnostics {
    // This marker belongs to the app-private snapshot envelope. Provider
    // results are nested and cannot mark their own IDs as verified.
    private const val VERIFIED_SERVICE_VERSION = "verified_service_version"
    private const val CURRENT_SERVICE_VERSION = 1
    private val extensionId = Regex("""[a-z0-9][a-z0-9._-]{0,127}""")
    private val workerMessages = setOf(
        "", "Android background time limit reached", "Cancelled", "Completed",
        "Downloading", "Failed", "Finalizing", "Finished", "Paused", "Preparing",
        "Preparing queue", "Queue prepared", "Queue updated", "Resumed",
        "Service destroyed", "Service restart ignored", "Service stopped", "Starting",
        "Verification required", "Waiting for Wi-Fi", "Wi-Fi restored",
    )
    private val rateLimitCountdown = Regex("""Rate limited, retrying in ([0-9]{1,3})s""")
    private const val MAX_PROVIDER_ATTEMPTS = 64
    private const val UNKNOWN = "unknown"
    private val attemptStages = setOf(
        "availability", "availability_operation_error", "availability_operation_timeout",
        "availability_response_unavailable", "preflight_error",
        "preflight_verification_required", "download",
    )
    // Closed alias -> canonical map, mirroring BugLog.temporaryProvider (Dart).
    // Keep both in sync; anything else is reported as "unknown".
    private val attemptProviders: Map<String, String> = buildMap {
        mapOf(
            "amazon" to listOf("amazon", "amazon-extension"),
            "deezer" to listOf("deezer", "deezer-extension"),
            "tidal" to listOf("tidal", "tidal-web", "tidal-extension"),
            "qobuz" to listOf("qobuz", "qobuz-web"),
            "spotify" to listOf("spotify", "spotify-web"),
            "youtube" to listOf("youtube", "ytmusic-spotiflac"),
        ).forEach { (canonical, aliases) -> aliases.forEach { put(it, canonical) } }
        listOf(
            "apple-music", "beatport", "bugs-music", "genie-music",
            "jiosaavn", "melon-music", "soundcloud",
        ).forEach { put(it, it) }
    }
    private val serviceKeys =listOf("service", "verification_service", "provider", "source")
    private val itemStatuses = setOf("queued", "preparing", "downloading", "finalizing", "completed", "failed", "skipped")
    private val itemFields = setOf(
        "item_id", "status", "progress", "bytes_received", "bytes_total", "error", "result",
    )
    private val legacyProviderTypes = setOf(
        "provider_error", "extension_error", "runtime_error", "script_error",
        "download_error", "init_error", "api_error",
    )
    private val verificationMarkers = listOf(
        "verify_required", "verification_required", "verification required", "needsverification",
        "needs verification", "session is not authenticated", "signed session expired",
    )

    fun headerMessage(message: String): String = when {
        message in workerMessages || countdownSeconds(message) != null -> message
        message == "Invalid native queue payload" || message.startsWith("Invalid native queue payload:") ->
            "Invalid native queue payload"
        message == "Download failed" || message.startsWith("Native download failed during ") ->
            "Download failed"
        else -> ""
    }

    fun sanitize(snapshot: JSONObject, installedServiceIds: () -> Set<String> = { emptySet() }) {
        project(snapshot, allowPersistedService = false, installedServiceIds)
    }

    fun prepareForWrite(
        snapshot: JSONObject,
        previouslyPersisted: Boolean,
        installedServiceIds: () -> Set<String>,
    ) {
        project(snapshot, allowPersistedService = previouslyPersisted, installedServiceIds)
        snapshot.put(VERIFIED_SERVICE_VERSION, CURRENT_SERVICE_VERSION)
    }

    fun restore(snapshot: JSONObject, installedServiceIds: () -> Set<String>) {
        project(snapshot, allowPersistedService = true, installedServiceIds)
    }

    private fun project(
        snapshot: JSONObject,
        allowPersistedService: Boolean,
        installedServiceIds: () -> Set<String>,
    ) {
        val wasVerified = snapshot.remove(VERIFIED_SERVICE_VERSION) == CURRENT_SERVICE_VERSION
        val trustedIds by lazy(installedServiceIds)
        fun serviceId(result: JSONObject): String? {
            if (allowPersistedService && wasVerified) {
                return (result.opt("service") as? String)?.takeIf(extensionId::matches)
            }
            return verifiedServiceId(result) { trustedIds }
        }
        fun providerAllowed(id: String): Boolean =
            if (allowPersistedService && wasVerified) extensionId.matches(id) else id in trustedIds
        if (snapshot.has("message")) snapshot.put("message", headerMessage(snapshot.optString("message")))
        if (snapshot.has("last_result")) {
            val result = snapshot.optJSONObject("last_result")
            if (result == null) snapshot.remove("last_result")
            else snapshot.put(
                "last_result",
                safeResult(result, serviceId = ::serviceId, providerAllowed = ::providerAllowed),
            )
        }
        val delta = snapshot.optJSONObject("item_delta")
        if (delta == null) snapshot.remove("item_delta")
        else sanitizeItem(delta, ::serviceId, ::providerAllowed)
        val itemIds = snapshot.optJSONArray("item_ids")
        if (itemIds == null) {
            snapshot.remove("item_ids")
        } else {
            val ids = JSONArray()
            for (index in 0 until itemIds.length()) {
                (itemIds.opt(index) as? String)?.let(ids::put)
            }
            snapshot.put("item_ids", ids)
        }
        for (key in listOf("items", "item_deltas")) {
            val items = snapshot.optJSONArray(key)
            if (items == null) {
                snapshot.remove(key)
                continue
            }
            val cleanItems = JSONArray()
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                sanitizeItem(item, ::serviceId, ::providerAllowed)
                cleanItems.put(item)
            }
            snapshot.put(key, cleanItems)
        }
    }

    fun verifiedServiceId(result: JSONObject, installedServiceIds: () -> Set<String>): String? {
        val candidates = serviceKeys.mapNotNull { (result.opt(it) as? String)?.trim() }
        if (candidates.isEmpty()) return null
        val trustedIds = installedServiceIds()
        return candidates.firstOrNull(trustedIds::contains)
    }

    private fun isSuccessful(result: JSONObject) = result.opt("success") == true

    private fun sanitizeItem(
        item: JSONObject,
        serviceId: (JSONObject) -> String?,
        providerAllowed: (String) -> Boolean,
    ) {
        val keys = item.keys()
        while (keys.hasNext()) {
            if (keys.next() !in itemFields) keys.remove()
        }
        if (item.opt("item_id") !is String) item.remove("item_id")
        for (field in listOf("progress", "bytes_received", "bytes_total")) {
            if (item.opt(field) !is Number) item.remove(field)
        }
        val result = item.optJSONObject("result")
        if (result == null) item.remove("result")
        val rawError = (item.opt("error") as? String).orEmpty()
        val status = item.optString("status")
        if (status !in itemStatuses) item.remove("status")
        if (result != null && isSuccessful(result)) {
            item.remove("error")
        } else if (result != null) {
            val safe = safeResult(result, rawError, serviceId, providerAllowed)
            item.put("result", safe).put("error", safe.getString("error"))
        } else if (status == "failed" && rawError.isNotBlank()) {
            val safe = safeResult(JSONObject(), rawError, serviceId, providerAllowed)
            item.put("result", safe).put("error", safe.getString("error"))
        } else if (item.has("error")) {
            when {
                status == "queued" && countdownSeconds(rawError) != null -> Unit
                status == "skipped" && rawError.isNotBlank() -> item.put("error", "Cancelled")
                else -> item.remove("error")
            }
        }
    }

    private fun safeResult(
        result: JSONObject,
        itemError: String = "",
        serviceId: (JSONObject) -> String?,
        providerAllowed: (String) -> Boolean = { false },
    ): JSONObject {
        if (isSuccessful(result)) return result

        val message = itemError.ifBlank { (result.opt("error") as? String).orEmpty() }
        val lowerMessage = message.lowercase(Locale.ROOT)
        val reportedType = DownloadFailureDiagnostics.safeErrorType(result.opt("error_type"))
        val storage = reportedType == "permission" ||
            FinalizerDiagnostics.errorTypeFromOutput(message) == "permission"
        val errorType = when {
            reportedType == "cancelled" || reportedType == "verification_required" -> reportedType
            reportedType != null && reportedType !in legacyProviderTypes ->
                if (NativeWorkerPolicy.isRateLimit(reportedType, message)) "rate_limit" else reportedType
            verificationMarkers.any(lowerMessage::contains) -> "verification_required"
            NativeWorkerPolicy.isRateLimit(reportedType, message) -> "rate_limit"
            listOf("not found", "not available", "no results").any(lowerMessage::contains) -> "not_found"
            listOf("permission", "operation not permitted", "access denied").any(lowerMessage::contains) -> "permission"
            listOf("network", "connection", "timeout", "dial").any(lowerMessage::contains) -> "network"
            else -> reportedType
        }
        val safeMessage = when {
            errorType == "verification_required" && storage -> "Verification required. Storage permission denied"
            storage && errorType == "permission" -> "Storage permission denied"
            storage -> "Failed to create file"
            errorType == "verification_required" -> "Verification required"
            errorType == "cancelled" -> "Cancelled"
            errorType == "rate_limit" -> "Rate limited"
            errorType == "permission" -> "Access denied"
            else -> "Download failed"
        }
        val safe = JSONObject().put("success", false).put("error", safeMessage)
        // A generic access denial classifies as permission in Dart, but only a
        // storage-specific denial should trigger fallback to a different folder.
        if (errorType != null && (errorType != "permission" || storage)) {
            safe.put("error_type", errorType)
        }
        val stage = DownloadFailureDiagnostics.Stage.entries.firstOrNull {
            it.wireValue == result.opt("failure_stage")
        }
        stage?.let { safe.put("failure_stage", it.wireValue) }
        DownloadFailureDiagnostics.safeCause(result.opt("diagnostic_cause"))
            ?.let { safe.put("diagnostic_cause", it) }
        (result.opt("retryable") as? Boolean)?.let { safe.put("retryable", it) }
        val retryAfter = result.optInt("retry_after_seconds").takeIf { it > 0 }
        if (errorType == "rate_limit") {
            safe.put("retry_after_seconds", NativeWorkerPolicy.rateLimitDelaySeconds(retryAfter, message))
        } else if (retryAfter != null) {
            safe.put("retry_after_seconds", retryAfter.coerceAtMost(300))
        }
        serviceId(result)?.let { safe.put("service", it) }
        providerAttempts(result.opt("provider_attempts"))?.let {
            safe.put("provider_attempts", it)
        }
        return safe
    }

    /**
     * Closed projection of the engine trace: only provider (verified ids or
     * "unknown"), stage and error_type from explicit lists. Order is kept and
     * at most [MAX_PROVIDER_ATTEMPTS] entries are read. Returns null when the
     * field is absent or not an array so older engines stay compatible.
     */
    private fun attemptProvider(raw: Any?): String =
        (raw as? String)?.trim()?.lowercase(Locale.ROOT)?.let { attemptProviders[it] } ?: UNKNOWN

    private fun providerAttempts(raw: Any?): JSONArray? {
        val attempts = raw as? JSONArray ?: return null
        val clean = JSONArray()
        for (index in 0 until minOf(attempts.length(), MAX_PROVIDER_ATTEMPTS)) {
            val entry = attempts.optJSONObject(index) ?: continue
            val provider = attemptProvider(entry.opt("provider"))
            val stage = (entry.opt("stage") as? String)?.takeIf(attemptStages::contains) ?: UNKNOWN
            val rawType = entry.opt("error_type")
            val errorType = if (rawType == null || rawType == JSONObject.NULL || rawType == "") {
                ""
            } else {
                DownloadFailureDiagnostics.safeErrorType(rawType) ?: UNKNOWN
            }
            clean.put(
                JSONObject().put("provider", provider).put("stage", stage).put("error_type", errorType),
            )
        }
        return clean
    }

    private fun countdownSeconds(message: String): Int? =
        rateLimitCountdown.matchEntire(message)?.groupValues?.get(1)?.toInt()?.takeIf { it in 5..300 }
}
