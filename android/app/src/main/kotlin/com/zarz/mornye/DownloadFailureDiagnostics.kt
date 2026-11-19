package com.zarz.mornye

import java.util.Locale

internal object DownloadFailureDiagnostics {
    enum class Stage(val wireValue: String, val displayLabel: String) {
        PREPARING_OUTPUT("preparing_output", "preparing output directory"),
        BACKEND_DOWNLOAD("backend_download", "downloading"),
        ANDROID_FINALIZING("android_finalizing", "finalizing"),
    }

    private val errorTypes = setOf(
        "verification_required", "authentication_error", "provider_auth_failed",
        "request_auth_invalid", "provider_reauth_required", "provider_unavailable",
        "quality_unavailable", "not_found", "network", "rate_limit", "permission",
        "file_error", "extension_error", "cancelled", "isp_blocked",
        "subscription_required", "expired_stream", "http_error", "integrity_failed",
        "transient_network", "timeout", "auth", "storage_error", "not_implemented",
        "invalid_url", "provider_error", "runtime_error", "script_error", "download_error",
        "init_error", "api_error", "rate_limited",
    )

    private val causes = setOf(
        "encrypted_validation_guard", "strict_quality_mismatch", "strict_quality_unverified",
        "quality_selection_unavailable", "encrypted_finalization_unavailable",
    )

    fun safeErrorType(value: Any?): String? = (value as? String)
        ?.trim()?.lowercase(Locale.ROOT)?.takeIf(errorTypes::contains)

    fun safeCause(value: Any?): String? = (value as? String)?.takeIf(causes::contains)

    fun terminalMessage(
        stage: Stage,
        rawErrorType: Any?,
        rawCause: Any?,
        errorMessage: String,
    ): String? {
        val rawType = rawErrorType as? String
        val reportedType = safeErrorType(rawType) ?: "unknown"
        if (reportedType == "cancelled" ||
            NativeWorkerPolicy.isVerificationRequired(reportedType, errorMessage)
        ) {
            return null
        }
        // Dart decides whether a storage failure is terminal after attempting
        // recovery. The worker cannot record it as terminal ahead of that.
        if (reportedType == "permission" ||
            FinalizerDiagnostics.errorTypeFromOutput(errorMessage) == "permission"
        ) {
            return null
        }
        // Only called after the worker has made its retry decision.
        val errorType = if (NativeWorkerPolicy.isRateLimit(rawType, errorMessage)) {
            "rate_limit"
        } else {
            reportedType
        }
        val cause = if (stage == Stage.BACKEND_DOWNLOAD) safeCause(rawCause) ?: "unknown" else "unknown"
        return "Terminal download failure: stage=${stage.wireValue} error_type=$errorType cause=$cause"
    }
}
