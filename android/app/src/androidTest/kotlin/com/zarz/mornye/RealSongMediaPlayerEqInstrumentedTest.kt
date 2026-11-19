package com.zarz.mornye

import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean

/** Original real MP3 or exact synthetic fragmented AAC + MediaPlayer + productive EQ.
 * No Flutter, Media3 retirement, MixedOutput or streaming-provider coverage.
 * Matrix expects both cases; native process death makes the matrix incomplete.
 * Source-only candidate; no claim of build/device success.
 */
@RunWith(AndroidJUnit4::class)
class RealSongMediaPlayerEqInstrumentedTest {
    private enum class Stage { OFF_BEGIN, ON_BEGIN, AAC_OFF_BEGIN, AAC_ON_BEGIN, PLAYER_CREATED, EQ_BEGIN, EQ_END,
        PREPARE_BEGIN, PREPARED, SEEK_COMPLETE, MUTED_PLAY_VERIFIED, PAUSED,
        EFFECT_CLOSE_BEGIN, EFFECT_CLOSE_END, PLAYER_RELEASE_BEGIN, PLAYER_RELEASE_END, CASE_COMPLETE }
    private fun stage(value: Stage) {
        runCatching {
        Log.i("MusaRealSongStage", value.name)
        InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply {
            putString("musa_real_song_stage", value.name)
        })
        }
    }
    @Test(timeout = 45000) fun originalMp3MediaPlayerWithoutEq() = runCase(false, false)
    @Test(timeout = 45000) fun originalMp3MediaPlayerWithProductiveEq() = runCase(true, false)

    @Test(timeout = 45000) fun syntheticAacMediaPlayerWithoutEq() = runCase(false, true)
    @Test(timeout = 45000) fun syntheticAacMediaPlayerWithProductiveEq() = runCase(true, true)

    private fun runCase(enabled: Boolean, aac: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("Refuse ordinary app", "org.musa.music.catalogintegration", context.packageName)
        assertEquals(android.app.Application::class.java, context.applicationContext.javaClass)
        val audio = context.getSystemService(AudioManager::class.java)
        // Caller must preflight this; do not change any user setting.
        assertEquals("Require media stream zero", 0, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        val assetName = if (aac) "synthetic_fragmented_aac_test.m4a" else "carefree_kevin_macleod_original.mp3"
        val expectedHash = if (aac) "6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58"
            else "8433b770a630d9b1594fd484442c677907ece899a4d149954cd2e74fd733e311"
        val bytes = instrumentation.context.assets.open(assetName).use { it.readBytes() }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals(expectedHash, digest)
        val root = File(context.cacheDir, "real-song-" + java.util.UUID.randomUUID())
        val file = File(root, if (aac) "synthetic.m4a" else "original.mp3")
        val thread = HandlerThread("musa-real-song")
        var handler: Handler? = null
        fun <T> onLoop(block: () -> T): T {
            val answer = AtomicReference<T>()
            val error = AtomicReference<Throwable>()
            val latch = CountDownLatch(1)
            val active = checkNotNull(handler)
            val cancelled = AtomicBoolean(false)
            val task = Runnable {
                if (cancelled.get()) { latch.countDown(); return@Runnable }
                try { answer.set(block()) } catch (t: Throwable) { error.set(t) } finally { latch.countDown() }
            }
            check(active.post(task))
            if (!latch.await(5, TimeUnit.SECONDS)) {
                cancelled.set(true)
                active.removeCallbacks(task)
                // A running native call cannot be cancelled; later join must prove exit.
                throw IllegalStateException("Playback task timeout; cleanup is not confirmed")
            }
            error.get()?.let { throw it }
            return answer.get()
        }
        var player: MediaPlayer? = null
        var effect: Any? = null
        var effectClass: Class<*>? = null
        val prepared = CountDownLatch(1)
        val seeked = CountDownLatch(1)
        val error = AtomicReference<String>()
        try {
            check(root.mkdir())
            thread.start()
            handler = Handler(thread.looper)
            stage(if (aac) { if (enabled) Stage.AAC_ON_BEGIN else Stage.AAC_OFF_BEGIN }
                else { if (enabled) Stage.ON_BEGIN else Stage.OFF_BEGIN })
            file.writeBytes(bytes) // Original bytes, no conversion or metadata rewriting.
            onLoop {
                val p = MediaPlayer()
                player = p
                p.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                p.setVolume(0f, 0f) // Defense in addition to system stream zero.
                p.setOnPreparedListener { prepared.countDown() }
                p.setOnSeekCompleteListener { seeked.countDown() }
                p.setOnErrorListener { _, _, _ -> error.set("MEDIA_PLAYER_ERROR"); prepared.countDown(); seeked.countDown(); true }
                p.setDataSource(file.path)
                stage(Stage.PLAYER_CREATED)
                if (enabled) {
                    stage(Stage.EQ_BEGIN)
                    // Same class and session-specific configuration as MediaPlayerWrapper.
                    // Reflection crosses Kotlin internal visibility only in instrumentation.
                    val type = Class.forName("xyz.luan.audioplayers.player.PlaybackEqualizer")
                    effectClass = type
                    effect = type.getDeclaredConstructor(Int::class.javaPrimitiveType).apply { isAccessible = true }.newInstance(p.audioSessionId)
                    val config = mapOf<String, Any?>("enabled" to true, "balance" to 0.25f,
                        "frequencies" to listOf(31f, 62f, 125f, 250f, 500f, 1000f, 2000f, 4000f, 8000f, 16000f),
                        "gains" to List(10) { 0f })
                    type.getDeclaredMethod("configure", Map::class.java).apply { isAccessible = true }.invoke(effect, config)
                    stage(Stage.EQ_END)
                }
                stage(Stage.PREPARE_BEGIN)
                p.prepareAsync()
            }
            assertTrue("No preparation", prepared.await(10, TimeUnit.SECONDS))
            assertNull(error.get())
            stage(Stage.PREPARED)
            onLoop { assertTrue(player!!.duration > (if (aac) 2000 else 10000)); player!!.seekTo(1000) }
            assertTrue("No seek completion", seeked.await(5, TimeUnit.SECONDS))
            assertNull(error.get())
            stage(Stage.SEEK_COMPLETE)
            onLoop { player!!.start() }
            SystemClock.sleep(500)
            onLoop { assertTrue(player!!.isPlaying); assertTrue(player!!.currentPosition >= 1100) }
            stage(Stage.MUTED_PLAY_VERIFIED)
            onLoop { player!!.pause(); assertFalse(player!!.isPlaying) }
            stage(Stage.PAUSED)
            assertNull(error.get())
        } finally {
            try {
                if (handler != null && thread.isAlive) onLoop {
                    try {
                        stage(Stage.EFFECT_CLOSE_BEGIN)
                        effect?.let { effectClass!!.getDeclaredMethod("close").apply { isAccessible = true }.invoke(it) }
                        stage(Stage.EFFECT_CLOSE_END)
                    } finally {
                        stage(Stage.PLAYER_RELEASE_BEGIN)
                        player?.release()
                        stage(Stage.PLAYER_RELEASE_END)
                    }
                }
            } finally {
                if (thread.isAlive) thread.quitSafely()
                thread.join(5000)
                assertFalse("Playback thread survived", thread.isAlive)
                check(root.canonicalFile.parentFile == context.cacheDir.canonicalFile)
                check(!root.exists() || root.deleteRecursively())
            }
        }
        stage(Stage.CASE_COMPLETE)
    }
}
