package com.zarz.mornye

/**
 * Pure (no Android) single-slot state for extension verification: only one
 * verification may be pending at a time. Dart chains the providers one after
 * another; a request that arrives while the slot is taken is answered BUSY
 * without starting anything.
 */
internal class VerificationSlot {
    enum class Begin { STARTED, BUSY, INVALID }

    var activeId: String? = null
        private set

    /** Same order as the original channel handler: BUSY is checked first. */
    fun begin(id: String, destinationValid: Boolean): Begin {
        if (activeId != null) return Begin.BUSY
        if (id.isBlank() || !destinationValid) return Begin.INVALID
        activeId = id
        return Begin.STARTED
    }

    fun isActive(id: String?): Boolean = id != null && id == activeId

    /** Frees the slot; true only for the request that currently holds it. */
    fun finish(id: String?): Boolean {
        if (!isActive(id)) return false
        activeId = null
        return true
    }
}

/** Pure decision: can the main Activity host the invisible verification now? */
internal object VerificationHostPolicy {
    fun canHost(
        hasOwner: Boolean,
        finishingOrDestroyed: Boolean,
        startedOrResumed: Boolean,
    ): Boolean = hasOwner && !finishingOrDestroyed && startedOrResumed
}
