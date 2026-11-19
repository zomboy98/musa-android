package com.zarz.mornye

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.source.TimedProgressiveDataSource
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** Instrumentation-only AAC decode through real ExoPlayer and MediaCodec.
 * The only renderer uses a PCM-discarding sink: no AudioTrack, provider or network.
 * Sink readiness/clock fix is not yet compiled or executed. APIs inspected from cached Media3 1.9.2.
 */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class ExoSyntheticPcmDecodeInstrumentedTest {
    private companion object {
        const val TAG = "MusaExoInstrumented"
        const val FIRST_READ_WAIT_S = 10L
        const val READY_BEFORE_RELEASE_WAIT_S = 10L
        const val CLEANUP_WAIT_S = 5L
    }

    @Test(timeout = 90000)
    fun decodesNonSilentPcmBeforeTheSyntheticTransferCompletes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val bytes = instrumentation.context.assets.open("synthetic_fragmented_aac_test.m4a").use { it.readBytes() }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals("6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58", digest)
        val split = bytes.size / 2
        assertTrue("fixture too small to split", split > 0)

        val release = CountDownLatch(1)
        val barrierReleased = AtomicBoolean(false)
        val firstRead = CountDownLatch(1)
        val outcome = CountDownLatch(1)          // opens on READY *or* error
        val ready = AtomicBoolean(false)
        val failure = AtomicReference<String>()
        val closed = AtomicBoolean(false)
        val earlyPcm = CountDownLatch(1)
        val ended = CountDownLatch(1)
        val pcmBeforeRelease = AtomicBoolean(false)
        val pcmHighWater = AtomicLong(-1)

        // Measured by the lease itself, not inferred.
        val servedBytes = AtomicLong(0)
        val highWater = AtomicLong(0)            // max (position + served length)
        val blockedReads = AtomicInteger(0)      // reads that hit the barrier
        val servedAtReady = AtomicLong(-1)
        val highWaterAtReady = AtomicLong(-1)
        val releasedAtReady = AtomicBoolean(true)
        val readyAt = AtomicLong(0)
        val audioSelectedAtReady = AtomicBoolean(false)
        val sink = CapturingPcmSink {
            if (!barrierReleased.get()) {
                pcmHighWater.set(highWater.get())
                pcmBeforeRelease.set(true)
                earlyPcm.countDown()
            }
        }
        val begin = SystemClock.elapsedRealtimeNanos()

        val source = object : TimedProgressiveLease {
            override fun knownSize(): Long? = if (barrierReleased.get()) bytes.size.toLong() else null
            override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead {
                if (closed.get()) throw java.io.IOException("lease closed")
                firstRead.countDown()
                if (position >= split && !barrierReleased.get()) {
                    blockedReads.incrementAndGet()
                    release.await(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                }
                if (closed.get()) throw java.io.IOException("lease closed")
                val released = barrierReleased.get()
                val available = if (released) bytes.size else split
                if (position >= available) return if (released) TimedProgressiveRead.End else TimedProgressiveRead.Pending
                val start = position.toInt()
                val end = minOf(available, start + maxBytes)
                servedBytes.addAndGet((end - start).toLong())
                highWater.accumulateAndGet(end.toLong()) { a, b -> maxOf(a, b) }
                return TimedProgressiveRead.Bytes(bytes.copyOfRange(start, end))
            }
        }

        val thread = HandlerThread("musa-exo-instrumented").apply { start() }
        val handler = Handler(thread.looper)
        val player = AtomicReference<ExoPlayer>()
        var primary: Throwable? = null
        var cleaned = false

        /** Runs [block] on the player looper and waits (bounded) for its result. */
        fun <T> onPlayer(block: (ExoPlayer) -> T): T {
            val result = AtomicReference<T>()
            val error = AtomicReference<Throwable>()
            val done = CountDownLatch(1)
            assertTrue("player looper rejected task", handler.post {
                try { result.set(block(player.get() ?: throw IllegalStateException("player not created"))) }
                catch (t: Throwable) { error.set(t) } finally { done.countDown() }
            })
            assertTrue("player looper did not answer", done.await(5, TimeUnit.SECONDS))
            error.get()?.let { throw it }
            return result.get()
        }

        try {
            val created = CountDownLatch(1)
            assertTrue(handler.post {
                try {
                    val renderer = androidx.media3.exoplayer.audio.MediaCodecAudioRenderer(
                        context, androidx.media3.exoplayer.mediacodec.MediaCodecSelector.DEFAULT,
                        handler, null, sink)
                    val exo = ExoPlayer.Builder(context, RenderersFactory { _, _, _, _, _ -> arrayOf(renderer) })
                        .setLooper(thread.looper).build()
                    player.set(exo)
                    exo.playWhenReady = true
                    exo.addListener(object : Player.Listener {
                        override fun onPlaybackStateChanged(state: Int) {
                            if (state == Player.STATE_ENDED) ended.countDown()
                            if (state != Player.STATE_READY || ready.get()) return
                            // Order matters: released flag, bytes, released flag again.
                            val before = barrierReleased.get()
                            servedAtReady.set(servedBytes.get())
                            highWaterAtReady.set(highWater.get())
                            val after = barrierReleased.get()
                            releasedAtReady.set(before || after)
                            audioSelectedAtReady.set(exo.currentTracks.isTypeSelected(C.TRACK_TYPE_AUDIO))
                            readyAt.set(SystemClock.elapsedRealtimeNanos())
                            ready.set(true)
                            outcome.countDown()
                        }
                        override fun onPlayerError(error: PlaybackException) {
                            failure.compareAndSet(null, "${error.errorCodeName}(${error.errorCode})")
                            outcome.countDown()
                            earlyPcm.countDown()
                            ended.countDown()
                        }
                    })
                    exo.setMediaSource(ProgressiveMediaSource.Factory(TimedProgressiveDataSource.Factory(source))
                        .createMediaSource(MediaItem.fromUri("musa-progressive://lease")))
                    exo.prepare()
                } catch (error: Throwable) {
                    failure.compareAndSet(null, "setup:${error.javaClass.simpleName}:${error.message}")
                    outcome.countDown()
                } finally {
                    created.countDown()
                }
            })
            assertTrue("player was not created in time", created.await(10, TimeUnit.SECONDS))
            assertNull("Exo setup/prepare error", failure.get())
            assertTrue("source was never read", firstRead.await(FIRST_READ_WAIT_S, TimeUnit.SECONDS))

            // Phase 1: barrier still closed. Only READY or an error can open `outcome`.
            val settledBeforeRelease = outcome.await(READY_BEFORE_RELEASE_WAIT_S, TimeUnit.SECONDS)
            val servedNow = servedBytes.get()
            val highWaterNow = highWater.get()
            val stateBeforeRelease = onPlayer { it.playbackState }
            val releasedYet = barrierReleased.get() // must still be false: only this thread releases
            assertFalse("barrier released before phase 1 ended", releasedYet)
            assertNull("Exo error before release (not READY): ${failure.get()}", failure.get())
            assertTrue("no STATE_READY within ${READY_BEFORE_RELEASE_WAIT_S}s with the barrier closed " +
                "(state=$stateBeforeRelease served=$servedNow/${bytes.size} blockedReads=${blockedReads.get()} " +
                "pcm=${sink.snapshot()})",
                settledBeforeRelease && ready.get())
            // The prefix may already be drained: BUFFERING here is legitimate.
            assertTrue("player left prepared state", stateBeforeRelease == Player.STATE_READY ||
                stateBeforeRelease == Player.STATE_BUFFERING)
            assertFalse("READY was observed only after release", releasedAtReady.get())
            assertTrue("lease served past the barrier: high-water=${highWaterAtReady.get()} split=$split",
                highWaterAtReady.get() in 1..split.toLong())
            assertTrue("no bytes served by READY: ${servedAtReady.get()}",
                servedAtReady.get() > 0)
            assertTrue("high-water after phase 1 beyond split: $highWaterNow > $split", highWaterNow <= split)
            assertTrue("audio track was not selected", audioSelectedAtReady.get())
            assertTrue("no early PCM before barrier release; error=${failure.get()}",
                earlyPcm.await(10, TimeUnit.SECONDS))
            assertNull("codec failed before barrier release", failure.get())
            assertTrue("PCM only arrived after release", pcmBeforeRelease.get())
            assertTrue("PCM arrived after reading beyond barrier",
                pcmHighWater.get() in 1..split.toLong())
            assertFalse("barrier was released before PCM assertion", barrierReleased.get())

            // Phase 2: release the rest and require actual decoder completion.
            val readyMs = TimeUnit.NANOSECONDS.toMillis(readyAt.get() - begin)
            barrierReleased.set(true)
            release.countDown()
            assertTrue("decode did not end; error=${failure.get()}", ended.await(15, TimeUnit.SECONDS))
            assertNull("Exo decode failed", failure.get())
            assertEquals("decode did not reach ENDED", Player.STATE_ENDED, onPlayer { it.playbackState })
            val stats = sink.snapshot()
            assertTrue("no decoded PCM", stats.bytes > 0)
            assertTrue("decoded PCM was silent", stats.squareSum > 0.0)
            assertTrue("PCM timestamps regressed", stats.monotonic)
            assertTrue("invalid PCM format", stats.sampleRate > 0 && stats.channels > 0)
            // The synthetic fixture contains several seconds of audio. This loose
            // lower bound detects a lone output buffer without assuming AAC priming.
            assertTrue("PCM output too short", stats.frames >= stats.sampleRate.toLong())
            Log.i(TAG, "early_pcm=true high_water_at_pcm=${pcmHighWater.get()} split=$split " +
                "ready_ms=$readyMs pcm_bytes=${stats.bytes} pcm_frames=${stats.frames} " +
                "sample_rate=${stats.sampleRate} channels=${stats.channels} high_water_final=${highWater.get()}")
        } catch (t: Throwable) {
            primary = t
            throw t
        } finally {
            closed.set(true)
            barrierReleased.set(true)
            release.countDown()
            var disposed = false
            val done = CountDownLatch(1)
            val releaseError = AtomicReference<Throwable>()
            val posted = try {
                handler.post {
                    try { player.get()?.release() }
                    catch (t: Throwable) { releaseError.set(t) }
                    finally { done.countDown() }
                }
            } catch (_: Throwable) { false }
            disposed = if (posted) done.await(CLEANUP_WAIT_S, TimeUnit.SECONDS) else player.get() == null
            thread.quitSafely()
            thread.join(5000)
            cleaned = disposed && !thread.isAlive && releaseError.get() == null
            if (!cleaned) {
                Log.e(TAG, "cleanup incomplete: player disposed=$disposed thread alive=${thread.isAlive}")
                if (primary == null) fail("cleanup incomplete: player disposed=$disposed thread alive=${thread.isAlive}")
            }
        }
    }

    private data class PcmStats(val bytes: Long, val frames: Long, val sampleRate: Int,
        val channels: Int, val squareSum: Double, val monotonic: Boolean)

    /** No delegate and no AudioTrack: only PCM16 is supported, preventing AAC bypass. */
    private class CapturingPcmSink(private val firstPcm: () -> Unit) :
        androidx.media3.exoplayer.audio.AudioSink {
        private var format: Format? = null
        private var byteCount = 0L
        private var frames = 0L
        private var energy = 0.0
        private var lastPts = Long.MIN_VALUE
        private var monotonic = true
        private var position = androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET
        private var eos = false
        private var writtenUntilUs = androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET
        private var playing = false
        private var clockAnchorMs = 0L
        private var clockAnchorUs = 0L
        private var parameters = androidx.media3.common.PlaybackParameters.DEFAULT
        private var attributes = androidx.media3.common.AudioAttributes.DEFAULT
        private var skipSilence = false
        override fun setListener(listener: androidx.media3.exoplayer.audio.AudioSink.Listener) {}
        override fun supportsFormat(format: Format) =
            format.sampleMimeType == "audio/raw" && format.pcmEncoding == C.ENCODING_PCM_16BIT
        override fun getFormatSupport(format: Format) =
            if (supportsFormat(format)) androidx.media3.exoplayer.audio.AudioSink.SINK_FORMAT_SUPPORTED_DIRECTLY
            else androidx.media3.exoplayer.audio.AudioSink.SINK_FORMAT_UNSUPPORTED
        @Synchronized override fun configure(format: Format, size: Int, channels: IntArray?) {
            check(supportsFormat(format)) { "Unexpected decoded format: $format" }
            check(format.sampleRate > 0 && format.channelCount > 0)
            this.format?.let { check(it.sampleRate == format.sampleRate && it.channelCount == format.channelCount) }
            this.format = format
            eos = false
        }
        @Synchronized override fun handleBuffer(buffer: java.nio.ByteBuffer, pts: Long, units: Int): Boolean {
            val f = checkNotNull(format)
            val count = buffer.remaining()
            if (count == 0) return true
            check(count % (2 * f.channelCount) == 0) { "Unaligned PCM" }
            monotonic = monotonic && pts >= lastPts
            lastPts = pts
            val samples = buffer.duplicate().order(java.nio.ByteOrder.LITTLE_ENDIAN)
            var bufferEnergy = 0.0
            while (samples.remaining() >= 2) {
                val value = samples.short.toDouble()
                bufferEnergy += value * value
            }
            energy += bufferEnergy
            val bufferFrames = count / (2 * f.channelCount)
            byteCount += count
            frames += bufferFrames
            if (position == androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET) {
                position = pts
                writtenUntilUs = pts
                clockAnchorUs = pts
                clockAnchorMs = SystemClock.elapsedRealtime()
            }
            // Rebase before adding PCM so a previous underrun cannot consume new
            // data using wall-clock time accrued while the queue was empty.
            updatePosition()
            clockAnchorUs = position
            clockAnchorMs = SystemClock.elapsedRealtime()
            writtenUntilUs = pts + bufferFrames.toLong() * 1_000_000L / f.sampleRate
            buffer.position(buffer.limit())
            // Callback runs after consumption, on renderer thread, and records the barrier then.
            if (bufferEnergy > 0.0) firstPcm()
            return true
        }
        @Synchronized fun snapshot() = PcmStats(byteCount, frames,
            format?.sampleRate ?: 0, format?.channelCount ?: 0, energy, monotonic)
        // Model queued PCM and a real-time playback head without an audio device.
        // Media3 1.9.2 MediaCodecAudioRenderer.isReady() is exactly hasPendingData().
        // Returning false unconditionally prevents STATE_READY even after PCM decode.
        @Synchronized override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
            updatePosition()
            return position
        }
        private fun updatePosition() {
            if (!playing || position == androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET) return
            val elapsedUs = (SystemClock.elapsedRealtime() - clockAnchorMs) * 1000L
            position = minOf(writtenUntilUs, clockAnchorUs + elapsedUs)
            clockAnchorUs = position
            clockAnchorMs = SystemClock.elapsedRealtime()
        }
        @Synchronized override fun playToEndOfStream() { eos = true }
        @Synchronized override fun isEnded() = eos && !hasPendingData()
        @Synchronized override fun hasPendingData(): Boolean {
            updatePosition()
            return writtenUntilUs != androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET &&
                position < writtenUntilUs
        }
        @Synchronized override fun play() {
            if (playing) return
            clockAnchorUs = if (position == androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET) 0L else position
            clockAnchorMs = SystemClock.elapsedRealtime()
            playing = true
        }
        @Synchronized override fun pause() {
            updatePosition()
            playing = false
        }
        override fun handleDiscontinuity() {}
        override fun setPlaybackParameters(value: androidx.media3.common.PlaybackParameters) { parameters = value }
        override fun getPlaybackParameters() = parameters
        override fun setSkipSilenceEnabled(value: Boolean) { skipSilence = value }
        override fun getSkipSilenceEnabled() = skipSilence
        override fun setAudioAttributes(value: androidx.media3.common.AudioAttributes) { attributes = value }
        override fun getAudioAttributes() = attributes
        override fun setAudioSessionId(value: Int) {}
        override fun setAuxEffectInfo(value: androidx.media3.common.AuxEffectInfo) {}
        override fun getAudioTrackBufferSizeUs() = C.TIME_UNSET
        override fun enableTunnelingV21() { error("Tunneling is unsupported by test sink") }
        override fun disableTunneling() {}
        override fun setVolume(value: Float) {}
        @Synchronized override fun flush() {
            eos = false
            position = androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET
            writtenUntilUs = androidx.media3.exoplayer.audio.AudioSink.CURRENT_POSITION_NOT_SET
            clockAnchorUs = 0L
            clockAnchorMs = SystemClock.elapsedRealtime()
            playing = false
            // Keep aggregate evidence across lifecycle flushes; this test never seeks.
        }
        override fun reset() { flush() }
    }
}
