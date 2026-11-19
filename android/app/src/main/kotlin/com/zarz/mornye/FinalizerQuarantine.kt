package com.zarz.mornye

/**
 * Tracks producers for one attempt. This does not own paths or stop producers.
 * A token may be completed only by a genuine producer termination callback, or
 * when launch is known to have failed before the producer started.
 *
 * The owner must retain this object and its private staging directory after a
 * timeout. Cleanup is claimed only after every producer has stopped. A failed
 * cleanup must be recorded durably by the owner and can then be retried.
 */
internal class FinalizerQuarantine {
    internal class Producer internal constructor()
    internal class CleanupClaim internal constructor()

    private val active = mutableSetOf<Producer>()
    private var cleanupRequested = false
    private var cleanupClaim: CleanupClaim? = null
    private var cleanupFinished = false

    @Synchronized
    fun register(): Producer {
        check(!cleanupRequested) { "cleanup already requested" }
        return Producer().also { active.add(it) }
    }

    /** Returns false for duplicate or foreign callbacks. */
    @Synchronized
    fun producerStopped(producer: Producer): Boolean = active.remove(producer)

    @Synchronized
    fun requestCleanup() {
        cleanupRequested = true
    }

    /** Exactly one caller may clean while a claim is held. */
    @Synchronized
    fun tryClaimCleanup(): CleanupClaim? {
        if (!cleanupRequested || active.isNotEmpty() || cleanupClaim != null || cleanupFinished) return null
        return CleanupClaim().also { cleanupClaim = it }
    }

    /** Only the current claim holder may report its result. */
    @Synchronized
    fun cleanupResult(claim: CleanupClaim, success: Boolean) {
        check(cleanupClaim === claim) { "invalid cleanup claim" }
        cleanupClaim = null
        cleanupFinished = success
    }
}
