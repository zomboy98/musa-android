package com.zarz.mornye

import android.content.Context
import android.content.ContextWrapper
import android.media.AudioManager
import android.os.Handler
import android.os.Bundle
import android.util.Log
import android.os.HandlerThread
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import kotlinx.coroutines.cancel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead
import xyz.luan.audioplayers.source.UrlSource
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

private enum class HarnessStage {
    TEST_ENTERED,
    PACKAGE_VERIFIED,
    APPLICATION_VERIFIED,
    EMPTY_DATA_VERIFIED,
    FIXTURE_VERIFIED,
    ROOT_CREATED,
    VOLUME_ZERO_VERIFIED,
    MAIN_SETUP_ENTERED,
    CONTEXT_CONSTRUCT_BEGIN,
    CONTEXT_CONSTRUCT_END,
    CONTEXT_ATTACH_BEGIN,
    CONTEXT_ATTACH_END,
    ENGINE_CONSTRUCT_BEGIN,
    ENGINE_CONSTRUCT_END,
    PLAYER_PLUGIN_BEGIN,
    PLAYER_PLUGIN_END,
    AUDIO_SESSION_PLUGIN_BEGIN,
    AUDIO_SESSION_PLUGIN_END,
    FFMPEG_PLUGIN_BEGIN,
    FFMPEG_PLUGIN_END,
    PREFS_PLUGIN_BEGIN,
    PREFS_PLUGIN_END,
    SQLITE_PLUGIN_BEGIN,
    SQLITE_PLUGIN_END,
    JNI_PLUGIN_BEGIN,
    JNI_PLUGIN_END,
    BACKEND_GUARD_READY,
    PROGRESSIVE_CHANNEL_BEGIN,
    PROGRESSIVE_CHANNEL_END,
    CONTROL_CHANNEL_READY,
    DART_EXECUTE_BEGIN,
    DART_EXECUTE_RETURNED,
    DART_FIXTURE_REQUESTED,
    SESSION_FACTORY_ENTERED,
    SESSION_FACTORY_READY,
    PRODUCER_ENTERED,
    PRODUCER_RELEASED,
    PRODUCER_COMMITTED,
    RESULT_CALLBACK_BEGIN,
    RESULT_CALLBACK_END,
    LEASE_CLOSE_BEGIN,
    LEASE_CLOSE_END,
    SESSION_CLOSE_BEGIN,
    SESSION_CLOSE_END,
    FINAL_PREPARED_OBSERVED,
    FINAL_EQ_ENABLED_OBSERVED,
    DART_RELEASE_REQUESTED,
    DART_VERDICT_RECEIVED,
    DART_ACK_RECEIVED,
    WAIT_FINISHED_RETURNED,
    ASSERTIONS_PASSED,
    TEARDOWN_ENTERED,
    ENGINE_DESTROY_BEGIN,
    ENGINE_DESTROY_END,
    VOLUME_RESTORE_BEGIN,
    VOLUME_RESTORE_END,
    ROOT_DELETE_BEGIN,
    ROOT_DELETE_END
}

/** Closed identifiers only: never log arguments, paths, exceptions or user state. */
private fun markHarnessStage(value: HarnessStage) {
    Log.i("MusaHarnessStage", value.name)
    // Independent status channel preserves the last checkpoint if logcat is lost.
    // Diagnostic transport failure must not change the test's behavior.
    runCatching {
        InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply {
            putString("musa_harness_stage", value.name)
        })
    }
}

/**
 * Paired with the headless Dart scenario in integration_test/android_progressive_final_file_test.dart.
 * Build that Dart target with both experimental defines and a fresh isolated app ID.
 * Owns its FlutterEngine; never starts MainActivity lifecycle or touches cached engines.
 * Diagnostic revision is source-only; preceding candidate crashed without a cause.
 * Synthetic producer only; offline APK permission/UID gates remain required.
 * Productive MethodChannels and the player are never mocked. Reflection observes
 * private player state; it never constructs a deck or sends retirement events.
 */
@RunWith(AndroidJUnit4::class)
class ProgressiveFlutterFinalFileInstrumentedTest {
    private fun field(owner: Any, name: String): Any? =
        owner.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(owner)

    @Test(timeout = 120000)
    fun dartHandlerRetiresMedia3AndLoadsFinalFilePreservingPauseAndPosition() = runTransition(null)

