package com.zarz.mornye

/** Serializes native events; payloads are delivered only to the originating caller. */
internal class ProgressiveAttemptGate(
    private val attached: () -> Unit,
    private val completed: (String) -> Unit,
    private val fallback: () -> Unit,
    private val failure: () -> Unit = fallback,
    private val invalidated: () -> Unit = {},
) {
    private val lock = Any()
    private var terminal = false
    private var sentAttached = false
    private var committed = false
    private var pendingResult: String? = null

    fun sourceAttached() = synchronized(lock) {
        if (!terminal && !sentAttached) { sentAttached = true; attached() }
    }
    fun result(value: String) = synchronized(lock) {
        if (!terminal) {
            pendingResult = value
            if (committed) { terminal = true; completed(value) }
        }
    }
    fun sourceCommitted() = synchronized(lock) {
        if (!terminal) {
            committed = true
            pendingResult?.let { terminal = true; completed(it) }
        }
    }
    fun unavailable() = synchronized(lock) {
        if (!terminal) {
            terminal = true
            val result = pendingResult
            if (result != null) { invalidated(); completed(result) } else fallback()
        }
    }
    fun failed() = synchronized(lock) {
        if (!terminal) {
            terminal = true
            val result = pendingResult
            if (result != null) { invalidated(); completed(result) } else failure()
        }
    }
    fun cancel() = synchronized(lock) { terminal = true }
}
