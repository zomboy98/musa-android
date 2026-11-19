package com.zarz.mornye

import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead
import xyz.luan.audioplayers.source.UrlSource
import java.io.File
import java.io.IOException
import java.lang.reflect.Proxy
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Source-only native cut. Real wrapper/MixedOutput/Media3/EQ; no engine, Dart,
 * SQLite, Rust producer or productive channel/controller coordination.
 * Per-instance debug capability only; product runtime gate is unchanged.
 */
@RunWith(AndroidJUnit4::class)
class NativeMedia3FinalWrapperInstrumentedTest {
    private enum class Stage { OFF_BEGIN, ON_BEGIN, MEDIA3_ATTACHED, MEDIA3_ADVANCED,
        PAUSED, BALANCE_TRIGGER, RETIRE_CALLBACK, RETIRE_CLOSE_END, EQ_APPLIED,
        FILE_HASH_VERIFIED, FINAL_SOURCE_BEGIN, FINAL_SOURCE_RETURNED, FINAL_PREPARED,
        FINAL_SEEK_COMPLETE, FINAL_PAUSE_VERIFIED, FINAL_ADVANCED, CLEANUP_BEGIN,
        CLEANUP_END, CASE_COMPLETE }
    private fun stage(value: Stage) { runCatching {
        Log.i("MusaNativeTransition", value.name)
        InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply {
            putString("musa_native_transition_stage", value.name)
        })
    } }
    private fun field(owner: Any, name: String) = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }
    @Test(timeout = 90000) fun balanceRetirementToFinalWrapperWithoutEq() = runCase(false)
    @Test(timeout = 90000) fun balanceRetirementToFinalWrapperWithEq() = runCase(true)

    private fun runCase(enabled: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("org.musa.music.catalogintegration", context.packageName)
        assertEquals(android.app.Application::class.java, context.applicationContext.javaClass)
        assertEquals(0, context.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_MUSIC))
        val bytes = instrumentation.context.assets.open("synthetic_fragmented_aac_test.m4a").use { it.readBytes() }
        fun hash(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }
        val expectedHash = "6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58"
        assertEquals(expectedHash, hash(bytes))
        val root = File(context.cacheDir, "native-transition-" + java.util.UUID.randomUUID())
        val finalFile = File(root, "exact.m4a")
        val thread = HandlerThread("musa-native-transition")
        var handler: Handler? = null
        var wrapped: WrappedPlayer? = null
        var events: EventHandler? = null
        var deck: AudioplayersPlugin.ExperimentalProgressiveDeck? = null
        val error = AtomicBoolean(false)
        val leaseClosed = AtomicBoolean(false)
        val retired = CountDownLatch(1)
        val reportedPosition = AtomicReference<Int?>()
        val retireCount = AtomicInteger()
        val seekComplete = CountDownLatch(1)
        fun <T> onLoop(block: () -> T): T {
            val active = checkNotNull(handler)
            val value = AtomicReference<T>()
            val failure = AtomicReference<Throwable>()
            val done = CountDownLatch(1)
            val cancelled = AtomicBoolean(false)
            val task = Runnable {
                if (cancelled.get()) { done.countDown(); return@Runnable }
                try { value.set(block()) } catch (t: Throwable) { failure.set(t) } finally { done.countDown() }
            }
            check(active.post(task))
            if (!done.await(5, TimeUnit.SECONDS)) {
                cancelled.set(true); active.removeCallbacks(task)
                throw IllegalStateException("Playback task timeout; cleanup unconfirmed")
            }
            failure.get()?.let { throw it }
            return value.get()
        }
        fun awaitState(label: String, condition: () -> Boolean) {
            val end = SystemClock.elapsedRealtime() + 10000
            while (SystemClock.elapsedRealtime() < end && !error.get()) {
                if (onLoop(condition)) return
                Thread.sleep(25)
            }
            fail(label)
        }
        try {
            check(root.mkdir())
            thread.start(); handler = Handler(thread.looper)
            stage(if (enabled) Stage.ON_BEGIN else Stage.OFF_BEGIN)
            onLoop {
                val plugin = AudioplayersPlugin(experimentalProgressiveForTesting = true,
                    allowUnreadyMedia3ForInstrumentation = true)
                field(plugin, "context").set(plugin, context)
                field(plugin, "playbackThread").set(plugin, thread)
                field(plugin, "playbackHandler").set(plugin, handler)
                val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader,
                    arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
                val eventHandler = EventHandler(EventChannel(messenger, "test/native-transition"))
                events = eventHandler
                eventHandler.onListen(null, object : EventChannel.EventSink {
                    override fun success(event: Any?) {
                        if ((event as? Map<*, *>)?.get("event") == "audio.onSeekComplete") seekComplete.countDown()
                    }
                    override fun error(code: String?, message: String?, details: Any?) { error.set(true) }
                    override fun endOfStream() {}
                })
                // Disable focus acquisition only in this native cut; both variants identical.
                val player = WrappedPlayer::class.java.constructors.single().newInstance(plugin,
                    eventHandler, AudioContextAndroid().copy(audioFocus = AudioManager.AUDIOFOCUS_NONE),
                    SoundPoolManager(plugin)) as WrappedPlayer
                wrapped = player
                player.volume = 0f
                @Suppress("UNCHECKED_CAST")
                (field(plugin, "players").get(plugin) as ConcurrentHashMap<String, WrappedPlayer>)["native-cut"] = player
                deck = checkNotNull(plugin.experimentalProgressiveDeck("native-cut", useMedia3 = true,
                    replaceExisting = false, experimentalRequest = true))
                deck!!.onRetireRequested = {
                    retireCount.incrementAndGet()
                    stage(Stage.RETIRE_CALLBACK)
                    deck!!.close { position ->
                        reportedPosition.set(position); stage(Stage.RETIRE_CLOSE_END); retired.countDown()
                    }
                }
            }
            val split = bytes.size - 1024
            val lease = object : TimedProgressiveLease {
                override fun knownSize(): Long? = null
                override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead {
                    if (leaseClosed.get()) throw IOException("Lease closed")
                    if (position >= split) { Thread.sleep(minOf(timeoutMs, 20).toLong()); return TimedProgressiveRead.Pending }
                    val end = minOf(split.toLong(), position + maxBytes).toInt()
                    return TimedProgressiveRead.Bytes(bytes.copyOfRange(position.toInt(), end))
                }
            }
            val attached = CountDownLatch(1)
            val accepted = AtomicBoolean(false)
            deck!!.attachTimed(lease, { leaseClosed.set(true) }) { ok -> accepted.set(ok); attached.countDown() }
            assertTrue(attached.await(5, TimeUnit.SECONDS)); assertTrue(accepted.get())
            stage(Stage.MEDIA3_ATTACHED)
            awaitState("Media3 not prepared") { wrapped!!.prepared }
            onLoop { wrapped!!.play() }
            awaitState("Media3 did not advance") { wrapped!!.playing && (wrapped!!.getCurrentPosition() ?: 0) >= 600 }
            stage(Stage.MEDIA3_ADVANCED)
            onLoop { wrapped!!.pause() }
            val position = onLoop { checkNotNull(wrapped!!.getCurrentPosition()) }
            assertTrue(position >= 500)
            Thread.sleep(200)
            onLoop { assertFalse(wrapped!!.playing); assertTrue(kotlin.math.abs(checkNotNull(wrapped!!.getCurrentPosition()) - position) <= 100) }
            stage(Stage.PAUSED)
            stage(Stage.BALANCE_TRIGGER)
            onLoop { wrapped!!.balance = 0.25f }
            assertTrue("No retirement close", retired.await(5, TimeUnit.SECONDS))
            assertEquals(1, retireCount.get()); assertTrue(leaseClosed.get())
            onLoop { assertNull(wrapped!!.source); assertNull(field(wrapped!!, "player").get(wrapped)); assertFalse(wrapped!!.playing) }
            val preserved = checkNotNull(reportedPosition.get())
            assertTrue(kotlin.math.abs(preserved - position) <= 250)
            onLoop { wrapped!!.setEqualizer(mapOf("enabled" to enabled, "balance" to 0.25f,
                "frequencies" to listOf(31f,62f,125f,250f,500f,1000f,2000f,4000f,8000f,16000f),
                "gains" to List(10) { 0f })) }
            stage(Stage.EQ_APPLIED)
            finalFile.writeBytes(bytes); assertEquals(expectedHash, hash(finalFile.readBytes()))
            stage(Stage.FILE_HASH_VERIFIED)
            stage(Stage.FINAL_SOURCE_BEGIN)
            onLoop { wrapped!!.source = UrlSource(finalFile.path, true) }
            stage(Stage.FINAL_SOURCE_RETURNED)
            awaitState("Final wrapper not prepared") { wrapped!!.prepared }
            onLoop {
                assertEquals("MediaPlayerWrapper", field(wrapped!!, "player").get(wrapped)?.javaClass?.simpleName)
                assertFalse(wrapped!!.playing)
                assertEquals(enabled, field(wrapped!!, "equalizerEnabled").get(wrapped))
            }
            stage(Stage.FINAL_PREPARED)
            onLoop { wrapped!!.seek(preserved) }
            assertTrue("No final native seek callback", seekComplete.await(5, TimeUnit.SECONDS))
            assertFalse(error.get())
            stage(Stage.FINAL_SEEK_COMPLETE)
            val before = onLoop { checkNotNull(wrapped!!.getCurrentPosition()) }
            assertTrue(kotlin.math.abs(before - preserved) <= 250)
            Thread.sleep(300)
            onLoop { assertFalse(wrapped!!.playing); assertTrue(kotlin.math.abs(checkNotNull(wrapped!!.getCurrentPosition()) - before) <= 100) }
            stage(Stage.FINAL_PAUSE_VERIFIED)
            onLoop { wrapped!!.play() }
            awaitState("Final playback did not advance") { wrapped!!.playing && checkNotNull(wrapped!!.getCurrentPosition()) >= before + 300 }
            onLoop { wrapped!!.pause() }
            stage(Stage.FINAL_ADVANCED)
            assertFalse(error.get())
        } finally {
            stage(Stage.CLEANUP_BEGIN)
            try {
                if (handler != null && thread.isAlive) {
                    val closed = CountDownLatch(1)
                    deck?.close { closed.countDown() } ?: closed.countDown()
                    check(closed.await(5, TimeUnit.SECONDS)) { "Deck cleanup unconfirmed" }
                    onLoop { try { wrapped?.release() } finally { events?.dispose() } }
                }
            } finally {
                if (thread.isAlive) thread.quitSafely()
                thread.join(5000)
                assertFalse("Playback thread survived", thread.isAlive)
                check(root.canonicalFile.parentFile == context.cacheDir.canonicalFile)
                check(!root.exists() || root.deleteRecursively())
            }
            stage(Stage.CLEANUP_END)
        }
        stage(Stage.CASE_COMPLETE)
    }
}