    @Test(timeout = 120000)
    fun balanceRetirementThenFinalFileWithoutEq() = runTransition(false)

    @Test(timeout = 120000)
    fun balanceRetirementThenFinalFileWithEq() = runTransition(true)

    private fun runTransition(balanceRetirementEqEnabled: Boolean?) {
        markHarnessStage(HarnessStage.TEST_ENTERED)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("Refuse ordinary debug app", "org.musa.music.catalogintegration", context.packageName)
        markHarnessStage(HarnessStage.PACKAGE_VERIFIED)
        check(context.applicationContext.javaClass == android.app.Application::class.java) {
            "Offline test overlay must use base android.app.Application"
        }
        markHarnessStage(HarnessStage.APPLICATION_VERIFIED)
        TestOwnCrashCorrelation.bindIfRequested(context)
        // Refuse any prefs/data, including unknown framework-created files.
        // Metadata only on failure; never read preference contents.
        for (directory in listOf(context.filesDir, File(context.dataDir, "databases"),
                File(context.dataDir, "shared_prefs"))) {
            val entries = if (!directory.exists()) emptyArray() else {
                check(directory.isDirectory) { "Expected directory: $directory" }
                checkNotNull(directory.listFiles()) { "Cannot enumerate isolated test directory: $directory" }
            }
            check(entries.isEmpty()) {
                val metadata = entries.sortedBy { it.name }.joinToString {
                    val type = if (it.isDirectory) "directory" else if (it.isFile) "file" else "other"
                    "${it.name}:$type"
                }
                "Require fresh isolated app data: $directory; count=${entries.size}; entries=$metadata"
            }
        }
        markHarnessStage(HarnessStage.EMPTY_DATA_VERIFIED)
        val bytes = instrumentation.context.assets.open("synthetic_fragmented_aac_test.m4a").use { it.readBytes() }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals("6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58", digest)
        markHarnessStage(HarnessStage.FIXTURE_VERIFIED)
        val root = File(context.cacheDir, "flutter-progressive-" + java.util.UUID.randomUUID()).apply { check(mkdir()) }
        val finalFile = File(root, "synthetic-final.m4a")
        markHarnessStage(HarnessStage.ROOT_CREATED)
        val fixture = Fixture(bytes, finalFile)
        val finished = CountDownLatch(1)
        val dartSuccess = AtomicBoolean(false)
        val verdictReceived = AtomicBoolean(false)
        val dartError = AtomicReference<String>()
        val main = Handler(Looper.getMainLooper())
        val manager = context.getSystemService(AudioManager::class.java)
        val oldVolume = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
        var channelContext: MainActivity? = null
        var engine: FlutterEngine? = null
        var bridge: ExperimentalProgressiveChannel? = null
        var support: MethodChannel? = null
        var backendGuard: MethodChannel? = null
        val preparedObserved = AtomicBoolean(false)
        val equalizerObserved = AtomicBoolean(false)
        val unexpectedBackendCalls = java.util.concurrent.atomic.AtomicInteger()
        var plugin: AudioplayersPlugin? = null
        var playbackThread: HandlerThread? = null
        try {
            // Actual renderers and final MediaPlayer run, with the system stream muted.
            // Teardown restores it only after disposing the harness player.
            manager.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
            assertEquals(0, manager.getStreamVolume(AudioManager.STREAM_MUSIC))
            markHarnessStage(HarnessStage.VOLUME_ZERO_VERIFIED)
            instrumentation.runOnMainSync {
                markHarnessStage(HarnessStage.MAIN_SETUP_ENTERED)
                // Existing channel signature takes MainActivity but uses only its
                // applicationInfo. Attach Context only; never run Activity lifecycle.
                markHarnessStage(HarnessStage.CONTEXT_CONSTRUCT_BEGIN)
                val host = MainActivity()
                markHarnessStage(HarnessStage.CONTEXT_CONSTRUCT_END)
                markHarnessStage(HarnessStage.CONTEXT_ATTACH_BEGIN)
                ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java)
                    .apply { isAccessible = true }.invoke(host, context)
                    markHarnessStage(HarnessStage.CONTEXT_ATTACH_END)
                channelContext = host
                markHarnessStage(HarnessStage.ENGINE_CONSTRUCT_BEGIN)
                val e = FlutterEngine(context, null, false)
                markHarnessStage(HarnessStage.ENGINE_CONSTRUCT_END)
                engine = e
                check(!e.dartExecutor.isExecutingDart) { "Engine unexpectedly ran application code" }
                val p = AudioplayersPlugin(allowUnreadyMedia3ForInstrumentation = true)
                plugin = p
                markHarnessStage(HarnessStage.PLAYER_PLUGIN_BEGIN)
                e.plugins.add(p)
                markHarnessStage(HarnessStage.PLAYER_PLUGIN_END)
                // Explicit local-only plugins. No AudioService engine, Cast,
                // discovery, application backend or generated plugin registrant.
                // jni/jni_flutter are registered because shared_preferences_android
                // and path_provider_android need them (JniPlugin initialises the JVM
                // handle used by libdartjni; JniFlutterPlugin keeps the app context).
                markHarnessStage(HarnessStage.AUDIO_SESSION_PLUGIN_BEGIN)
                e.plugins.add(com.ryanheise.audio_session.AudioSessionPlugin())
                markHarnessStage(HarnessStage.AUDIO_SESSION_PLUGIN_END)
                markHarnessStage(HarnessStage.FFMPEG_PLUGIN_BEGIN)
                e.plugins.add(com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin())
                markHarnessStage(HarnessStage.FFMPEG_PLUGIN_END)
                markHarnessStage(HarnessStage.PREFS_PLUGIN_BEGIN)
                e.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
                markHarnessStage(HarnessStage.PREFS_PLUGIN_END)
                markHarnessStage(HarnessStage.SQLITE_PLUGIN_BEGIN)
                e.plugins.add(com.tekartik.sqflite.SqflitePlugin())
                markHarnessStage(HarnessStage.SQLITE_PLUGIN_END)
                markHarnessStage(HarnessStage.JNI_PLUGIN_BEGIN)
                e.plugins.add(com.github.dart_lang.jni.JniPlugin())
                e.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
                markHarnessStage(HarnessStage.JNI_PLUGIN_END)
                // Fail rather than perform a real Rust fallback/profile operation.
                // This guard never returns fake success; audio/progressive channels stay real.
                backendGuard = MethodChannel(e.dartExecutor.binaryMessenger, "com.zarz.mornye/backend").apply {
                    setMethodCallHandler { call, reply ->
                        unexpectedBackendCalls.incrementAndGet()
                        reply.error("unexpected_backend_call", "Offline fixture forbids " + call.method, null)
                    }
                }
                markHarnessStage(HarnessStage.BACKEND_GUARD_READY)
                markHarnessStage(HarnessStage.PROGRESSIVE_CHANNEL_BEGIN)
                bridge = ExperimentalProgressiveChannel(host, e, ProgressiveChannelInstrumentation { request, result ->
                markHarnessStage(HarnessStage.SESSION_FACTORY_ENTERED)
                    val payload = JSONObject(request)
                    check(payload.optBoolean("temporary_playback") && payload.optString("storage_mode") == "app")
                    check(payload.optString("track_name") == "Synthetic progressive fixture")
                    check(fixture.starts.incrementAndGet() == 1) { "Unexpected second transfer" }
                    fixture.result = result
                    markHarnessStage(HarnessStage.SESSION_FACTORY_READY)
                    fixture
                })
                markHarnessStage(HarnessStage.PROGRESSIVE_CHANNEL_END)
                support = MethodChannel(e.dartExecutor.binaryMessenger, "musa.test/progressive_final_file").apply {
                    setMethodCallHandler { call, reply ->
                        when (call.method) {
                            "fixture" -> {
                                markHarnessStage(HarnessStage.DART_FIXTURE_REQUESTED)
                                reply.success(mapOf(
                                "package" to context.packageName, "root" to root.path,
                                "finalPath" to finalFile.path, "sha256" to digest,
                                "balanceRetirementEqEnabled" to balanceRetirementEqEnabled))
                            }
                            "snapshot" -> {
                                @Suppress("UNCHECKED_CAST")
                                val players = field(p, "players") as Map<String, WrappedPlayer>
                                val player = players["music-player"]
                                if (player == null) reply.success(fixture.stats())
                                else player.onPlaybackThread {
                                    try {
                                        val output = field(player, "player")
                                        val snapshot = fixture.stats().toMutableMap().apply {
                                            put("engine", output?.javaClass?.simpleName)
                                            put("prepared", player.prepared)
                                            put("playing", player.playing)
                                            put("positionMs", player.getCurrentPosition())
                                            put("sourceKind", player.source?.javaClass?.simpleName)
                                            put("sourcePath", (player.source as? UrlSource)?.url)
                                            put("equalizerEnabled", field(player, "equalizerEnabled"))
                                            put("balance", player.balance)
                                        }
                                        if (output?.javaClass?.simpleName == "MediaPlayerWrapper" && player.prepared && preparedObserved.compareAndSet(false, true))
                                            markHarnessStage(HarnessStage.FINAL_PREPARED_OBSERVED)
                                        if (output?.javaClass?.simpleName == "MediaPlayerWrapper" && field(player, "equalizerEnabled") == true && equalizerObserved.compareAndSet(false, true))
                                            markHarnessStage(HarnessStage.FINAL_EQ_ENABLED_OBSERVED)
                                        main.post { reply.success(snapshot) }
                                    } catch (t: Exception) { main.post { reply.error("snapshot", t.message, null) } }
                                }
                            }
                            "release" -> { markHarnessStage(HarnessStage.DART_RELEASE_REQUESTED); fixture.release(); reply.success(true) }
                            "finish" -> {
                                markHarnessStage(HarnessStage.DART_VERDICT_RECEIVED)
                                dartSuccess.set(call.argument<Boolean>("success") == true)
                                dartError.set(call.argument<String>("error")?.take(4000))
                                verdictReceived.set(true)
                                reply.success(true)
                            }
                            "acknowledgeFinish" -> {
                                // Dart sends this only after receiving finish's reply.
                                // No scenario/cleanup work follows this acknowledgement.
                                if (!verdictReceived.get()) reply.error("finish_order", "No verdict received", null)
                                else {
                                    reply.success(true)
                                    markHarnessStage(HarnessStage.DART_ACK_RECEIVED)
                                    finished.countDown()
                                }
                            }
                            else -> reply.notImplemented()
                        }
                    }
                }
                markHarnessStage(HarnessStage.CONTROL_CHANNEL_READY)
                // Start only after all real channels, fixtures and refusal guards
                // are installed. The APK must contain the paired Dart target.
                markHarnessStage(HarnessStage.DART_EXECUTE_BEGIN)
                e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
                markHarnessStage(HarnessStage.DART_EXECUTE_RETURNED)
            }
            assertTrue("Dart target did not finish; build the paired target and both defines",
                finished.await(90, TimeUnit.SECONDS))
                markHarnessStage(HarnessStage.WAIT_FINISHED_RETURNED)
            assertTrue("Dart integration failed: ${dartError.get()}", dartSuccess.get())
            assertEquals(1, fixture.starts.get())
            assertEquals("Harness unexpectedly used the real backend channel", 0, unexpectedBackendCalls.get())
            assertTrue("Final producer never completed", fixture.committed.get())
            assertEquals(bytes.toList(), finalFile.readBytes().toList())
            markHarnessStage(HarnessStage.ASSERTIONS_PASSED)
        } finally {
            markHarnessStage(HarnessStage.TEARDOWN_ENTERED)
            fixture.close()
            try {
                instrumentation.runOnMainSync {
                    support?.setMethodCallHandler(null)
                    bridge?.close()
                    plugin?.let { playbackThread = field(it, "playbackThread") as? HandlerThread }
                    backendGuard?.setMethodCallHandler(null)
                    markHarnessStage(HarnessStage.ENGINE_DESTROY_BEGIN)
                    engine?.destroy()
                    markHarnessStage(HarnessStage.ENGINE_DESTROY_END)
                    channelContext?.scope?.cancel()
                }
                playbackThread?.join(5000)
                assertFalse("Harness playback thread survived disposal", playbackThread?.isAlive == true)
            } finally {
                // Always restore volume, even when teardown reports another failure.
                markHarnessStage(HarnessStage.VOLUME_RESTORE_BEGIN)
                manager.setStreamVolume(AudioManager.STREAM_MUSIC, oldVolume, 0)
                markHarnessStage(HarnessStage.VOLUME_RESTORE_END)
                assertEquals(context.cacheDir.canonicalFile, root.canonicalFile.parentFile)
                check(root.name.startsWith("flutter-progressive-"))
                markHarnessStage(HarnessStage.ROOT_DELETE_BEGIN)
                assertTrue("Could not remove own fixture directory", root.deleteRecursively())
                markHarnessStage(HarnessStage.ROOT_DELETE_END)
            }
        }
    }

    private class Fixture(private val bytes: ByteArray, private val finalFile: File) : ProgressiveControllerSession {
        val starts = java.util.concurrent.atomic.AtomicInteger()
        val committed = AtomicBoolean(false)
        private val cancelled = AtomicBoolean(false)
        private val leaseClosed = AtomicBoolean(false)
        private val released = AtomicBoolean(false)
        private val producerRelease = CountDownLatch(1)
        private val readWake = CountDownLatch(1)
        private val highWater = AtomicLong()
        private val split = bytes.size - 1024
        @Volatile var result: ((String) -> Unit)? = null
        private val lease = object : ProgressiveAudioLease, TimedProgressiveLease {
            override fun knownSize(): Long? = if (released.get()) bytes.size.toLong() else null
            override fun size(): Long? = knownSize()
            override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead {
                if (leaseClosed.get()) throw IOException("Fixture lease revoked")
                if (position >= split && !released.get()) readWake.await(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                if (leaseClosed.get()) throw IOException("Fixture lease revoked")
                val available = if (released.get()) bytes.size else split
                if (position >= available) return if (released.get()) TimedProgressiveRead.End else TimedProgressiveRead.Pending
                val end = minOf(available.toLong(), position + maxBytes).toInt()
                highWater.accumulateAndGet(end.toLong()) { a, b -> maxOf(a, b) }
                return TimedProgressiveRead.Bytes(bytes.copyOfRange(position.toInt(), end))
            }
            override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead =
                when (val value = readChunk(position, maxBytes, timeoutMs)) {
                    is TimedProgressiveRead.Bytes -> ProgressiveRead.Data(value.value)
                    TimedProgressiveRead.Pending -> ProgressiveRead.Pending
                    TimedProgressiveRead.End -> ProgressiveRead.End
                }
            override fun close() {
                markHarnessStage(HarnessStage.LEASE_CLOSE_BEGIN)
                leaseClosed.set(true)
                readWake.countDown()
                markHarnessStage(HarnessStage.LEASE_CLOSE_END)
            }
        }
        fun stats(): Map<String, Any?> = mapOf(
            "starts" to starts.get(), "committed" to committed.get(),
            "released" to released.get(), "leaseClosed" to leaseClosed.get(),
            "sessionClosed" to cancelled.get(), "highWater" to highWater.get(),
            "split" to split, "total" to bytes.size)
        fun release() { released.set(true); readWake.countDown(); producerRelease.countDown() }
        override fun download() {
            markHarnessStage(HarnessStage.PRODUCER_ENTERED)
            check(producerRelease.await(40, TimeUnit.SECONDS)) { "Fixture producer was never released" }
            if (cancelled.get()) throw IOException("Fixture session cancelled")
            markHarnessStage(HarnessStage.PRODUCER_RELEASED)
            finalFile.writeBytes(bytes)
            committed.set(true)
            markHarnessStage(HarnessStage.PRODUCER_COMMITTED)
            markHarnessStage(HarnessStage.RESULT_CALLBACK_BEGIN)
            checkNotNull(result)(JSONObject().put("success", true).put("file_path", finalFile.path).toString())
            markHarnessStage(HarnessStage.RESULT_CALLBACK_END)
        }
        override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate =
            if (cancelled.get()) ProgressiveCandidate.Closed else ProgressiveCandidate.Available(1, lease)
        override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int): ProgressiveTerminal {
            if (committed.get()) return ProgressiveTerminal.Committed
            if (cancelled.get()) return ProgressiveTerminal.Aborted
            Thread.sleep(minOf(20, timeoutMs).toLong())
            return ProgressiveTerminal.Pending
        }
        override fun close() {
            markHarnessStage(HarnessStage.SESSION_CLOSE_BEGIN)
            cancelled.set(true)
            lease.close()
            producerRelease.countDown()
            markHarnessStage(HarnessStage.SESSION_CLOSE_END)
        }
    }
}
