package com.zarz.mornye

import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/** Serializes owner replacement and shutdown against operations using it. */
internal class OwnerLifecycle {
    private val lock = ReentrantReadWriteLock(true)
    fun <T> operation(block: () -> T): T = lock.read(block)
    fun <T> exclusive(block: () -> T): T = lock.write(block)
}

internal fun closeOwnerResources(actions: List<() -> Unit>): Exception? {
    var first: Exception? = null
    for (action in actions) {
        try { action() } catch (error: Exception) {
            if (first == null) first = error else if (first !== error) first.addSuppressed(error)
        }
    }
    return first
}
