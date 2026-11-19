package com.zarz.mornye

/**
 * Pure (no Android) hard deadline for the invisible extension verification.
 * The screen is never shown; if verification has not completed after
 * [timeoutMs] it is closed and answered as unavailable (silent fallback).
 */
internal class VerificationDeadline(
    private val clock: () -> Long,
    val timeoutMs: Long = HARD_TIMEOUT_MS,
) {
    private var startedAt: Long = clock()
    var completed: Boolean = false
        private set

    fun start() {
        startedAt = clock()
    }

    /** Milliseconds left before the hard timeout (0 if due or completed). */
    fun remainingMs(): Long {
        if (completed) return 0L
        return (timeoutMs - (clock() - startedAt)).coerceAtLeast(0L)
    }

    /** True when the deadline passed without completion. */
    fun expired(): Boolean = !completed && clock() - startedAt >= timeoutMs

    /** The verification ended (granted/failed/closed); it can no longer expire. */
    fun markCompleted() {
        completed = true
    }

    companion object {
        /** Hard limit; never wait for the user. Easy to adjust. */
        const val HARD_TIMEOUT_MS = 25_000L
    }
}
