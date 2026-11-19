package com.zarz.mornye

import com.mornye.backend.ExtensionManager
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.source.TimedProgressiveLease

/** Native-only experiment. No UI, method channel, or production caller enables it. */
internal class ExperimentalProgressiveBridge(
    private val io: Executor,
    private val enabledForTesting: Boolean = false,
    private val cleanup: Executor = io,
    private val completion: Executor = Executor { it.run() },
    private val instrumentationSessionFactory: ((String, (String) -> Unit) -> ProgressiveControllerSession)? = null,
) {
    fun start(
        manager: ExtensionManager?,
        requestJson: String,
        target: AudioplayersPlugin.ExperimentalProgressiveDeck?,
        fallback: (Long?) -> Unit,
        onSourceAttached: () -> Unit = {},
        onDownloadResult: (String) -> Unit = {},
        onCancellationFailure: () -> Unit = {},
        onTerminalFailure: (Long?) -> Unit = {},
        onSourceCommitted: () -> Unit = {},
        onSourceRetired: (Long?) -> Unit = {},
        onSourceRetiring: () -> Unit = {},
    ): ProgressiveDeckController? {
        if (!enabledForTesting || target == null) {
            io.execute { fallback(null) }
            return null
        }
        val sink = ForkProgressiveDeck(target)
        val controller = ProgressiveDeckController(io, {
            instrumentationSessionFactory?.invoke(requestJson, onDownloadResult) ?: run {
                val owner = checkNotNull(manager) { "Progressive backend unavailable" }
                val session = owner.createProgressiveSession()
                UniffiSessionAdapter(session, { owner.downloadProgressive(requestJson, session) }, ::isProgressiveDownloadSuccess, onDownloadResult)
            }
        }, sink, { fallback(sink.position()) }, onSourceAttached, onCancellationFailure, { onTerminalFailure(sink.position()) }, onSourceCommitted, { onSourceRetired(sink.position()) }, onSourceRetiring, cleanup, completion)
        sink.onRetireRequested = controller::retireSource
        controller.start()
        return controller
    }
}

/** Acceptance only means MediaPlayer was given a source, never that it played. */
private class ForkProgressiveDeck(private val target: AudioplayersPlugin.ExperimentalProgressiveDeck) : ProgressiveControllerDeck {
    private val cancelled = AtomicBoolean(false)
    private val completed = CountDownLatch(1)
    private val discarded = CountDownLatch(1)
    @Volatile var onRetireRequested: (() -> Unit)? = null
    @Volatile private var accepted = false
    @Volatile private var finalPosition: Long? = null
    @Volatile private var discardConfirmed = false

    override fun open(lease: ProgressiveAudioLease) {
        if (cancelled.get()) throw IOException("Deck cancelled")
        val onAttached: (Boolean) -> Unit = { accepted = it; completed.countDown() }
        if (target.useMedia3) {
            val timed = lease as? TimedProgressiveLease ?: throw IOException("Timed lease unavailable")
            target.onRetireRequested = { onRetireRequested?.invoke() }
            target.attachTimed(timed, { lease.close() }, onAttached)
        } else {
            target.attach(ProgressiveLeaseMediaDataSource(lease), onAttached)
        }
        if (!completed.await(10, TimeUnit.SECONDS) || cancelled.get() || !accepted) {
            discard()
            throw IOException("Deck could not accept source")
        }
    }

    override fun discard() {
        if (cancelled.compareAndSet(false, true)) {
            target.closeWithStatus { position, confirmed -> finalPosition = position?.toLong(); discardConfirmed = confirmed; discarded.countDown() }
            completed.countDown()
        }
    }
    override fun awaitDiscard(timeoutMs: Long): Boolean = try {
        discarded.await(timeoutMs, TimeUnit.MILLISECONDS) && discardConfirmed
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
    }
    fun position(): Long? {
        if (cancelled.get()) discarded.await(2, TimeUnit.SECONDS)
        return finalPosition
    }
}
