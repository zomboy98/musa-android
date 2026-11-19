package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWorkerPolicyTest {
    @Test
    fun percentOnlyNotificationTotalsDoNotRenderAsBytes() {
        assertTrue(DownloadService.isPercentOnlyNotificationTotal(10_000L))
        assertTrue(DownloadService.isPercentOnlyNotificationTotal(100L))
        assertFalse(DownloadService.isPercentOnlyNotificationTotal(72L * 1024L * 1024L))
        assertFalse(DownloadService.isPercentOnlyNotificationTotal(0L))
    }

    @Test
    fun rateLimitRetriesExactlyOnce() {
        assertTrue(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "rate_limit",
                errorMessage = "Too many requests",
                attempts = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "rate_limit",
                errorMessage = "Too many requests",
                attempts = 1,
            ),
        )
    }

    @Test
    fun rateLimitDetectionFallsBackToMessage() {
        assertTrue(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "network",
                errorMessage = "HTTP 429: retry later",
                attempts = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "network",
                errorMessage = "Connection reset",
                attempts = 0,
            ),
        )
    }

    @Test
    fun rateLimitRequiresAStatusMarkerOrAnExplicitType() {
        for (message in listOf(
            "Connection reset https://private.invalid/track/1429",
            "Connection reset https://private.invalid/track/429",
            "Connection reset https://private.invalid?status=429",
            "Connection reset https://private.invalid/track;status=429",
            """Provider returned {"status":"HTTP error: 429"}""",
            "HTTP 4290 is invalid",
            "Could not fetch track data: SoundCloud API returned HTTP 4290",
            "Connection reset https://private.invalid/track;Could%20not%20fetch%20track%20data:%20SoundCloud%20API%20returned%20HTTP%20429",
            "Retry-After seconds: 429",
        )) {
            assertFalse(NativeWorkerPolicy.shouldRetryRateLimit("network", message, attempts = 0))
        }
        for (message in listOf(
            "HTTP/2 429",
            "HTTP status: 429",
            "status code=429",
            "HTTP error: 429",
            "segment 2 HTTP error: 429 Too Many Requests",
            "HTTP 429 for https://private.invalid/track",
            "HTTP 429 from JioSaavn",
            "All providers failed. Last error: Download failed: HTTP error: 429",
        )) {
            assertTrue(NativeWorkerPolicy.shouldRetryRateLimit("network", message, attempts = 0))
        }
        for (message in listOf(
            "Could not fetch track data: SoundCloud API returned HTTP 429",
            "All providers failed. Last error: Could not fetch track data: SoundCloud API returned HTTP 429",
            "direct SoundCloud lookup failed: SoundCloud API returned HTTP 429",
            "Search failed: SoundCloud API returned HTTP 429",
            "Failed to resolve Deezer download: HTTP 429 for https://private.invalid/track",
        )) {
            assertTrue(NativeWorkerPolicy.shouldRetryRateLimit("api_error", message, attempts = 0))
        }
        assertTrue(NativeWorkerPolicy.shouldRetryRateLimit("rate_limited", null, attempts = 0))
    }

    @Test
    fun bundledDownloadRateLimitsUseTheSharedStatusCases() {
        val fixture = checkNotNull(javaClass.getResourceAsStream("/download_rate_limit_cases.tsv"))
        fixture.bufferedReader().useLines { lines ->
            for (line in lines) {
                val (name, type, message, expected) = line.split('\t')
                assertEquals(
                    name,
                    expected == "rate_limit",
                    NativeWorkerPolicy.shouldRetryRateLimit(type, message, attempts = 0),
                )
            }
        }
    }

    @Test
    fun retryDelayUsesServerHintAndSafeBounds() {
        assertEquals(
            45,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 45,
                errorMessage = null,
            ),
        )
        assertEquals(
            12,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = null,
                errorMessage = "Retry-After seconds: 12",
            ),
        )
        assertEquals(
            5,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 1,
                errorMessage = null,
            ),
        )
        assertEquals(
            300,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 900,
                errorMessage = null,
            ),
        )
    }

    @Test
    fun wifiOnlyPausesWithoutWifi() {
        assertTrue(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "wifi_only",
                hasWifi = false,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "wifi_only",
                hasWifi = true,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "any",
                hasWifi = false,
            ),
        )
    }

    @Test
    fun verificationDetectionUsesTypeAndMessageFallback() {
        for (errorType in listOf(
            "authentication_error", "provider_auth_failed",
            "request_auth_invalid", "provider_reauth_required",
        )) {
            assertFalse(
                NativeWorkerPolicy.isVerificationRequired(
                    errorType = errorType,
                    errorMessage = "Provider unauthorized; verification required upstream",
                ),
            )
        }
        assertTrue(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "verification_required",
                errorMessage = null,
            ),
        )
        assertTrue(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "unknown",
                errorMessage = "Challenge required before download",
            ),
        )
        assertFalse(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "network",
                errorMessage = "Connection reset",
            ),
        )
    }

    @Test
    fun completionAlertSkipsCancelledOrEmptyRuns() {
        assertTrue(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 1,
                failed = 0,
            ),
        )
        assertTrue(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 0,
                failed = 1,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = true,
                completed = 1,
                failed = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 0,
                failed = 0,
            ),
        )
    }

    @Test
    fun stoppedWorkerRequeuesOnlyInFlightItems() {
        listOf("preparing", "downloading", "finalizing").forEach { status ->
            assertEquals("queued", NativeWorkerPolicy.statusAfterWorkerStop(status))
        }
        assertEquals("queued", NativeWorkerPolicy.statusAfterWorkerStop("queued"))
        assertEquals("completed", NativeWorkerPolicy.statusAfterWorkerStop("completed"))
        assertEquals("failed", NativeWorkerPolicy.statusAfterWorkerStop("failed"))
        assertEquals("skipped", NativeWorkerPolicy.statusAfterWorkerStop("skipped"))
    }

    @Test
    fun acknowledgedPayloadsAreReleasedOnlyForTerminalItems() {
        listOf("completed", "failed", "skipped").forEach { status ->
            assertTrue(NativeWorkerPolicy.isTerminalStatus(status))
        }
        listOf("queued", "preparing", "downloading", "finalizing").forEach { status ->
            assertFalse(NativeWorkerPolicy.isTerminalStatus(status))
        }
    }
}
