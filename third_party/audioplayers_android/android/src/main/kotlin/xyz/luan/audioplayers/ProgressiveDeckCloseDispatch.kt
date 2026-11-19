package xyz.luan.audioplayers

internal fun detachProgressiveSource(detach: () -> Int?, closeSource: () -> Unit): Int? {
    return try { detach() } finally { closeSource() }
}

/** Dispatches player detachment without blocking the caller. */
internal fun dispatchProgressiveDeckClose(
    post: (() -> Unit) -> Boolean,
    detach: () -> Int?,
    emergencyClose: () -> Unit,
    finish: (Int?, Boolean) -> Unit,
) {
    val finished = java.util.concurrent.atomic.AtomicBoolean(false)
    fun complete(position: Int?, confirmed: Boolean) {
        if (finished.compareAndSet(false, true)) finish(position, confirmed)
    }
    val accepted = try {
        post {
            val result = runCatching { detach() }
            complete(result.getOrNull(), result.isSuccess)
        }
    } catch (_: Exception) { false }
    if (!accepted) {
        runCatching { emergencyClose() }
        complete(null, false)
    }
}

internal class ProgressiveDeckCloseCallbacks {
    private val lock = Any()
    private var started = false
    private var result: Pair<Int?, Boolean>? = null
    private val callbacks = mutableListOf<(Int?, Boolean) -> Unit>()

    fun register(callback: (Int?, Boolean) -> Unit): Boolean {
        var settled: Pair<Int?, Boolean>? = null
        val start = synchronized(lock) {
            settled = result
            if (settled != null) false else {
                callbacks.add(callback)
                if (started) false else { started = true; true }
            }
        }
        settled?.let { callback(it.first, it.second) }
        return start
    }

    fun finish(position: Int?, confirmed: Boolean) {
        val pending = synchronized(lock) {
            if (result != null) return
            result = position to confirmed
            callbacks.toList().also { callbacks.clear() }
        }
        pending.forEach { runCatching { it(position, confirmed) } }
    }
}
