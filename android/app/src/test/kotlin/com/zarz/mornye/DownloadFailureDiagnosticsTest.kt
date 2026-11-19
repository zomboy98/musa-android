package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

class DownloadFailureDiagnosticsTest {
    @Test
    fun logsOnlyFixedStageErrorTypeAndCause() {
        val stage = DownloadFailureDiagnostics.Stage.BACKEND_DOWNLOAD
        assertEquals(
            "Terminal download failure: stage=backend_download error_type=quality_unavailable cause=encrypted_validation_guard",
            DownloadFailureDiagnostics.terminalMessage(
                stage,
                "quality_unavailable",
                "encrypted_validation_guard",
                "canary https://private.invalid/song",
            ),
        )
        assertEquals(
            "Terminal download failure: stage=backend_download error_type=unknown cause=unknown",
            DownloadFailureDiagnostics.terminalMessage(
                stage,
                "canary /private/song",
                "{decryption_key: canary}",
                "canary native exception",
            ),
        )
    }

    @Test
    fun preservesClosedProviderFailureCodes() {
        val stage = DownloadFailureDiagnostics.Stage.BACKEND_DOWNLOAD
        for (type in listOf(
            "subscription_required",
            "expired_stream",
            "http_error",
            "integrity_failed",
            "transient_network",
            "timeout",
            "auth",
            "authentication_error",
            "provider_auth_failed",
            "request_auth_invalid",
            "provider_reauth_required",
            "provider_unavailable",
            "storage_error",
            "file_error",
            "isp_blocked",
            "not_implemented",
            "invalid_url",
            "provider_error",
            "extension_error",
            "runtime_error",
            "script_error",
            "download_error",
            "init_error",
            "api_error",
        )) {
            assertEquals(
                "Terminal download failure: stage=backend_download error_type=$type cause=unknown",
                DownloadFailureDiagnostics.terminalMessage(
                    stage, " ${type.uppercase()} ", "token=secret", "https://private.invalid/?token=secret",
                ),
            )
        }
    }

    @Test
    fun recordsRateLimitAfterTheWorkerHasExhaustedRetries() {
        val stage = DownloadFailureDiagnostics.Stage.BACKEND_DOWNLOAD
        for (reportedType in listOf("rate_limit", "network")) {
            val message = "HTTP 429 https://diagnostic-canary.invalid"
            assertTrue(NativeWorkerPolicy.shouldRetryRateLimit(reportedType, message, attempts = 0))
            assertFalse(NativeWorkerPolicy.shouldRetryRateLimit(
                reportedType, message, attempts = NativeWorkerPolicy.MAX_RATE_LIMIT_RETRIES,
            ))
            assertEquals(
                "Terminal download failure: stage=backend_download error_type=rate_limit cause=unknown",
                DownloadFailureDiagnostics.terminalMessage(stage, reportedType, null, message),
            )
        }
        assertEquals(
            "Terminal download failure: stage=backend_download error_type=auth cause=unknown",
            DownloadFailureDiagnostics.terminalMessage(stage, "auth", null, "verification required upstream"),
        )
        assertEquals(
            "Terminal download failure: stage=backend_download error_type=rate_limit cause=unknown",
            DownloadFailureDiagnostics.terminalMessage(stage, "rate_limited", null, "Provider throttled"),
        )
        assertFalse(NativeWorkerPolicy.shouldRetryRateLimit("network", "connection lost", attempts = 0))
        assertEquals(
            "Terminal download failure: stage=backend_download error_type=network cause=unknown",
            DownloadFailureDiagnostics.terminalMessage(stage, "network", null, "connection lost"),
        )
    }

    @Test
    fun leavesControlFlowAndRecoverableStorageToTheQueue() {
        val stage = DownloadFailureDiagnostics.Stage.PREPARING_OUTPUT
        for ((type, message) in listOf(
            "verification_required" to "",
            "cancelled" to "",
            "permission" to "",
            "unknown" to "failed to create SAF file",
        )) {
            assertNull(DownloadFailureDiagnostics.terminalMessage(stage, type, null, message))
        }
    }
}
