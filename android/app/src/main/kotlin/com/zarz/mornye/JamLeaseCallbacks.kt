package com.zarz.mornye

/** All callers waiting for the same lease receive exactly one result. */
internal class JamLeaseCallbacks {
    private val callbacks = mutableListOf<(Boolean) -> Unit>()
    fun add(callback: (Boolean) -> Unit) { callbacks.add(callback) }
    fun isNotEmpty() = callbacks.isNotEmpty()
    fun complete(value: Boolean) {
        val ready = callbacks.toList()
        callbacks.clear()
        ready.forEach { it(value) }
    }
}
