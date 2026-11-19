package com.zarz.mornye

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWorkerSnapshotDiagnosticsTest {
    @Test
    fun projectsRateLimitAfterRetryDecisionAndKeepsSafeDetails() {
        val raw = "HTTP 429 https://example.invalid/?token=fixture-secret retry-after: 43"
        val result = JSONObject().put("success", false)
            .put("error", raw)
            .put("error_type", "network")
            .put("retryable", true)
            .put("failure_stage", "backend_download")
            .put("diagnostic_cause", "encrypted_validation_guard")
            .put("service", "test.provider")
            .put("source", "https://example.invalid/?token=fixture-secret")
        val snapshot = JSONObject().put("last_result", result)

        assertTrue(NativeWorkerPolicy.shouldRetryRateLimit("network", raw, attempts = 0))
        assertFalse(NativeWorkerPolicy.shouldRetryRateLimit(
            "network", raw, attempts = NativeWorkerPolicy.MAX_RATE_LIMIT_RETRIES,
        ))
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot) { setOf("test.provider") }
        val safe = snapshot.getJSONObject("last_result")
        assertEquals("rate_limit", safe.getString("error_type"))
        assertEquals(43, safe.getInt("retry_after_seconds"))
        assertTrue(safe.getBoolean("retryable"))
        assertEquals("backend_download", safe.getString("failure_stage"))
        assertEquals("encrypted_validation_guard", safe.getString("diagnostic_cause"))
        assertEquals("test.provider", safe.getString("service"))
        assertFalse(safe.has("source"))
        assertFalse(snapshot.toString().contains("fixture-secret"))
        assertEquals(raw, result.getString("error"))
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot) { setOf("test.provider") }
        assertEquals(safe.toString(), snapshot.getJSONObject("last_result").toString())
    }

    @Test
    fun distinguishesGenericDenialsFromLegacyStorageRecovery() {
        val snapshot = JSONObject().put(
            "item_delta",
            JSONObject().put("status", "failed").put("error", "Access denied for fixture account"),
        )
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
        val delta = snapshot.getJSONObject("item_delta")
        val safe = delta.getJSONObject("result")
        assertEquals("Access denied", delta.getString("error"))
        assertFalse(safe.has("error_type"))
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
        assertEquals(safe.toString(), delta.getJSONObject("result").toString())
    }

    @Test
    fun dropsMalformedResultAndUnknownDiagnosticValues() {
        val snapshot = JSONObject()
            .put("message", "raw provider output")
            .put("last_result", "raw provider payload")
            .put(
                "item_delta",
                JSONObject().put("status", "failed").put(
                    "result",
                    JSONObject().put("error_type", "unknown fixture type")
                        .put("failure_stage", "unknown fixture stage")
                        .put("diagnostic_cause", "unknown fixture cause")
                        .put("retryable", "unknown fixture value"),
                ),
            )
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
        assertFalse(snapshot.has("last_result"))
        assertFalse(snapshot.toString().contains("fixture"))
        assertEquals("Download failed", snapshot.getJSONObject("item_delta").getString("error"))
    }

    @Test
    fun keepsOnlyCatalogVerifiedServiceAndPreservesProviderFallbackOrder() {
        val raw = JSONObject().put("success", false).put("error_type", "verification_required")
            .put("service", "fixture-token-service")
            .put("verification_service", "fixture-token-verification")
            .put("provider", "installed.extension")
            .put("source", "fixture-token-source")
        val snapshot = JSONObject().put("last_result", raw)
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot) { setOf("installed.extension") }
        assertEquals("installed.extension", snapshot.getJSONObject("last_result").getString("service"))
        assertFalse(snapshot.toString().contains("fixture-token"))

        snapshot.put("last_result", raw)
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
        assertFalse(snapshot.getJSONObject("last_result").has("service"))
    }

    @Test
    fun keepsBooleanSuccessForAnyStatusAndRemovesResidualError() {
        val result = JSONObject().put("success", true)
            .put("file_path", "content://fixture/output")
            .put("history", JSONObject().put("album", "Album"))
            .put("metadata", JSONObject().put("title", "Title"))
            .put("finalization", JSONObject().put("published", true))
        for (status in listOf("failed", "queued", "completed")) {
            val item = JSONObject().put("status", status).put("result", result)
                .put("error", "fixture-token-residual")
            val snapshot = JSONObject().put("item_delta", item)
            NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
            assertEquals(status, item.getString("status"))
            assertEquals(result.toString(), item.getJSONObject("result").toString())
            assertFalse(item.has("error"))
        }

        val fake = JSONObject().put("success", "true").put("file_path", "fixture-token-path")
        val snapshot = JSONObject().put("last_result", fake)
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
        assertFalse(snapshot.getJSONObject("last_result").getBoolean("success"))
        assertFalse(snapshot.toString().contains("fixture-token"))
    }

    @Test
    fun followsDartPrecedenceForTypedAndLegacyFailures() {
        val cases = listOf(
            Triple("network", "Verification required", "network"),
            Triple("permission", "Verification required", "permission"),
            Triple("provider_auth_failed", "Signed session expired", "provider_auth_failed"),
            Triple("extension_error", "Signed session expired", "verification_required"),
            Triple("verification_required", "HTTP 429", "verification_required"),
            Triple("network", "HTTP 429", "rate_limit"),
            Triple("", "Needs verification", "verification_required"),
            Triple("", "Access denied", ""),
            Triple("", "Operation not permitted", "permission"),
        )
        for ((type, raw, expected) in cases) {
            val result = JSONObject().put("success", false).put("error_type", type)
                .put("error", "$raw fixture-token")
            val snapshot = JSONObject().put("last_result", result)
            NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
            assertEquals(expected, snapshot.getJSONObject("last_result").optString("error_type"))
            assertFalse(snapshot.toString().contains("fixture-token"))
        }
    }

    private fun attempt(provider: Any?, stage: Any?, type: Any?) = JSONObject()
        .put("provider", provider).put("stage", stage).put("error_type", type)

    private fun failedWith(attempts: Any?): JSONObject {
        val result = JSONObject().put("success", false).put("error_type", "network")
        if (attempts != null) result.put("provider_attempts", attempts)
        val snapshot = JSONObject().put("last_result", result)
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot) { setOf("installed.a", "installed.b") }
        return snapshot.getJSONObject("last_result")
    }

    @Test
    fun preservesProviderAttemptsInOrderWithClosedValues() {
        val safe = failedWith(
            org.json.JSONArray()
                .put(attempt("deezer-extension", "availability", ""))
                .put(attempt("tidal", "availability_response_unavailable", "quality_unavailable"))
                .put(attempt(" Tidal-Web ", "download", "rate_limit")),
        )
        val out = safe.getJSONArray("provider_attempts")
        assertEquals(3, out.length())
        assertEquals("deezer", out.getJSONObject(0).getString("provider"))
        assertEquals("", out.getJSONObject(0).getString("error_type"))
        assertEquals("quality_unavailable", out.getJSONObject(1).getString("error_type"))
        assertEquals("tidal", out.getJSONObject(2).getString("provider"))
        assertEquals("download", out.getJSONObject(2).getString("stage"))
        assertEquals(setOf("provider", "stage", "error_type"), out.getJSONObject(0).keys().asSequence().toSet())
    }

    @Test
    fun replacesMaliciousProviderAttemptValuesWithUnknownAndDropsExtras() {
        val evil = "https://example.invalid/?token=fixture-token"
        val entry = attempt(evil, "Track Title fixture-token", "bearer fixture-token")
            .put("url", evil).put("title", "fixture-token-title")
        val safe = failedWith(
            org.json.JSONArray().put(entry)
                .put(attempt("not.installed", "download", "network"))
                .put(attempt(42, org.json.JSONArray().put("x"),JSONObject().put("t", "fixture-token"))),
        )
        val out = safe.getJSONArray("provider_attempts")
        assertEquals(3, out.length())
        for (i in 0 until 3) assertEquals("unknown", out.getJSONObject(i).getString("provider"))
        assertEquals("unknown", out.getJSONObject(0).getString("stage"))
        assertEquals("unknown", out.getJSONObject(0).getString("error_type"))
        assertEquals("download", out.getJSONObject(1).getString("stage"))
        assertEquals("network", out.getJSONObject(1).getString("error_type"))
        assertEquals("unknown", out.getJSONObject(2).getString("stage"))
        assertFalse(safe.toString().contains("fixture-token"))
        assertFalse(safe.toString().contains("example.invalid"))
    }

    @Test
    fun boundsProviderAttemptsAndSurvivesMalformedShapes() {
        val many = org.json.JSONArray()
        for (i in 0 until 100) many.put(attempt("tidal", "availability", if (i == 64) "cancelled" else ""))
        val out = failedWith(many).getJSONArray("provider_attempts")
        assertEquals(64, out.length())
        assertFalse(out.toString().contains("cancelled"))

        val mixed = org.json.JSONArray().put("raw").put(JSONObject.NULL).put(7)
            .put(attempt("tidal", "download", JSONObject.NULL))
        val clean = failedWith(mixed).getJSONArray("provider_attempts")
        assertEquals(1, clean.length())
        assertEquals("", clean.getJSONObject(0).getString("error_type"))

        assertFalse(failedWith("fixture-token-not-array").has("provider_attempts"))
        assertFalse(failedWith(JSONObject().put("provider", "tidal")).has("provider_attempts"))
        assertEquals(0, failedWith(org.json.JSONArray()).getJSONArray("provider_attempts").length())
    }

    @Test
    fun omitsProviderAttemptsWhenEngineDoesNotSendThemAndIsIdempotent() {
        assertFalse(failedWith(null).has("provider_attempts"))

        val snapshot = JSONObject().put(
            "item_delta",
            JSONObject().put("status", "failed").put(
                "result",
                JSONObject().put("success", false).put(
                    "provider_attempts",
                    org.json.JSONArray().put(attempt("tidal", "download", "timeout"))
                        .put(attempt("evil fixture-token", "download", "timeout")),
                ),
            ),
        )
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot) { setOf("installed.a") }
        val first = snapshot.toString()
        assertFalse(first.contains("fixture-token"))
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot) { setOf("installed.a") }
        assertEquals(first, snapshot.toString())
        val out = snapshot.getJSONObject("item_delta").getJSONObject("result")
            .getJSONArray("provider_attempts")
        assertEquals("tidal", out.getJSONObject(0).getString("provider"))
        assertEquals("unknown", out.getJSONObject(1).getString("provider"))
    }

    @Test
    fun restoreMapsAttemptProvidersThroughClosedListEvenWhenRegexMatches() {
        // Alphanumeric, passes the extension-id regex and is even "installed",
        // yet is not on the fixed list: must never be persisted or restored.
        val sensitive = "sk9f3a7c21d4b8e605aa17c"
        val snapshot = JSONObject()
            .put("verified_service_version", 1)
            .put(
                "last_result",
                JSONObject().put("success", false).put("service", "tidal").put(
                    "provider_attempts",
                    org.json.JSONArray()
                        .put(attempt(sensitive, "download", "network"))
                        .put(attempt("qobuz-web", "availability", ""))
                        .put(attempt("installed.a", "download", "network")),
                ),
            )
        NativeWorkerSnapshotDiagnostics.restore(snapshot) { setOf(sensitive, "installed.a") }
        val result = snapshot.getJSONObject("last_result")
        val out = result.getJSONArray("provider_attempts")
        assertEquals(3, out.length())
        assertEquals("unknown", out.getJSONObject(0).getString("provider"))
        assertEquals("download", out.getJSONObject(0).getString("stage"))
        assertEquals("qobuz", out.getJSONObject(1).getString("provider"))
        assertEquals("unknown", out.getJSONObject(2).getString("provider"))
        assertFalse(snapshot.toString().contains(sensitive))
        // The existing "service" behavior is unchanged.
        assertEquals("tidal", result.getString("service"))
    }

    @Test
    fun prepareForWriteAlsoReducesAttemptProvidersToClosedList() {
        val sensitive = "sk9f3a7c21d4b8e605aa17c"
        val snapshot = JSONObject().put(
            "last_result",
            JSONObject().put("success", false).put(
                "provider_attempts",
                org.json.JSONArray().put(attempt(sensitive, "download", "network")),
            ),
        )
        NativeWorkerSnapshotDiagnostics.prepareForWrite(
            snapshot, previouslyPersisted = true,
        ) { setOf(sensitive) }
        assertFalse(snapshot.toString().contains(sensitive))
        assertEquals(
            "unknown",
            snapshot.getJSONObject("last_result").getJSONArray("provider_attempts")
                .getJSONObject(0).getString("provider"),
        )
    }

    @Test
    fun removesMalformedContainersAndEntriesWhileKeepingValidItems() {
        val snapshot = JSONObject().put("items", "fixture-token-items")
            .put("item_delta", "fixture-token-delta")
            .put("item_ids", org.json.JSONArray().put(JSONObject().put("token", "fixture-token-id")))
            .put(
                "item_deltas",
                org.json.JSONArray().put("fixture-token-deltas").put(
                    JSONObject().put("item_id", "valid-item").put("status", "failed")
                        .put("result", "fixture-token-result").put("progress", "fixture-token-progress")
                        .put("debug", "fixture-token-debug"),
                ),
            )
        NativeWorkerSnapshotDiagnostics.sanitize(snapshot)
        assertFalse(snapshot.toString().contains("fixture-token"))
        assertEquals(1, snapshot.getJSONArray("item_deltas").length())
        assertEquals("valid-item", snapshot.getJSONArray("item_deltas").getJSONObject(0).getString("item_id"))
    }
}
