package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class FinalizerDiagnosticsTest {
    @Test
    fun storageFailureRetainsRecoveryTypeWithoutPrivateDetails() {
        val error = IllegalStateException("failed to publish deferred SAF output /private/secret.flac?token=private")
        assertEquals("permission", FinalizerDiagnostics.errorType(error))
        assertEquals("Native finalization failed", FinalizerDiagnostics.message(FinalizerDiagnostics.Failure.FINALIZATION, error))
        assertEquals("permission", FinalizerDiagnostics.errorType(SecurityException("private")))
        assertEquals("unknown", FinalizerDiagnostics.errorType(IllegalStateException("private")))
        val ffmpegOutput = "permission denied /private/secret.flac https://example.invalid/?token=private"
        assertEquals("permission", FinalizerDiagnostics.errorTypeFromOutput(ffmpegOutput))
        val safeFailure = FinalizerDiagnostics.decryptionFailure(FinalizerDiagnostics.errorTypeFromOutput(ffmpegOutput))
        assertEquals("permission", FinalizerDiagnostics.errorType(safeFailure))
        assertEquals("Storage write failed", safeFailure.message)
        assertEquals("unknown", FinalizerDiagnostics.errorTypeFromOutput("invalid decoder /private/secret.flac"))
        assertEquals("unknown", FinalizerDiagnostics.errorType(FinalizerDiagnostics.decryptionFailure("unknown")))
        assertEquals("SAF deferred download failed: permission denied", FinalizerDiagnostics.safDownloadFailure(true, error))
        assertEquals("SAF download failed", FinalizerDiagnostics.safDownloadFailure(false, IllegalStateException("/private/secret")))
    }

    @Test
    fun privateFfmpegOutputAndExceptionsNeverReachDiagnostics() {
        val secret = "PRIVATE_TOKEN_123"
        val sensitive = "decoder failed /home/alice/Private Song.flac https://example.invalid/?token=$secret"
        val cases = listOf(
            FinalizerDiagnostics.Failure.REPLAYGAIN_SCAN to "ReplayGain scan failed",
            FinalizerDiagnostics.Failure.FLAC_PROBE to "Native FLAC magic probe failed",
            FinalizerDiagnostics.Failure.AUTO_CONVERSION to "Automatic conversion failed; keeping source",
            FinalizerDiagnostics.Failure.REPLAYGAIN_WRITE to "ReplayGain write failed",
            FinalizerDiagnostics.Failure.FINALIZATION to "Native finalization failed",
        )
        for ((failure, expected) in cases) {
            for (raw in listOf(sensitive, IllegalStateException(sensitive), null)) {
                val message = FinalizerDiagnostics.message(failure, raw)
                assertEquals(expected, message)
                assertFalse(message.contains(secret))
                assertFalse(message.contains("alice"))
                assertFalse(message.contains("example.invalid"))
            }
        }
    }
}
