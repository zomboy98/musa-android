package com.zarz.mornye

/** Tracks native lease lifetime without holding this monitor over cancellation. */
internal class CancellationLeaseTable<T : Any> {
    private val active = mutableMapOf<String, MutableList<T>>()
    private val cancellations = mutableMapOf<String, Int>()
    private val deferred = mutableMapOf<String, MutableList<T>>()
    @Synchronized fun add(id: String, lease: T) { active.getOrPut(id) { mutableListOf() }.add(lease) }
    @Synchronized fun beginCancel(id: String): Boolean {
        if (active[id].isNullOrEmpty()) return false
        cancellations[id] = (cancellations[id] ?: 0) + 1
        return true
    }
    @Synchronized fun remove(id: String, lease: T): List<T> {
        val entries = active[id] ?: return emptyList()
        val index = entries.indexOfFirst { it === lease }
        if (index < 0) return emptyList()
        entries.removeAt(index)
        if (entries.isEmpty()) active.remove(id)
        if ((cancellations[id] ?: 0) > 0) {
            deferred.getOrPut(id) { mutableListOf() }.add(lease)
            return emptyList()
        }
        return listOf(lease)
    }
    @Synchronized fun endCancel(id: String): List<T> {
        val count = checkNotNull(cancellations[id])
        if (count > 1) { cancellations[id] = count - 1; return emptyList() }
        cancellations.remove(id)
        return deferred.remove(id).orEmpty()
    }
}
