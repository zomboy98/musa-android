package com.zarz.mornye

/** Fixed, shareable diagnostics. Raw FFmpeg output and exception messages can contain private data. */
internal object FinalizerDiagnostics {
    class StorageWriteFailure : IllegalStateException("Storage write failed")
    fun decryptionFailure(errorType: String): IllegalStateException =
        if (errorType == "permission") StorageWriteFailure() else IllegalStateException("decrypt failed")
    fun safDownloadFailure(deferred: Boolean, error: Throwable): String {
        val prefix = if (deferred) "SAF deferred download failed" else "SAF download failed"
        return if (errorType(error) == "permission") "$prefix: permission denied" else prefix
    }
    enum class Failure(val message: String) {
        REPLAYGAIN_SCAN("ReplayGain scan failed"),
        FLAC_PROBE("Native FLAC magic probe failed"),
        AUTO_CONVERSION("Automatic conversion failed; keeping source"),
        REPLAYGAIN_WRITE("ReplayGain write failed"),
        FINALIZATION("Native finalization failed"),
    }

    fun message(failure: Failure, @Suppress("UNUSED_PARAMETER") rawDiagnostic: Any?): String = failure.message

    // Match the existing queue's storage-recovery categories before discarding
    // the message. Never include the message itself in the returned result.
    fun errorType(error: Throwable): String {
        if (error is SecurityException || error is StorageWriteFailure) return "permission"
        return errorTypeFromOutput(error.message.orEmpty())
    }

    fun errorTypeFromOutput(output: String): String {
        val message = output.lowercase(java.util.Locale.ROOT)
        val storageFailures = listOf(
            "operation not permitted", "permission denied", "read-only file system",
            "failed to create file", "failed to create directory", "failed to access saf directory",
            "failed to create saf file", "failed to open saf file", "failed to publish saf",
            "failed to publish deferred saf", "failed to copy extension output to saf",
        )
        return if (storageFailures.any(message::contains)) "permission" else "unknown"
    }
}
