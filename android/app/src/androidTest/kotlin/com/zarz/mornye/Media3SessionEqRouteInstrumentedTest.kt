package com.zarz.mornye

import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
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
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead

/** Isolated native test proposal. Never starts a Flutter engine or opens a network socket. */
@RunWith(AndroidJUnit4::class)
class Media3SessionEqRouteInstrumentedTest {
    private fun field(owner: Any, name: String) = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }
    private val enabled = mapOf<String, Any?>("enabled" to true, "frequencies" to listOf(31f, 62f, 125f, 250f, 500f, 1000f, 2000f, 4000f, 8000f, 16000f), "gains" to List(10) { 0f })
    private val disabled = mapOf<String, Any?>("enabled" to false)

    @Test(timeout = 60000) fun defaultRouteStillRetiresOnEqualizerEnable() = runCase("default")
    @Test(timeout = 60000) fun optedInRouteKeepsSameEngineAcrossOffOnAndReleases() = runCase("enabled")
    @Test(timeout = 60000) fun optedInConfigurationFailureRetiresInsteadOfClaimingApplied() = runCase("failure")
    @Test(timeout = 60000) fun optedInMissingSessionRetiresInsteadOfClaimingApplied() = runCase("no_session")
    @Test(timeout = 60000) fun removedOptInDoesNotCarryToReplacementDeck() = runCase("owner-default")
    @Test(timeout = 60000) fun oldDeckLateCloseDoesNotRevokeReplacementOptIn() = runCase("owner-new")

    private fun runCase(mode: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("org.musa.music.catalogintegration", context.packageName)
        assertTrue(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        assumeTrue(android.os.Build.VERSION.SDK_INT >= 28)
        assertEquals(0, context.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_MUSIC))
        val bytes = instrumentation.context.assets.open("synthetic_fragmented_aac_test.m4a").use { it.readBytes() }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals("6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58", digest)
        val thread = HandlerThread("musa-session-eq-test")
        var handler: Handler? = null
        var deck: AudioplayersPlugin.ExperimentalProgressiveDeck? = null
        var player: WrappedPlayer? = null
        var events: EventHandler? = null
        var lastEqualizer: Any? = null
        val failed = AtomicBoolean(false); val retired = CountDownLatch(1); val revocations = AtomicInteger()
        val attached = AtomicBoolean(false); val retirementConfirmed = AtomicBoolean(false)
        val oldCloseDone = CountDownLatch(1); val oldCloseConfirmed = AtomicBoolean(false)
        fun <T> onLoop(action: () -> T): T {
            val value = AtomicReference<T>(); val error = AtomicReference<Throwable>(); val done = CountDownLatch(1)
            val active = checkNotNull(handler) { "Playback handler unavailable; cleanup unconfirmed" }
            val taskState = AtomicInteger(0) // pending, started, cancelled
            val task = Runnable {
                if (!taskState.compareAndSet(0, 1)) { done.countDown(); return@Runnable }
                try { value.set(action()) } catch (t: Throwable) { error.set(t) } finally { done.countDown() }
            }
            check(active.post(task))
            if (!done.await(5, TimeUnit.SECONDS)) {
                val cancelled = taskState.compareAndSet(0, 2)
                if (cancelled) active.removeCallbacks(task)
                throw IllegalStateException(if (cancelled) "Playback task timed out and was cancelled before start" else "Playback task timed out after start; cleanup unconfirmed")
            }
            error.get()?.let { throw it }; return value.get()
        }
        var primaryFailure: Throwable? = null
        try {
            thread.start(); handler = Handler(thread.looper)
            onLoop {
                val plugin = AudioplayersPlugin(experimentalProgressiveForTesting = true, allowUnreadyMedia3ForInstrumentation = true)
                field(plugin, "context").set(plugin, context); field(plugin, "playbackThread").set(plugin, thread); field(plugin, "playbackHandler").set(plugin, handler)
                val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
                val eventHandler = EventHandler(EventChannel(messenger, "test/media3-session-eq")); events = eventHandler
                eventHandler.onListen(null, object : EventChannel.EventSink {
                    override fun success(event: Any?) {}
                    override fun error(code: String?, message: String?, details: Any?) { failed.set(true) }
                    override fun endOfStream() {}
                })
                val wrapped = WrappedPlayer::class.java.constructors.single().newInstance(plugin, eventHandler,
                    AudioContextAndroid().copy(audioFocus = AudioManager.AUDIOFOCUS_NONE), SoundPoolManager(plugin)) as WrappedPlayer
                player = wrapped; wrapped.volume = 0f
                @Suppress("UNCHECKED_CAST")
                (field(plugin, "players").get(plugin) as ConcurrentHashMap<String, WrappedPlayer>)["eq-session"] = wrapped
                deck = checkNotNull(plugin.experimentalProgressiveDeck("eq-session", useMedia3 = true, replaceExisting = false, experimentalRequest = true))
                if (mode != "default") {
                    // Proposed native-only opt-in: absent today, so this test is intentionally red.
                    // Implementation must reject non-debuggable apps and require the constructor guard.
                    deck!!.javaClass.getMethod("enableSessionEqForInstrumentation").invoke(deck)
                }
                if (mode.startsWith("owner-")) {
                    @Suppress("UNCHECKED_CAST")
                    val registry = field(plugin, "experimentalDecks").get(plugin) as ConcurrentHashMap<String, AudioplayersPlugin.ExperimentalProgressiveDeck>
                    val old = checkNotNull(registry.remove("eq-session"))
                    // Called on the playback looper: close dispatch remains queued while B is registered.
                    old.closeWithStatus { _, confirmed -> oldCloseConfirmed.set(confirmed); oldCloseDone.countDown() }
                    deck = checkNotNull(plugin.experimentalProgressiveDeck("eq-session", useMedia3 = true, replaceExisting = false, experimentalRequest = true))
                    if (mode == "owner-new") deck!!.javaClass.getMethod("enableSessionEqForInstrumentation").invoke(deck)
                }
                deck!!.onRetireRequested = { deck!!.closeWithStatus { _, confirmed -> retirementConfirmed.set(confirmed); retired.countDown() } }
            }
            if (mode.startsWith("owner-")) {
                assertTrue("old close did not finish", oldCloseDone.await(5, TimeUnit.SECONDS))
                assertTrue("old close was not confirmed", oldCloseConfirmed.get())
            }
            val lease = object : TimedProgressiveLease {
                override fun knownSize(): Long? = bytes.size.toLong()
                override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead {
                    if (position >= bytes.size) return TimedProgressiveRead.End
                    return TimedProgressiveRead.Bytes(bytes.copyOfRange(position.toInt(), minOf(bytes.size, position.toInt() + maxBytes)))
                }
            }
            val attachDone = CountDownLatch(1)
            deck!!.attachTimed(lease, { revocations.incrementAndGet() }) { attached.set(it); attachDone.countDown() }
            assertTrue(attachDone.await(5, TimeUnit.SECONDS)); assertTrue(attached.get())
            val deadline = SystemClock.elapsedRealtime() + 10000
            while (SystemClock.elapsedRealtime() < deadline && !onLoop { player!!.prepared } && !failed.get()) Thread.sleep(25)
            assertTrue("Media3 did not prepare", onLoop { player!!.prepared }); assertFalse(failed.get())
            val output = onLoop { checkNotNull(field(player!!, "player").get(player)) }
            assertEquals("Media3ProgressivePlayer", output.javaClass.simpleName)
            if (mode == "default" || mode == "owner-default") {
                onLoop { player!!.setEqualizer(enabled) }
                assertTrue("default route must retire", retired.await(5, TimeUnit.SECONDS))
                assertTrue("default retirement must confirm close", retirementConfirmed.get())
            } else {
                // Start muted to obtain a real audio session; no claim about audible output.
                onLoop { player!!.play() }
                val effects = field(output, "effects").get(output)
                while (SystemClock.elapsedRealtime() < deadline && onLoop { field(effects, "session").getInt(effects) <= 0 }) Thread.sleep(25)
                assertTrue("No valid Media3 audio session", onLoop { field(effects, "session").getInt(effects) > 0 })
                if (mode == "no_session") {
                    onLoop { effects.javaClass.getMethod("onSession", Int::class.javaPrimitiveType, Long::class.javaPrimitiveType).invoke(effects, 0, 1L) }
                    onLoop { player!!.setEqualizer(enabled) }
                    assertTrue("missing session must retire", retired.await(5, TimeUnit.SECONDS))
                    assertTrue("retirement must confirm close", retirementConfirmed.get())
                } else if (mode == "failure") {
                    onLoop { player!!.setEqualizer(enabled + ("gains" to listOf(0f))) }
                    assertTrue("failed effect must retire", retired.await(5, TimeUnit.SECONDS))
                    assertTrue("retirement must confirm close", retirementConfirmed.get())
                } else {
                    onLoop { player!!.setEqualizer(enabled) }
                    val first = onLoop { checkNotNull(field(effects, "effect").get(effects)) }
                    val firstEqualizer = first.javaClass.declaredFields.single { it.type.simpleName == "PlaybackEqualizer" }.apply { isAccessible = true }.get(first)
                    assertNotNull(onLoop { field(firstEqualizer, "effect").get(firstEqualizer) })
                    onLoop { player!!.setEqualizer(disabled) }
                    assertNull(onLoop { field(effects, "effect").get(effects) })
                    assertNull(onLoop { field(firstEqualizer, "effect").get(firstEqualizer) })
                    onLoop { player!!.setEqualizer(enabled) }
                    val second = onLoop { checkNotNull(field(effects, "effect").get(effects)) }
                    lastEqualizer = second.javaClass.declaredFields.single { it.type.simpleName == "PlaybackEqualizer" }.apply { isAccessible = true }.get(second)
                    assertNotSame(first, second)
                    assertSame(output, onLoop { field(player!!, "player").get(player) })
                    assertEquals(1L, retired.count)
                }
            }
        } catch (error: Throwable) {
            primaryFailure = error
            throw error
        } finally {
            val cleanupFailures = mutableListOf<Throwable>()
            fun clean(action: () -> Unit) { runCatching(action).exceptionOrNull()?.let(cleanupFailures::add) }
            if (thread.isAlive && handler != null) {
                clean {
                    val closed = CountDownLatch(1); val closeConfirmed = AtomicBoolean(false)
                    deck?.closeWithStatus { _, confirmed -> closeConfirmed.set(confirmed); closed.countDown() } ?: run { closeConfirmed.set(true); closed.countDown() }
                    check(closed.await(5, TimeUnit.SECONDS) && closeConfirmed.get()) { "Deck close unconfirmed" }
                }
                clean { lastEqualizer?.let { eq -> assertNull(onLoop { field(eq, "effect").get(eq) }) } }
                clean { onLoop { player?.release() } }
                clean { onLoop { events?.dispose() } }
                clean { if (attached.get()) assertEquals("attached lease must be revoked exactly once", 1, revocations.get()) }
            } else if (deck != null || player != null || events != null) {
                cleanupFailures.add(IllegalStateException("Playback thread unavailable; cleanup unconfirmed"))
            }
            clean { if (thread.isAlive) thread.quitSafely() }
            clean { thread.join(5000); check(!thread.isAlive) { "Playback thread survived; cleanup unconfirmed" } }
            val original = primaryFailure
            if (original != null) cleanupFailures.forEach(original::addSuppressed)
            else if (cleanupFailures.isNotEmpty()) {
                val first = cleanupFailures.first()
                cleanupFailures.drop(1).forEach(first::addSuppressed)
                throw first
            }
        }
    }
}
