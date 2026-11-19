package com.zarz.mornye

/** Serializes generation checks and scheduling against durable invalidation. */
internal class SessionGenerationGate(private val load: () -> Long?, private val save: (Long) -> Boolean) {
    private var failed = false
    @Synchronized fun current(): Long? {
        if (failed) return null
        return try { load()?.takeIf { it >= 0 } } catch (_: Exception) { null }
    }
    /** Returns the generation to cancel, only after the next value is persisted. */
    @Synchronized fun invalidate(): Long? {
        val previous = current() ?: return null
        if (previous == Long.MAX_VALUE) { failed = true; return null }
        val saved = try { save(previous + 1) } catch (_: Exception) { false }
        if (!saved) { failed = true; return null }
        return previous
    }
    @Synchronized fun runIfCurrent(expected: Long, action: () -> Unit): Boolean {
        if (expected < 0 || current() != expected) return false
        action()
        return true
    }
}
