package com.zarz.mornye

import java.util.concurrent.Executor
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal sealed class ProgressiveCandidate {
    data class Available(val sequence: Long, val lease: ProgressiveAudioLease) : ProgressiveCandidate()
    data object Pending : ProgressiveCandidate()
    data object Finished : ProgressiveCandidate()
    data object Closed : ProgressiveCandidate()
}
internal enum class ProgressiveTerminal { Pending, Committed, Invalidated, Aborted }
internal interface ProgressiveControllerSession : AutoCloseable {
    fun download()
    fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate
    fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int): ProgressiveTerminal
    override fun close()
}
/** Implementations must return promptly and run only on the injected background executor. */
internal interface ProgressiveControllerDeck {
    fun open(lease: ProgressiveAudioLease)
    fun discard()
    /** Called off the playback thread after discard; synchronous decks are already closed. */
    fun awaitDiscard(timeoutMs: Long): Boolean = true
}

/** Experimental only. Cancellation and its completion waits must not share producer workers. */
internal class ProgressiveDeckController(
    private val io: Executor,
    private val sessionFactory: () -> ProgressiveControllerSession,
    private val deck: ProgressiveControllerDeck,
    private val fallback: () -> Unit,
    private val onSourceAttached: () -> Unit = {},
    private val onCancellationFailure: () -> Unit = {},
    private val onTerminalFailure: () -> Unit = {},
    private val onSourceCommitted: () -> Unit = {},
    private val onSourceRetired: () -> Unit = {},
    private val onSourceRetiring: () -> Unit = {},
    private val cleanup: Executor = io,
    private val completion: Executor = Executor { it.run() },
    private val downloadWaitMs: Long = 10_000L,
    private val discardWaitMs: Long = 2_000L,
) : AutoCloseable {
    private val lock = Any()
    private var session: ProgressiveControllerSession? = null
    private var started = false
    private var opening = false
    private var stopped = false
    private var retired = false
    private var requested = false
    private val downloadFinished = CountDownLatch(1)
    private val factoryFinished = CountDownLatch(1)
    private val factoryCleanupFailed = java.util.concurrent.atomic.AtomicBoolean(false)
    private var outcome: Boolean? = null
    private val waiters = ArrayList<(Boolean) -> Unit>()
    private val closeAcknowledged = java.util.concurrent.atomic.AtomicBoolean(false)

    fun start() {
        synchronized(lock) { check(!requested); requested = true }
        try {
            io.execute startTask@{
                if (synchronized(lock) { stopped }) { factoryFinished.countDown(); return@startTask }
                val created = try { sessionFactory() } catch (_: Exception) { factoryFinished.countDown(); failBeforeStart(); return@startTask }
                synchronized(lock) {
                    if (stopped) { runCleanup { try { created.close() } catch (_: Exception) { factoryCleanupFailed.set(true) } finally { factoryFinished.countDown() } }; return@startTask }
                    session = created
                    factoryFinished.countDown()
                }
                try {
                    io.execute downloadTask@{
                        try {
                            if (synchronized(lock) { stopped }) return@downloadTask
                            created.download()
                            if (synchronized(lock) { retired && !stopped }) onSourceCommitted()
                        } catch (_: Exception) { fail() } finally { downloadFinished.countDown() }
                    }
                } catch (_: java.util.concurrent.RejectedExecutionException) {
                    downloadFinished.countDown(); fail(); return@startTask
                }
                try { io.execute { observe(created) } }
                catch (_: java.util.concurrent.RejectedExecutionException) { fail() }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            synchronized(lock) { stopped = true }
            factoryFinished.countDown()
            onCancellationFailure()
            settle(false)
        }
    }

    private fun runCleanup(action: () -> Unit) {
        try { cleanup.execute(action) }
        catch (_: java.util.concurrent.RejectedExecutionException) {
            // A channel shutdown racing with startup must still revoke its owner.
            Thread(action, "musa-progressive-cleanup").apply { isDaemon = true; start() }
        }
    }

    private fun runCompletion(action: () -> Unit) {
        try { completion.execute(action) }
        catch (_: java.util.concurrent.RejectedExecutionException) {
            Thread(action, "musa-progressive-completion").apply { isDaemon = true; start() }
        }
    }

    private fun observe(owner: ProgressiveControllerSession) {
        try {
            while (true) {
                if (synchronized(lock) { stopped || retired }) return
                when (val next = owner.nextLease(0, 1000)) {
                    ProgressiveCandidate.Pending -> continue
                    ProgressiveCandidate.Closed -> { failBeforeStart(); return }
                    ProgressiveCandidate.Finished -> {
                        // A successful producer can publish Finished just before its
                        // JSON result returns. Let it finish before cancelling.
                        if (!waitForDownload()) { cancelAfterDownloadTimeout(); return }
                        failBeforeStart()
                        return
                    }
                    is ProgressiveCandidate.Available -> {
                        synchronized(lock) {
                            if (stopped || retired) { next.lease.close(); return }
                            opening = true
                        }
                        try { deck.open(next.lease) } catch (error: Exception) {
                            runCatching { next.lease.close() }
                            throw error
                        }
                        val cancelled = synchronized(lock) {
                            opening = false
                            if (!stopped && !retired) started = true
                            stopped || retired
                        }
                        if (cancelled) { discardSafely(); return }
                        synchronized(lock) { if (!stopped && !retired) onSourceAttached() }
                        while (!synchronized(lock) { stopped || retired }) {
                            val terminal = owner.waitTerminal(next.lease, 1000)
                            if (synchronized(lock) { stopped || retired }) return
                            when (terminal) {
                                ProgressiveTerminal.Pending -> continue
                                ProgressiveTerminal.Committed -> { onSourceCommitted(); return }
                                // Rejection after playback starts must retire the
                                // deck and wait for the producer before fallback.
                                ProgressiveTerminal.Aborted -> { invalidate(); return }
                                ProgressiveTerminal.Invalidated -> { invalidate(); return }
                            }
                        }
                        return
                    }
                }
            }
        } catch (_: Exception) { if (!synchronized(lock) { retired }) fail() }
    }

    /** Retire a deck without cancelling a useful producer; its final result remains usable. */
    fun retireSource() {
        val discard = synchronized(lock) {
            if (stopped || retired) return
            retired = true
            started || opening
        }
        if (discard) {
            onSourceRetiring()
            if (!discardSafely()) { onCancellationFailure(); return }
            runCleanup {
                val closed = try { deck.awaitDiscard(discardWaitMs) } catch (_: Exception) { false }
                if (!synchronized(lock) { stopped }) {
                    if (closed) onSourceRetired() else onCancellationFailure()
                }
            }
        }
    }

    private fun discardSafely(): Boolean = try { deck.discard(); true } catch (_: Exception) { false }

    private fun fail() = stop(onlyBeforeStart = false)
    private fun failBeforeStart() = stop(onlyBeforeStart = true)
    private fun invalidate() = stop(onlyBeforeStart = false)

    /** Single critical section: the started/opening decision and the stop cannot be split. */
    private fun stop(onlyBeforeStart: Boolean) {
        val (owner, discarded) = synchronized(lock) {
            if (stopped || (onlyBeforeStart && started)) return
            stopped = true
            session to (started || opening)
        }
        val discardOk = !discarded || discardSafely()
        finishBeforeFallback(owner, discardOk, discarded)
    }

    /**
     * The producer never returned after publishing Finished. Mark the controller stopped and close
     * the session on the cleanup executor (never on the caller), then report the failure exactly
     * once. No fallback: the producer may still be running, so a fallback would be misleading.
     */
    private fun cancelAfterDownloadTimeout() {
        val (owner, discarded) = synchronized(lock) {
            if (stopped) return // another path already owns cleanup and the single outcome
            stopped = true
            session to (started || opening)
        }
        if (discarded) discardSafely()
        runCleanup {
            runCatching { owner?.close() }
            onCancellationFailure()
            settle(false)
        }
    }

    private fun finishBeforeFallback(owner: ProgressiveControllerSession?, discardOk: Boolean, discarded: Boolean) {
        if (owner == null) {
            if (discardOk) fallback() else onCancellationFailure()
            settle(discardOk)
            return
        }
        runCleanup {
            // The session is always closed, even when the deck could not be discarded.
            val closed = try { owner.close(); true } catch (_: Exception) { false }
            val deckClosed = discardOk && (!discarded || awaitDiscardSafely())
            if (!closed || !deckClosed) { onCancellationFailure(); settle(false); return@runCleanup }
            runCompletion {
                val finished = waitForDownload()
                settle(finished)
                if (finished) fallback() else onCancellationFailure()
            }
        }
    }

    private fun awaitDiscardSafely(): Boolean = try { deck.awaitDiscard(discardWaitMs) } catch (_: Exception) { false }

    /** Records the real close outcome once and notifies every waiter registered so far. */
    private fun settle(success: Boolean) {
        val pending = synchronized(lock) {
            if (outcome != null) return
            outcome = success
            if (success) closeAcknowledged.set(true)
            waiters.toList().also { waiters.clear() }
        }
        pending.forEach { runCatching { it(success) } }
    }

    private fun waitForDownload(): Boolean = waitFor(downloadFinished)
    private fun waitFor(latch: CountDownLatch): Boolean = try {
        latch.await(downloadWaitMs, TimeUnit.MILLISECONDS)
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
    }

    fun closeAndNotify(completed: (Boolean) -> Unit) {
        var immediate: Boolean? = null
        val cleanup = synchronized(lock) {
            if (stopped) {
                // Already stopping (earlier close or failure): answer only when that cleanup settles.
                val known = outcome
                if (known == null) waiters.add(completed) else immediate = known
                null
            } else {
                stopped = true
                if (!requested) factoryFinished.countDown()
                waiters.add(completed)
                (started || opening) to session
            }
        }
        immediate?.let { completed(it); return }
        if (cleanup == null) return
        runCleanup {
            val discardOk = if (cleanup.first) discardSafely() else true
            val closeOk = try { cleanup.second?.close(); true } catch (_: Exception) { false }
            val deckClosed = discardOk && (!cleanup.first || awaitDiscardSafely())
            if (!deckClosed || !closeOk) { settle(false); return@runCleanup }
            runCompletion {
                settle(if (cleanup.second == null) waitFor(factoryFinished) && !factoryCleanupFailed.get() else waitForDownload())
            }
        }
    }
    override fun close() = closeAndNotify { }
}
