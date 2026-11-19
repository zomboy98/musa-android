package com.zarz.mornye

import java.util.concurrent.CountDownLatch
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** A bridge registers cancellation on the fork request before submitting it. */
internal class KeyReadRequest {
    private val lock = Any()
    private var cancelled = false
    private var registered = false
    private var cancellation: (() -> Unit)? = null

    fun onCancel(action: () -> Unit) {
        val callNow = synchronized(lock) {
            check(!registered) { "Cancellation already registered" }
            registered = true
            if (cancelled) true else { cancellation = action; false }
        }
        if (callNow) action()
    }

    fun isCancelled(): Boolean = synchronized(lock) { cancelled }

    fun cancel() {
        val action = synchronized(lock) {
            if (cancelled) null else { cancelled = true; cancellation.also { cancellation = null } }
        }
        action?.invoke()
    }
}

/** Reader must register its fork cancellation before it submits the operation. */
internal fun interface QueuedExtensionKeyReader { fun read(request: KeyReadRequest, callback: (String?) -> Unit) }

internal class ExperimentalKeyAccess(private val enabled: Boolean, private val reader: QueuedExtensionKeyReader?) {
    companion object {
        // One daemon and at most one pending attempt. A cancelled pending
        // attempt checks its token before entering the reader.
        private val executor = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
            { task -> Thread(task, "experimental-key-read").apply { isDaemon = true } })
        internal fun pendingCountForTest(): Int = executor.queue.size
    }

    fun read(active: () -> Boolean, timeoutMs: Long): String? {
        if (!enabled || reader == null || !active() || timeoutMs <= 0) return null
        val lock = Any()
        val done = CountDownLatch(1)
        val request = KeyReadRequest()
        var completed = false
        var value: String? = null
        val work = Runnable {
            try {
                if (!request.isCancelled()) reader.read(request) { result -> synchronized(lock) {
                    if (!completed) { completed = true; value = result; done.countDown() }
                } }
            } catch (_: Exception) {
                synchronized(lock) { if (!completed) { completed = true; done.countDown() } }
            }
        }
        try {
            executor.execute(work)
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtMost(86_400_000))
            while (true) {
                if (!active()) return null
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) return null
                if (done.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(25)), TimeUnit.NANOSECONDS)) break
            }
            return synchronized(lock) { val result = if (active()) value else null; value = null; result }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        } catch (_: Exception) {
            return null
        } finally {
            synchronized(lock) { completed = true; value = null }
            try { request.cancel() } catch (_: Exception) { }
            executor.remove(work)
        }
    }
}

/** Compile-time off until the fork and Android integration pass validation. */
internal object BackgroundKeyProvider {
    const val ENABLED = false
    private val reader: QueuedExtensionKeyReader? = null
    fun current() = ExperimentalKeyAccess(ENABLED, reader)
}
