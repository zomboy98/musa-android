package com.zarz.mornye

internal object NativeWorkerPolicy {
    const val MAX_RATE_LIMIT_RETRIES = 1
    private const val DEFAULT_RATE_LIMIT_DELAY_SECONDS = 30
    private const val MIN_RATE_LIMIT_DELAY_SECONDS = 5
    private const val MAX_RATE_LIMIT_DELAY_SECONDS = 300

    private val retryAfterPattern = Regex(
        """retry[- ]?after(?: seconds)?[:= ]+(\d+)""",
        RegexOption.IGNORE_CASE,
    )

    // Recognize status at a known prefix without searching URLs or payloads.
    // Keep this grammar in sync with the Dart queue.
    private val rateLimitStatusPattern = Regex(
        """^[ \t]*(?:(?:all providers failed\. last error:|download failed:)[ \t]+)*""" +
            """(?:(?:(?:could not fetch track data|direct soundcloud lookup failed|search failed):[ \t]+)?""" +
            """soundcloud api returned http[ \t]+""" +
            """|failed to resolve deezer download:[ \t]+http[ \t]+""" +
            """|(?:soundcloud (?:hls|stream) request failed|could not fetch track data: soundcloud api failed after retry):[ \t]+http[ \t]+""" +
            """|failed to download (?:file(?: via (?:cobalt|yt1d))?|(?:deezer|qobuz) stream):[ \t]+http[ \t]+error:[ \t]+""" +
            """|(?:segment [0-9]+[ \t]+)?""" +
            """(?:http(?:/[0-9]+(?:\.[0-9]+)?)?(?:[ \t]+(?:error|status(?:[ \t]+code)?))?|status(?:[ \t]+code)?)""" +
            """(?:[ \t]*[:=][ \t]*|[ \t]+))429(?=$|[ \t\r\n:;,!)\]]|\.(?:$|[ \t\r\n]))""",
        RegexOption.IGNORE_CASE,
    )

    fun shouldRetryRateLimit(
        errorType: String?,
        errorMessage: String?,
        attempts: Int,
    ): Boolean = attempts < MAX_RATE_LIMIT_RETRIES && isRateLimit(errorType, errorMessage)

    fun isRateLimit(errorType: String?, errorMessage: String?): Boolean {
        val type = errorType?.trim()
        if (type.equals("rate_limit", ignoreCase = true) ||
            type.equals("rate_limited", ignoreCase = true)
        ) return true
        return rateLimitStatusPattern.containsMatchIn(errorMessage.orEmpty())
    }

    fun rateLimitDelaySeconds(
        retryAfterSeconds: Int?,
        errorMessage: String?,
    ): Int {
        val parsedFromMessage = retryAfterPattern
            .find(errorMessage.orEmpty())
            ?.groupValues
            ?.getOrNull(1)
            ?.toIntOrNull()
        return (retryAfterSeconds?.takeIf { it > 0 }
            ?: parsedFromMessage
            ?: DEFAULT_RATE_LIMIT_DELAY_SECONDS)
            .coerceIn(
                MIN_RATE_LIMIT_DELAY_SECONDS,
                MAX_RATE_LIMIT_DELAY_SECONDS,
            )
    }

    fun isVerificationRequired(
        errorType: String?,
        errorMessage: String?,
    ): Boolean {
        if (errorType.equals("verification_required", ignoreCase = true)) {
            return true
        }
        when (errorType?.trim()?.lowercase()) {
            "auth", "authentication_error", "provider_auth_failed",
            "request_auth_invalid", "provider_reauth_required" -> return false
        }
        val message = errorMessage.orEmpty()
        return message.contains("verification required", ignoreCase = true) ||
            message.contains("challenge required", ignoreCase = true)
    }

    fun requiresWifi(downloadNetworkMode: String?): Boolean =
        downloadNetworkMode.equals("wifi_only", ignoreCase = true)

    fun shouldPauseForNetwork(
        downloadNetworkMode: String?,
        hasWifi: Boolean,
    ): Boolean = requiresWifi(downloadNetworkMode) && !hasWifi

    fun shouldNotifyQueueComplete(
        cancelRequested: Boolean,
        completed: Int,
        failed: Int,
    ): Boolean = !cancelRequested && completed + failed > 0

    fun isTerminalStatus(status: String): Boolean =
        status == "completed" || status == "failed" || status == "skipped"

    fun statusAfterWorkerStop(status: String): String = when (status) {
        "preparing", "downloading", "finalizing" -> "queued"
        else -> status
    }
}
