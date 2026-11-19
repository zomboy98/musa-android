package com.zarz.mornye

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead

/**
 * Instrumentation-only. NOT executed when written (no device, no Gradle run).
 *
 * Real Media3 `ExoPlayer` (through the real `Media3ProgressivePlayer`, `WrappedPlayer` and
 * `AudioplayersPlugin.ExperimentalProgressiveDeck`) fed by a local synthetic lease.
 * The player is only ever prepared and left PAUSED: `play()` / `start()` are never called, no
 * audio focus is requested and nothing is audible. Default renderers are used, so a decoder (and
 * possibly a paused AudioTrack) may exist; "silent" means no playback, not "no audio objects".
 *
 * Claim under test: when an EQ or balance change asks the Media3 deck to retire, the position
 * reported by the deck's close callback equals the paused position observed just before the
 * request, and the player stays paused throughout (never isPlaying, playWhenReady=false,
 * WrappedPlayer.playing=false).
 *
 * Does NOT enable MEDIA3_PROGRESSIVE_RUNTIME_READY: the deck is built by reflection because
 * `experimentalProgressiveDeck(..., useMedia3 = true)` returns null while that flag is false.
 * Does NOT prove: playing-state retirement, Dart/resume behaviour, the controller/Rust producer,
 * provider streams, bit-perfect output.
 */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class Media3RetirementInstrumentedTest {
    private companion object {
        const val PLAYER_ID = "media3-retirement-test"
        const val SEEK_TARGET_MS = 500L
        const val POSITION_TOLERANCE_MS = 50
        const val WAIT_S = 10L
    }

    private class Harness {
        val thread = HandlerThread("musa-media3-retirement").apply { start() }
        val handler = Handler(thread.looper)
        lateinit var plugin: AudioplayersPlugin
        lateinit var wrapped: WrappedPlayer
        lateinit var deck: AudioplayersPlugin.ExperimentalProgressiveDeck
        lateinit var eventHandler: EventHandler
        val revokes = AtomicInteger(0)

        /** Runs [block] on the playback looper (Exo's looper) and returns its result. */
        fun <T> onLoop(block: () -> T): T {
            val result = AtomicReference<T>()
            val error = AtomicReference<Throwable>()
            val done = CountDownLatch(1)
            assertTrue("looper rejected task", handler.post {
                try { result.set(block()) } catch (t: Throwable) { error.set(t) } finally { done.countDown() }
            })
            assertTrue("looper did not answer", done.await(WAIT_S, TimeUnit.SECONDS))
            error.get()?.let { throw it }
            return result.get()
        }
    }

    private fun field(owner: Any, name: String) =
        owner.javaClass.getDeclaredField(name).apply { isAccessible = true }

    private fun lease(bytes: ByteArray) = object : TimedProgressiveLease {
        override fun knownSize(): Long? = bytes.size.toLong()
        override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead {
            if (position >= bytes.size) return TimedProgressiveRead.End
            val start = position.toInt()
            val end = minOf(bytes.size, start + maxBytes)
            return TimedProgressiveRead.Bytes(bytes.copyOfRange(start, end))
        }
    }

    private fun build(h: Harness) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        h.plugin = AudioplayersPlugin(experimentalProgressiveForTesting = true)
        val pluginClass = AudioplayersPlugin::class.java
        pluginClass.getDeclaredField("context").apply { isAccessible = true }.set(h.plugin, instrumentation.targetContext)
        // Must be set before WrappedPlayer is constructed: it captures playbackDispatcher().
        pluginClass.getDeclaredField("playbackThread").apply { isAccessible = true }.set(h.plugin, h.thread)
        pluginClass.getDeclaredField("playbackHandler").apply { isAccessible = true }.set(h.plugin, h.handler)
        val messenger = Proxy.newProxyInstance(
            BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java),
        ) { _, _, _ -> null } as BinaryMessenger
        h.eventHandler = EventHandler(EventChannel(messenger, "test/media3-retirement"))
        h.wrapped = WrappedPlayer::class.java.constructors.single().newInstance(
            h.plugin, h.eventHandler, AudioContextAndroid(), SoundPoolManager(h.plugin),
        ) as WrappedPlayer
        @Suppress("UNCHECKED_CAST")
        (field(h.plugin, "players").get(h.plugin) as ConcurrentHashMap<String, WrappedPlayer>)[PLAYER_ID] = h.wrapped
        val generation = field(h.plugin, "generation").getInt(h.plugin)
        val ctor = Class.forName("xyz.luan.audioplayers.AudioplayersPlugin\$ExperimentalProgressiveDeck")
            .declaredConstructors.single().apply { isAccessible = true }
        h.deck = ctor.newInstance(h.plugin, h.wrapped, PLAYER_ID, generation, true) as AudioplayersPlugin.ExperimentalProgressiveDeck
    }

    private fun exo(h: Harness): ExoPlayer {
        val media3 = field(h.wrapped, "player").get(h.wrapped)
        assertNotNull("WrappedPlayer has no output", media3)
        return field(media3!!, "player").get(media3) as ExoPlayer
    }

    /**
     * [trigger] performs the EQ or balance change on the playback looper. It must request
     * retirement through the real WrappedPlayer setters.
     */
    private fun runRetirement(trigger: (WrappedPlayer) -> Unit, verifySettings: (WrappedPlayer) -> Unit) {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets
            .open("synthetic_seekable_sidx.m4a").use { it.readBytes() }
        val h = Harness()
        var primary: Throwable? = null
        try {
            h.onLoop { build(h) }

            val attached = CountDownLatch(1)
            val accepted = AtomicReference<Boolean>()
            val retireRequests = AtomicInteger(0)
            val atRequest = AtomicReference<Triple<Int?, Boolean, Boolean>>() // position, playing, playWhenReady
            val reported = AtomicReference<Int?>()
            val reportedLatch = CountDownLatch(1)
            val playerError = AtomicReference<String>()
            val isPlayingTrue = AtomicInteger(0)

            h.deck.onRetireRequested = {
                retireRequests.incrementAndGet()
                // Same order as production (ForkProgressiveDeck.discard -> deck.close): snapshot,
                // then close, which reads the position and releases the Exo instance.
                atRequest.set(Triple(h.wrapped.getCurrentPosition(), h.wrapped.playing, exo(h).playWhenReady))
                h.deck.close { position -> reported.set(position); reportedLatch.countDown() }
            }
            h.deck.attachTimed(lease(bytes), { h.revokes.incrementAndGet() }) { ok -> accepted.set(ok); attached.countDown() }
            assertTrue("attach callback missing", attached.await(WAIT_S, TimeUnit.SECONDS))
            assertEquals("deck refused the Media3 source", true, accepted.get())

            h.onLoop {
                exo(h).addListener(object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) { playerError.compareAndSet(null, error.errorCodeName) }
                    override fun onIsPlayingChanged(isPlaying: Boolean) { if (isPlaying) isPlayingTrue.incrementAndGet() }
                })
            }

            // Wait (bounded) for prepared. Never call play().
            val deadline = SystemClock.elapsedRealtime() + WAIT_S * 1000
            while (SystemClock.elapsedRealtime() < deadline && playerError.get() == null && !h.onLoop { h.wrapped.prepared }) Thread.sleep(50)
            assertNull("Exo error before retirement: ${playerError.get()}", playerError.get())
            assertTrue("player never became prepared", h.onLoop { h.wrapped.prepared })

            // A non-zero paused position is mandatory, otherwise "preserved" would be vacuously 0.
            // A fixture that cannot give one is a FAILURE of this test, never a skip (no assumeTrue).
            val seekable = h.onLoop { exo(h).isCurrentMediaItemSeekable }
            assertTrue("FIXTURE INADEQUATE: synthetic_seekable_sidx.m4a is not seekable through Exo " +
                "(isCurrentMediaItemSeekable=false), so no non-zero paused position can be established. " +
                "PENDING: generate a seekable fixture (e.g. fragmented AAC with sidx/known duration) " +
                "before this test can verify anything.", seekable)
            val duration = h.onLoop { exo(h).duration }
            assertTrue("FIXTURE INADEQUATE: duration is $duration ms (C.TIME_UNSET=${C.TIME_UNSET}); a known " +
                "duration > ${SEEK_TARGET_MS + POSITION_TOLERANCE_MS} ms is required to seek to the closed " +
                "target of $SEEK_TARGET_MS ms. PENDING: generate a longer/seekable fixture.",
                duration != C.TIME_UNSET && duration > SEEK_TARGET_MS + POSITION_TOLERANCE_MS)

            // Real seek termination. Exo reports the target position optimistically right after
            // seekTo(), so polling currentPosition alone proves nothing. Require (a) the SEEK
            // discontinuity and (b) a return to STATE_READY after seekTo (Exo masks BUFFERING at the
            // call), plus the position within tolerance of the closed target.
            val seekDiscontinuity = CountDownLatch(1)
            h.onLoop {
                exo(h).addListener(object : Player.Listener {
                    override fun onPositionDiscontinuity(
                        oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int,
                    ) { if (reason == Player.DISCONTINUITY_REASON_SEEK) seekDiscontinuity.countDown() }
                })
            }
            h.onLoop { exo(h).seekTo(SEEK_TARGET_MS) }
            assertTrue("Exo never reported the SEEK discontinuity", seekDiscontinuity.await(WAIT_S, TimeUnit.SECONDS))
            val seekDeadline = SystemClock.elapsedRealtime() + WAIT_S * 1000
            while (SystemClock.elapsedRealtime() < seekDeadline && playerError.get() == null &&
                !h.onLoop {
                    exo(h).playbackState == Player.STATE_READY &&
                        kotlin.math.abs(exo(h).currentPosition - SEEK_TARGET_MS) <= POSITION_TOLERANCE_MS
                }) Thread.sleep(50)
            assertNull("Exo error during seek: ${playerError.get()}", playerError.get())
            assertEquals("seek did not complete: Exo not READY after seekTo", Player.STATE_READY,
                h.onLoop { exo(h).playbackState })

            // Paused, and the position is stable (not advancing).
            val p1 = h.onLoop { exo(h).currentPosition }
            Thread.sleep(300)
            val p2 = h.onLoop { exo(h).currentPosition }
            assertFalse("playWhenReady must be false", h.onLoop { exo(h).playWhenReady })
            assertFalse("must not be playing", h.onLoop { exo(h).isPlaying })
            assertFalse("WrappedPlayer.playing must be false", h.onLoop { h.wrapped.playing })
            assertEquals("paused position moved", p1, p2)
            assertTrue("paused position $p2 not within ${POSITION_TOLERANCE_MS}ms of closed target $SEEK_TARGET_MS",
                kotlin.math.abs(p2 - SEEK_TARGET_MS) <= POSITION_TOLERANCE_MS)

            // Precondition: the setting that follows must be what flips Media3 eligibility.
            assertTrue("precondition: deck must be Media3-eligible before the change",
                h.onLoop { h.wrapped.supportsExperimentalMedia3() })

            // Request retirement through the real setting entry point.
            h.onLoop { trigger(h.wrapped) }
            assertTrue("retirement report missing", reportedLatch.await(WAIT_S, TimeUnit.SECONDS))

            assertEquals("retire requests", 1, retireRequests.get())
            val snapshot = atRequest.get()
            assertNotNull("no request-time snapshot", snapshot)
            val (requestPosition, requestPlaying, requestPlayWhenReady) = snapshot
            assertFalse("playing at request", requestPlaying)
            assertFalse("playWhenReady at request", requestPlayWhenReady)
            // Request snapshot against the closed value (the seek target), not against another
            // reading of the same player.
            assertNotNull("WrappedPlayer reported no position at request", requestPosition)
            assertTrue("request-time position $requestPosition not within ${POSITION_TOLERANCE_MS}ms of " +
                "closed target $SEEK_TARGET_MS",
                kotlin.math.abs(requestPosition!! - SEEK_TARGET_MS.toInt()) <= POSITION_TOLERANCE_MS)
            val reportedPosition = reported.get()
            assertNotNull("deck reported no position", reportedPosition)
            assertTrue("reported $reportedPosition not within ${POSITION_TOLERANCE_MS}ms of request snapshot " +
                "$requestPosition", kotlin.math.abs(reportedPosition!! - requestPosition) <= POSITION_TOLERANCE_MS)
            assertTrue("reported $reportedPosition not within ${POSITION_TOLERANCE_MS}ms of closed target " +
                "$SEEK_TARGET_MS", kotlin.math.abs(reportedPosition - SEEK_TARGET_MS.toInt()) <= POSITION_TOLERANCE_MS)
            assertEquals("Exo was playing at some point", 0, isPlayingTrue.get())
            assertFalse("WrappedPlayer.playing after retirement", h.onLoop { h.wrapped.playing })
            assertNull("source not detached", h.onLoop { h.wrapped.source })
            assertEquals("lease revoked exactly once", 1, h.revokes.get())
            assertNull("Exo error: ${playerError.get()}", playerError.get())
            // After EQ enable / non-zero balance the Media3 path must no longer be eligible.
            assertFalse("supportsExperimentalMedia3 must be false after the EQ/balance change",
                h.onLoop { h.wrapped.supportsExperimentalMedia3() })
            h.onLoop { verifySettings(h.wrapped) }
        } catch (t: Throwable) {
            primary = t
            throw t
        } finally {
            runCatching { h.deck.close { } }
            runCatching { h.onLoop { h.wrapped.release() } }
            runCatching { h.onLoop { h.eventHandler.dispose() } }
            h.thread.quitSafely()
            val joined = runCatching { h.thread.join(5000); !h.thread.isAlive }.getOrDefault(false)
            if (!joined && primary == null) throw AssertionError("cleanup incomplete: looper thread alive")
        }
    }

    @Test(timeout = 90000)
    fun balanceChangeRetiresPausedDeckAndReportsPausedPosition() = runRetirement(
        trigger = { it.balance = 0.4f },
        verifySettings = { assertEquals(0.4f, it.balance, 0.001f) },
    )

    @Test(timeout = 90000)
    fun equalizerEnableRetiresPausedDeckAndReportsPausedPosition() = runRetirement(
        trigger = { it.setEqualizer(mapOf("enabled" to true, "preamp" to 3)) },
        verifySettings = { /* equalizerEnabled is private; retirement request count is asserted above */ },
    )
}
