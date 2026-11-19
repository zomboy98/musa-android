package com.zarz.mornye

import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Bundle
import android.os.SystemClock
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.io.IOException
import java.lang.reflect.Proxy
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.ReleaseMode
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead

/** Native, offline cut: real Media3 output and EQ, controlled producer fixture; no Dart or Rust. */
@RunWith(AndroidJUnit4::class)
class Media3SingleEngineCommitInstrumentedTest {
    private fun field(owner: Any, name: String) = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }
    private enum class Stage { START, GUARDS_PASSED, FIXTURE_VERIFIED, DECK_OPTED_IN, ATTACH_BEGIN, ATTACHED,
        PREPARED, PLAY_BEGIN, PROGRESS_OBSERVED, PENDING_OBSERVED, SESSION_VALID, EQ_BEGIN, EQ_CONFIRMED,
        PAUSE_BEGIN, PAUSED, SEEK_BEGIN, SEEK_DEFERRED, SEEK_DISPATCHED, SEEK_CONFIRMED, COMMIT_SET, RESUME_BEGIN, COMPLETE_OBSERVED,
        ENDED_OBSERVED, COVERAGE_VERIFIED, IDENTITIES_VERIFIED, CLEANUP_BEGIN, CLOSE_CONFIRMED, CLEANUP_END, CASE_SUCCESS }
    private enum class Failure { ASSERTION, SECURITY, IO, ILLEGAL_STATE, OTHER, CLEANUP, GUARD, ATTACH_TIMEOUT, ATTACH_REJECTED,
        PREPARE_TIMEOUT, PROGRESS_TIMEOUT, PENDING_TIMEOUT, SESSION_TIMEOUT, EQ_MISSING, PAUSE_DRIFT, SEEK_TIMEOUT,
        COMPLETE_TIMEOUT, ENDED_TIMEOUT, COMMIT_MISSING, HIGH_WATER, TAIL_INCOMPLETE, IDENTITY_MISMATCH,
        UNEXPECTED_RETIREMENT, EARLY_REVOCATION, PLAYER_ERROR }
    private fun stage(value: Stage) { runCatching { InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("musa_single_engine_stage", value.name) }) } }
    private fun failure(value: Failure) { runCatching { InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("musa_single_engine_failure", value.name) }) } }
    private fun gate(kind: Failure, value: Boolean) { if (!value) { failure(kind); throw AssertionError("Single-engine check failed") } }

    @Test(timeout = 90000)
    fun partialCommitSeekAndEofKeepTheSameMedia3EngineAndEffect() {
        stage(Stage.START)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        gate(Failure.GUARD, context.packageName == "org.musa.music.catalogintegration")
        gate(Failure.GUARD, context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        assumeTrue(android.os.Build.VERSION.SDK_INT >= 28)
        gate(Failure.GUARD, context.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_MUSIC) == 0)
        stage(Stage.GUARDS_PASSED)
        val bytes = instrumentation.context.assets.open("synthetic_fragmented_aac_test.m4a").use { it.readBytes() }
        gate(Failure.GUARD, "6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58" == MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
        gate(Failure.GUARD, bytes.size > 2048); stage(Stage.FIXTURE_VERIFIED)
        val thread = HandlerThread("musa-single-engine-commit"); var handler: Handler? = null
        var deck: AudioplayersPlugin.ExperimentalProgressiveDeck? = null; var player: WrappedPlayer? = null; var events: EventHandler? = null
        var lastEqualizer: Any? = null
        val attached = AtomicBoolean(false); val failed = AtomicBoolean(false); val committed = AtomicBoolean(false)
        val revocations = AtomicInteger()
        val pending = CountDownLatch(1); val complete = CountDownLatch(1); val ended = CountDownLatch(1); val seekComplete = CountDownLatch(1); val retirement = AtomicInteger()
        fun <T> onLoop(action: () -> T): T {
            val active = checkNotNull(handler) { "Playback handler unavailable; cleanup unconfirmed" }
            val value = AtomicReference<T>(); val error = AtomicReference<Throwable>(); val done = CountDownLatch(1); val state = AtomicInteger(0)
            val task = Runnable { if (!state.compareAndSet(0, 1)) { done.countDown(); return@Runnable }; try { value.set(action()) } catch (t: Throwable) { error.set(t) } finally { done.countDown() } }
            check(active.post(task))
            if (!done.await(5, TimeUnit.SECONDS)) { val cancelled = state.compareAndSet(0, 2); if (cancelled) active.removeCallbacks(task); throw IllegalStateException(if (cancelled) "Playback task cancelled before start" else "Playback task timed out after start; cleanup unconfirmed") }
            error.get()?.let { throw it }; return value.get()
        }
        fun awaitState(kind: Failure, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 10000
            while (SystemClock.elapsedRealtime() < deadline && !failed.get()) { if (onLoop(condition)) return; Thread.sleep(25) }
            gate(Failure.PLAYER_ERROR, !failed.get())
            gate(kind, false)
        }
        var primary: Throwable? = null
        try {
            thread.start(); handler = Handler(thread.looper)
            onLoop {
                val plugin = AudioplayersPlugin(experimentalProgressiveForTesting = true, allowUnreadyMedia3ForInstrumentation = true)
                field(plugin, "context").set(plugin, context); field(plugin, "playbackThread").set(plugin, thread); field(plugin, "playbackHandler").set(plugin, handler)
                val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
                val eventHandler = EventHandler(EventChannel(messenger, "test/media3-commit")); events = eventHandler
                eventHandler.onListen(null, object : EventChannel.EventSink {
                    override fun success(event: Any?) { when ((event as? Map<*, *>)?.get("event")) { "audio.onComplete" -> complete.countDown(); "audio.onSeekComplete" -> seekComplete.countDown() } }
                    override fun error(code: String?, message: String?, details: Any?) { failed.set(true) }
                    override fun endOfStream() {}
                })
                val wrapped = WrappedPlayer::class.java.constructors.single().newInstance(plugin, eventHandler,
                    AudioContextAndroid().copy(audioFocus = AudioManager.AUDIOFOCUS_NONE), SoundPoolManager(plugin)) as WrappedPlayer
                player = wrapped; wrapped.volume = 0f; wrapped.releaseMode = ReleaseMode.STOP
                @Suppress("UNCHECKED_CAST")
                (field(plugin, "players").get(plugin) as ConcurrentHashMap<String, WrappedPlayer>)["commit-test"] = wrapped
                deck = checkNotNull(plugin.experimentalProgressiveDeck("commit-test", useMedia3 = true, replaceExisting = false, experimentalRequest = true))
                deck!!.enableSessionEqForInstrumentation()
                deck!!.onRetireRequested = { retirement.incrementAndGet() }
            }
            stage(Stage.DECK_OPTED_IN)
            val split = bytes.size - 1024
            val tailCoverage = BooleanArray(bytes.size - split); val coverageLock = Any(); var highWater = 0
            val lease = object : TimedProgressiveLease {
                override fun knownSize(): Long? = if (committed.get()) bytes.size.toLong() else null
                override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead {
                    if (revocations.get() != 0) throw IOException("lease revoked")
                    val available = if (committed.get()) bytes.size else split
                    if (position >= available) {
                        if (committed.get()) return TimedProgressiveRead.End
                        pending.countDown(); Thread.sleep(minOf(timeoutMs, 20).toLong()); return TimedProgressiveRead.Pending
                    }
                    val end = minOf(available.toLong(), position + maxBytes).toInt()
                    synchronized(coverageLock) {
                        highWater = maxOf(highWater, end)
                        for (index in maxOf(position.toInt(), split) until end) tailCoverage[index - split] = true
                    }
                    return TimedProgressiveRead.Bytes(bytes.copyOfRange(position.toInt(), end))
                }
            }
            val attachedDone = CountDownLatch(1)
            stage(Stage.ATTACH_BEGIN)
            deck!!.attachTimed(lease, { revocations.incrementAndGet() }) { attached.set(it); attachedDone.countDown() }
            gate(Failure.ATTACH_TIMEOUT, attachedDone.await(5, TimeUnit.SECONDS)); gate(Failure.ATTACH_REJECTED, attached.get())
            stage(Stage.ATTACHED)
            awaitState(Failure.PREPARE_TIMEOUT) { player!!.prepared }
            stage(Stage.PREPARED)
            val wrapper = onLoop { checkNotNull(field(player!!, "player").get(player)) }
            gate(Failure.IDENTITY_MISMATCH, wrapper.javaClass.simpleName == "Media3ProgressivePlayer")
            val engine = field(wrapper, "player").get(wrapper) as ExoPlayer; val effects = field(wrapper, "effects").get(wrapper)
            onLoop { engine.addListener(object : Player.Listener { override fun onPlaybackStateChanged(state: Int) { if (state == Player.STATE_ENDED) ended.countDown() } }) }
            stage(Stage.PLAY_BEGIN); onLoop { player!!.play() }
            awaitState(Failure.PROGRESS_TIMEOUT) { player!!.playing && (player!!.getCurrentPosition() ?: 0) >= 400 }
            stage(Stage.PROGRESS_OBSERVED)
            gate(Failure.PENDING_TIMEOUT, pending.await(5, TimeUnit.SECONDS))
            stage(Stage.PENDING_OBSERVED)
            awaitState(Failure.SESSION_TIMEOUT) { field(effects, "session").getInt(effects) > 0 }
            stage(Stage.SESSION_VALID); stage(Stage.EQ_BEGIN)
            onLoop { player!!.setEqualizer(mapOf("enabled" to true, "frequencies" to listOf(31f,62f,125f,250f,500f,1000f,2000f,4000f,8000f,16000f), "gains" to List(10) { 0f })) }
            val effect = onLoop { checkNotNull(field(effects, "effect").get(effects)) }
            lastEqualizer = effect.javaClass.declaredFields.single { it.type.simpleName == "PlaybackEqualizer" }.apply { isAccessible = true }.get(effect)
            gate(Failure.EQ_MISSING, onLoop { field(lastEqualizer!!, "effect").get(lastEqualizer) } != null)
            stage(Stage.EQ_CONFIRMED); stage(Stage.PAUSE_BEGIN)
            onLoop { player!!.pause() }; val paused = onLoop { checkNotNull(player!!.getCurrentPosition()) }
            Thread.sleep(150); gate(Failure.PAUSE_DRIFT, kotlin.math.abs(onLoop { checkNotNull(player!!.getCurrentPosition()) } - paused) <= 100)
            stage(Stage.PAUSED); stage(Stage.SEEK_BEGIN)
            // Diagnostic only: WrappedPlayer.seek keeps shouldSeekTo == position when it defers (not prepared / live stream), else resets it to -1.
            val seekDeferred = onLoop { player!!.seek(200); player!!.shouldSeekTo == 200 }; stage(if (seekDeferred) Stage.SEEK_DEFERRED else Stage.SEEK_DISPATCHED)
            gate(Failure.SEEK_TIMEOUT, seekComplete.await(5, TimeUnit.SECONDS)); stage(Stage.SEEK_CONFIRMED)
            committed.set(true) // Controlled fixture commit; no native/backend commit is fabricated.
            stage(Stage.COMMIT_SET); stage(Stage.RESUME_BEGIN)
            onLoop { gate(Failure.IDENTITY_MISMATCH, wrapper === field(player!!, "player").get(player) && engine === field(wrapper, "player").get(wrapper) && effect === field(effects, "effect").get(effects)); player!!.play() }
            gate(Failure.COMPLETE_TIMEOUT, complete.await(15, TimeUnit.SECONDS))
            stage(Stage.COMPLETE_OBSERVED)
            gate(Failure.ENDED_TIMEOUT, ended.await(5, TimeUnit.SECONDS)); stage(Stage.ENDED_OBSERVED); gate(Failure.COMMIT_MISSING, committed.get())
            synchronized(coverageLock) {
                gate(Failure.HIGH_WATER, bytes.size == highWater)
                gate(Failure.TAIL_INCOMPLETE, tailCoverage.all { it })
            }
            stage(Stage.COVERAGE_VERIFIED)
            onLoop { gate(Failure.IDENTITY_MISMATCH, wrapper === field(player!!, "player").get(player) && engine === field(wrapper, "player").get(wrapper) && effect === field(effects, "effect").get(effects)) }
            gate(Failure.UNEXPECTED_RETIREMENT, retirement.get() == 0); gate(Failure.EARLY_REVOCATION, revocations.get() == 0); gate(Failure.PLAYER_ERROR, !failed.get())
            stage(Stage.IDENTITIES_VERIFIED)
        } catch (error: Throwable) {
            failure(when (error) { is AssertionError -> Failure.ASSERTION; is SecurityException -> Failure.SECURITY; is IOException -> Failure.IO; is IllegalStateException -> Failure.ILLEGAL_STATE; else -> Failure.OTHER })
            primary = error; throw error
        }
        finally {
            stage(Stage.CLEANUP_BEGIN)
            val errors = mutableListOf<Throwable>(); fun clean(action: () -> Unit) { runCatching(action).exceptionOrNull()?.let(errors::add) }
            if (thread.isAlive && handler != null) {
                clean { val done = CountDownLatch(1); val confirmed = AtomicBoolean(false); deck?.closeWithStatus { _, ok -> confirmed.set(ok); done.countDown() } ?: run { confirmed.set(true); done.countDown() }; check(done.await(5, TimeUnit.SECONDS) && confirmed.get()) { "Deck close unconfirmed" }; stage(Stage.CLOSE_CONFIRMED) }
                clean { lastEqualizer?.let { eq -> assertNull(onLoop { field(eq, "effect").get(eq) }) } }
                clean { onLoop { player?.release() } }; clean { onLoop { events?.dispose() } }
                clean { if (attached.get()) assertEquals(1, revocations.get()) }
            } else if (deck != null || player != null || events != null) errors.add(IllegalStateException("Playback thread unavailable; cleanup unconfirmed"))
            clean { if (thread.isAlive) thread.quitSafely() }; clean { thread.join(5000); check(!thread.isAlive) { "Playback thread survived; cleanup unconfirmed" } }
            if (errors.isNotEmpty()) failure(Failure.CLEANUP)
            if (primary != null) errors.forEach(primary::addSuppressed) else if (errors.isNotEmpty()) { val first = errors.first(); errors.drop(1).forEach(first::addSuppressed); throw first }
            if (primary == null) { stage(Stage.CLEANUP_END); stage(Stage.CASE_SUCCESS) }
        }
    }
}
