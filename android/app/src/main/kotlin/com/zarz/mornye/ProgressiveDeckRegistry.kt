package com.zarz.mornye

/** Identity only: keys contain no URLs, filesystem paths, or audio data. */
internal class ProgressiveDeckKey

/** Isolated prototype; no production code creates or registers this registry. */
internal class ProgressiveDeckRegistry(private val enabledForTesting: Boolean = false) : AutoCloseable {
    private val lock = Any()
    private val leases = mutableMapOf<ProgressiveDeckKey, ProgressiveAudioLease>()
    private var closed = false

    /** Transfers a fresh lease; an already registered lease is rejected without closing it. */
    fun attach(key: ProgressiveDeckKey, lease: ProgressiveAudioLease): Boolean {
        var revoke: ProgressiveAudioLease? = null
        val accepted = synchronized(lock) {
            if (leases.values.any { it === lease }) return false
            if (!enabledForTesting || closed) {
                revoke = lease
                false
            } else {
                revoke = leases.put(key, lease)
                true
            }
        }
        revoke?.close()
        return accepted
    }

    fun lookup(key: ProgressiveDeckKey): ProgressiveAudioLease? = synchronized(lock) { leases[key] }

    fun release(key: ProgressiveDeckKey) {
        val lease = synchronized(lock) { leases.remove(key) }
        lease?.close()
    }

    override fun close() {
        val revoke = synchronized(lock) {
            if (closed) return
            closed = true
            leases.values.toList().also { leases.clear() }
        }
        revoke.forEach { it.close() }
    }
}
