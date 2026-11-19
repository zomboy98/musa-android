package com.zarz.mornye

import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mornye.backend.ExtensionManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.IOException
import java.lang.reflect.Proxy
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
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

/**
 * Real Rust lease end to end, no Dart: loopback HTTP server (no provider, no credentials) ->
 * extension file.download -> ExtensionManager.createProvisionalFmp4Session / downloadProgressive ->
 * nextLease / readAt -> UniffiLeaseAdapter -> Media3ProgressivePlayer, volume 0, seek, close.
 * The server withholds the tail of the file until the test releases it (throttled partial download).
 * Closed-vocabulary markers only: musa_real_lease_stage / musa_real_lease_failure.
 * The MP3 case documents that the provisional fMP4 gate rejects non-fMP4 containers (expected rejection).
 */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class RealLeaseMedia3InstrumentedTest {
    private fun field(owner: Any, name: String) = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }
    private enum class Stage { START, GUARDS_PASSED, FIXTURE_VERIFIED, SERVER_STARTED, DECK_OPTED_IN, BRIDGE_STARTED,
        PREFIX_SENT, RANGE_HEADER_ABSENT, RANGE_HEADER_PRESENT, ATTACHED, PREPARED, PLAY_BEGIN, PROGRESS_OBSERVED,
        SEEK_BEGIN, SEEK_DEFERRED, SEEK_DISPATCHED, SEEK_CONFIRMED, POST_SEEK_PROGRESS, TAIL_RELEASED, DOWNLOAD_RESULT,
        COMMIT_OBSERVED, REJECTION_OBSERVED,
        DIAG_STATE_IDLE, DIAG_STATE_BUFFERING, DIAG_STATE_READY, DIAG_STATE_ENDED, DIAG_PLAY_WHEN_READY, DIAG_NOT_PLAY_WHEN_READY, DIAG_IS_PLAYING,
        DIAG_NOT_PLAYING, DIAG_POS_ADVANCED_SOME, DIAG_POS_STUCK, DIAG_POS_REGRESSED, DIAG_WRAPPED_PLAYING, DIAG_WRAPPED_NOT_PLAYING, CLEANUP_BEGIN, CLOSE_CONFIRMED, CLEANUP_END, CASE_SUCCESS }
    private enum class Failure { ASSERTION, SECURITY, IO, ILLEGAL_STATE, OTHER, CLEANUP, GUARD, SERVER, ATTACH_TIMEOUT,
        PREPARE_TIMEOUT, PROGRESS_TIMEOUT, SEEK_TIMEOUT, POST_SEEK_TIMEOUT, DOWNLOAD_TIMEOUT, COMMIT_TIMEOUT,
        UNEXPECTED_ATTACH, REJECTION_MISSING, PLAYER_ERROR, CLOSE_FAILED }
    private fun stage(value: Stage) { runCatching { InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("musa_real_lease_stage", value.name) }) } }
    private fun failure(value: Failure) { runCatching { InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("musa_real_lease_failure", value.name) }) } }
    private fun gate(kind: Failure, value: Boolean) { if (!value) { failure(kind); throw AssertionError("Real-lease check failed") } }

    @Test(timeout = 90000)
    fun fragmentedAacFixtureStreamsThroughRealLease() = run("synthetic_fragmented_aac_test.m4a", "6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58", ".m4a", expectLease = true)

    @Test(timeout = 90000)
    fun seekableSidxFixtureStreamsThroughRealLease() = run("synthetic_seekable_sidx.m4a", "71472ebc569df10eb767b4eb92443eb50b943e51a676cec19e2f820bd50b405e", ".m4a", expectLease = true)

    @Test(timeout = 90000)
    fun mp3FixtureIsRejectedByProvisionalFmp4Gate() = run("carefree_kevin_macleod_original.mp3", "8433b770a630d9b1594fd484442c677907ece899a4d149954cd2e74fd733e311", ".mp3", expectLease = false)

    private fun run(asset: String, sha: String, ext: String, expectLease: Boolean) {
        stage(Stage.START)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        gate(Failure.GUARD, context.packageName == "org.musa.music.catalogintegration")
        gate(Failure.GUARD, context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        assumeTrue(android.os.Build.VERSION.SDK_INT >= 28)
        gate(Failure.GUARD, context.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_MUSIC) == 0)
        stage(Stage.GUARDS_PASSED)
        val bytes = instrumentation.context.assets.open(asset).use { it.readBytes() }
        gate(Failure.GUARD, sha == MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
        gate(Failure.GUARD, bytes.size > 4096); stage(Stage.FIXTURE_VERIFIED)
        val tail = 1024
        val root = File(context.cacheDir, "real-lease-${System.nanoTime()}")
        val setupCleanup = ArrayDeque<() -> Unit>()
        val cleanupErrors = mutableListOf<Throwable>()
        fun clean(action: () -> Unit) { runCatching(action).exceptionOrNull()?.let { cleanupErrors.add(it) } }
        var primary: Throwable? = null
        val release = CountDownLatch(1)
        val prefixSent = CountDownLatch(1)
        val serverFailure = AtomicReference<Throwable?>()
        val sockets = ConcurrentHashMap.newKeySet<Socket>()
        val rangeSeen = AtomicBoolean(false)
        val requests = AtomicInteger()
        val attached = CountDownLatch(1)
        val downloadResult = CountDownLatch(1)
        val committed = CountDownLatch(1)
        val rejected = CountDownLatch(1)
        val seekComplete = CountDownLatch(1)
        val playerFailed = AtomicBoolean(false)
        val thread = HandlerThread("musa-real-lease")
        var handler: Handler? = null
        var manager: ExtensionManager? = null
        var wrapped: WrappedPlayer? = null
        var events: EventHandler? = null
        var deck: AudioplayersPlugin.ExperimentalProgressiveDeck? = null
        var controller: ProgressiveDeckController? = null
        fun <T> onLoop(block: () -> T): T {
            val active = checkNotNull(handler) { "Playback handler unavailable" }
            val result = AtomicReference<T>(); val error = AtomicReference<Throwable?>(); val done = CountDownLatch(1)
            check(active.post { try { result.set(block()) } catch (t: Throwable) { error.set(t) } finally { done.countDown() } })
            check(done.await(10, TimeUnit.SECONDS)) { "Playback task timed out" }
            error.get()?.let { throw it }
            return result.get()
        }
        fun awaitState(kind: Failure, millis: Long = 15000, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + millis
            while (SystemClock.elapsedRealtime() < deadline && !playerFailed.get()) { if (onLoop(condition)) return; Thread.sleep(25) }
            gate(Failure.PLAYER_ERROR, !playerFailed.get())
            gate(kind, false)
        }
        try {
            check(root.mkdirs())
            val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
            setupCleanup.addFirst { server.close() }
            val serverExecutor = Executors.newCachedThreadPool()
            setupCleanup.addFirst { serverExecutor.shutdownNow(); check(serverExecutor.awaitTermination(5, TimeUnit.SECONDS)) { "server executor did not terminate" } }
            val io = Executors.newFixedThreadPool(3)
            val cleanup = Executors.newFixedThreadPool(2)
            val completion = Executors.newFixedThreadPool(2)
            setupCleanup.addFirst { listOf(io, cleanup, completion).forEach { it.shutdownNow(); check(it.awaitTermination(5, TimeUnit.SECONDS)) { "executor did not terminate" } } }
            setupCleanup.addFirst { thread.quitSafely(); thread.join(5000); check(!thread.isAlive) { "player thread did not terminate" } }
            thread.start(); handler = Handler(thread.looper)
            stage(Stage.SERVER_STARTED)
            serverExecutor.submit {
                try {
                    while (!server.isClosed) {
                        val client = server.accept(); sockets.add(client); requests.incrementAndGet()
                        serverExecutor.submit {
                            try {
                                client.soTimeout = 15000
                                val input = client.getInputStream()
                                var head = ""
                                while (!head.endsWith("\r\n\r\n")) { val b = input.read(); check(b >= 0); head = (head + b.toChar()).takeLast(2048) }
                                if (head.lowercase().contains("\r\nrange:")) rangeSeen.set(true)
                                val out = client.getOutputStream()
                                out.write("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                                var sent = 0; val prefix = bytes.size - tail
                                while (sent < prefix) { val n = minOf(16384, prefix - sent); out.write(bytes, sent, n); sent += n; if (prefix > 200000) Thread.sleep(3) }
                                out.flush(); prefixSent.countDown()
                                release.await()
                                out.write(bytes, prefix, tail); out.flush()
                            } catch (t: Throwable) { if (!server.isClosed) serverFailure.compareAndSet(null, t) } finally { runCatching { client.close() } }
                        }
                    }
                } catch (_: IOException) { /* server closed by cleanup */ } catch (t: Throwable) { serverFailure.compareAndSet(null, t) }
            }
            val id = "example.audio"
            val sources = File(root, "sources").apply { mkdirs() }
            val extension = File(sources, id).apply { mkdirs() }
            val output = File(root, "output").apply { mkdirs() }
            File(extension, "manifest.json").writeText("""{"name":"$id","version":"1","description":"local fixture","type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"aac_128","kind":"lossy"}]}""")
            File(extension, "index.js").writeText("""registerExtension({download(id,q,path){let d=file.download("http://127.0.0.1:${server.localPort}/audio",path,{maxAttempts:1,resume:false,chunked:true});return d.success?{success:true,file_path:d.path,actual_extension:'$ext'}:d;}});""")
            val native = ExtensionManager(sources.path, File(root, "data").path, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", 10000uL)
            manager = native
            native.environment().use { it.setAllowPrivateNetwork(true); it.setAllowedDownloadDirectories(listOf(output.path)) }
            native.loadAll(); native.setEnabled(id, true)
            val request = JSONObject().apply {
                put("service", id); put("source", id); put("provider_track_id", "fixture")
                put("temporary_playback", true); put("use_extensions", true); put("use_fallback", false)
                put("output_dir", output.path); put("track_name", "Fixture"); put("artist_name", "Fixture")
                put("album_name", "Fixture"); put("filename_format", "{title}"); put("output_ext", ext)
                put("quality", "aac_128"); put("allow_quality_fallback", true); put("embed_metadata", false); put("embed_lyrics", false)
            }.toString()
            onLoop {
                val plugin = AudioplayersPlugin(experimentalProgressiveForTesting = true)
                field(plugin, "context").set(plugin, context)
                field(plugin, "playbackThread").set(plugin, thread); field(plugin, "playbackHandler").set(plugin, handler)
                val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
                val eventHandler = EventHandler(EventChannel(messenger, "test/real-lease")); events = eventHandler
                eventHandler.onListen(null, object : EventChannel.EventSink {
                    override fun success(event: Any?) { if ((event as? Map<*, *>)?.get("event") == "audio.onSeekComplete") seekComplete.countDown() }
                    override fun error(code: String?, message: String?, details: Any?) { playerFailed.set(true) }
                    override fun endOfStream() {}
                })
                val player = WrappedPlayer::class.java.constructors.single().newInstance(plugin, eventHandler,
                    AudioContextAndroid().copy(audioFocus = AudioManager.AUDIOFOCUS_NONE), SoundPoolManager(plugin)) as WrappedPlayer
                wrapped = player; player.volume = 0f; player.releaseMode = ReleaseMode.STOP
                @Suppress("UNCHECKED_CAST")
                (field(plugin, "players").get(plugin) as ConcurrentHashMap<String, WrappedPlayer>)["real-lease"] = player
                val generation = field(plugin, "generation").getInt(plugin)
                val ctor = Class.forName("xyz.luan.audioplayers.AudioplayersPlugin\$ExperimentalProgressiveDeck").declaredConstructors.single().apply { isAccessible = true }
                deck = ctor.newInstance(plugin, player, "real-lease", generation, true) as AudioplayersPlugin.ExperimentalProgressiveDeck
            }
            stage(Stage.DECK_OPTED_IN)
            val sourceCommitted = AtomicBoolean(false)
            controller = ExperimentalProgressiveBridge(io, true, cleanup, completion).start(native, request, deck,
                fallback = { rejected.countDown() }, onSourceAttached = { attached.countDown() },
                onDownloadResult = { downloadResult.countDown() }, onCancellationFailure = { rejected.countDown() },
                onTerminalFailure = { rejected.countDown() }, onSourceCommitted = { sourceCommitted.set(true); committed.countDown() })
            gate(Failure.ILLEGAL_STATE, controller != null); stage(Stage.BRIDGE_STARTED)
            gate(Failure.SERVER, prefixSent.await(20, TimeUnit.SECONDS) && serverFailure.get() == null); stage(Stage.PREFIX_SENT)
            stage(if (rangeSeen.get()) Stage.RANGE_HEADER_PRESENT else Stage.RANGE_HEADER_ABSENT)
            if (!expectLease) {
                gate(Failure.REJECTION_MISSING, rejected.await(20, TimeUnit.SECONDS))
                gate(Failure.UNEXPECTED_ATTACH, attached.count == 1L && downloadResult.count == 1L)
                stage(Stage.REJECTION_OBSERVED)
            } else {
                gate(Failure.ATTACH_TIMEOUT, attached.await(20, TimeUnit.SECONDS)); gate(Failure.UNEXPECTED_ATTACH, rejected.count == 1L)
                stage(Stage.ATTACHED)
                awaitState(Failure.PREPARE_TIMEOUT) { wrapped!!.prepared }; stage(Stage.PREPARED)
                val media3 = onLoop { checkNotNull(field(wrapped!!, "player").get(wrapped)) }
                gate(Failure.GUARD, media3.javaClass.simpleName == "Media3ProgressivePlayer")
                gate(Failure.GUARD, onLoop { (field(media3, "player").get(media3) as ExoPlayer).volume } == 0f)
                gate(Failure.UNEXPECTED_ATTACH, downloadResult.count == 1L) // still partial: tail withheld
                stage(Stage.PLAY_BEGIN); onLoop { wrapped!!.play() }
                awaitState(Failure.PROGRESS_TIMEOUT) { wrapped!!.playing && (wrapped!!.getCurrentPosition() ?: 0) >= 300 }
                stage(Stage.PROGRESS_OBSERVED)
                stage(Stage.SEEK_BEGIN)
                val deferred = onLoop { wrapped!!.seek(100); wrapped!!.shouldSeekTo == 100 }
                stage(if (deferred) Stage.SEEK_DEFERRED else Stage.SEEK_DISPATCHED)
                gate(Failure.SEEK_TIMEOUT, seekComplete.await(10, TimeUnit.SECONDS)); stage(Stage.SEEK_CONFIRMED)
                val afterSeek = onLoop { checkNotNull(wrapped!!.getCurrentPosition()) }
                try { awaitState(Failure.POST_SEEK_TIMEOUT) { (wrapped!!.getCurrentPosition() ?: 0) >= afterSeek + 150 } } catch (t: Throwable) {
                    runCatching { onLoop {
                        val m3 = field(wrapped!!, "player").get(wrapped); val exo = field(m3, "player").get(m3) as ExoPlayer
                        stage(when (exo.playbackState) { 1 -> Stage.DIAG_STATE_IDLE; 2 -> Stage.DIAG_STATE_BUFFERING; 3 -> Stage.DIAG_STATE_READY; else -> Stage.DIAG_STATE_ENDED })
                        stage(if (exo.playWhenReady) Stage.DIAG_PLAY_WHEN_READY else Stage.DIAG_NOT_PLAY_WHEN_READY)
                        stage(if (exo.isPlaying) Stage.DIAG_IS_PLAYING else Stage.DIAG_NOT_PLAYING)
                        stage(if (wrapped!!.playing) Stage.DIAG_WRAPPED_PLAYING else Stage.DIAG_WRAPPED_NOT_PLAYING)
                        val now = wrapped!!.getCurrentPosition() ?: 0
                        stage(if (now > afterSeek) Stage.DIAG_POS_ADVANCED_SOME else if (now == afterSeek) Stage.DIAG_POS_STUCK else Stage.DIAG_POS_REGRESSED)
                    } }
                    throw t
                }
                stage(Stage.POST_SEEK_PROGRESS)
                release.countDown(); stage(Stage.TAIL_RELEASED)
                gate(Failure.DOWNLOAD_TIMEOUT, downloadResult.await(20, TimeUnit.SECONDS)); stage(Stage.DOWNLOAD_RESULT)
                gate(Failure.COMMIT_TIMEOUT, committed.await(10, TimeUnit.SECONDS)); stage(Stage.COMMIT_OBSERVED)
                gate(Failure.PLAYER_ERROR, !playerFailed.get())
            }
        } catch (error: Throwable) {
            failure(when (error) { is AssertionError -> Failure.ASSERTION; is SecurityException -> Failure.SECURITY; is IOException -> Failure.IO; is IllegalStateException -> Failure.ILLEGAL_STATE; else -> Failure.OTHER })
            primary = error
        } finally {
            stage(Stage.CLEANUP_BEGIN)
            release.countDown()
            sockets.forEach { s -> clean { s.close() } }
            clean { controller?.let { active ->
                val closed = CountDownLatch(1); val outcome = AtomicReference<Boolean>()
                active.closeAndNotify { outcome.set(it); closed.countDown() }
                check(closed.await(15, TimeUnit.SECONDS)) { "controller cleanup did not settle" }
                check(outcome.get() == true) { "controller reported unsuccessful cleanup" }
            } }
            clean { val detached = CountDownLatch(1); if (deck != null) { deck!!.close { detached.countDown() }; check(detached.await(10, TimeUnit.SECONDS)) } }
            clean { if (handler != null) onLoop { wrapped?.release() } }
            clean { if (handler != null) onLoop { events?.dispose() } }
            clean { manager?.close() }
            if (primary == null && cleanupErrors.isEmpty()) stage(Stage.CLOSE_CONFIRMED)
            setupCleanup.forEach { clean(it) }
            clean { check(!root.exists() || root.deleteRecursively()) { "fixture directory was not deleted" } }
            if (cleanupErrors.isNotEmpty()) failure(Failure.CLEANUP)
            if (primary != null) cleanupErrors.forEach(primary::addSuppressed)
        }
        primary?.let { throw it }
        cleanupErrors.firstOrNull()?.let { first -> cleanupErrors.drop(1).forEach(first::addSuppressed); throw first }
        stage(Stage.CLEANUP_END); stage(Stage.CASE_SUCCESS)
    }
}
