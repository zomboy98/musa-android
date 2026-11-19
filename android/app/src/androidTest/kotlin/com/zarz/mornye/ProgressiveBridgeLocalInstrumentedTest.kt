package com.zarz.mornye

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mornye.backend.ExtensionManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer

/** Real bridge, controller, UniFFI producer and Media3. No play() and no external network.
 * The runtime flag remains false; the experimental deck is constructed reflectively as in S24.
 * This test requires a rust-enabled instrumentation variant and has not been run yet. */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class ProgressiveBridgeLocalInstrumentedTest {
    private fun field(owner: Any, name: String) = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }

    @Test(timeout = 90000)
    fun bridgePreparesBeforeDownloadCompletesAndCancelsWhilePaused() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bytes = instrumentation.context.assets.open("synthetic_seekable_sidx.m4a").use { it.readBytes() }
        assertTrue("fixture must contain a withheld tail", bytes.size > 2048)
        val root = File(instrumentation.targetContext.cacheDir, "bridge-local-${System.nanoTime()}")
        val setupCleanup = ArrayDeque<() -> Unit>()
        val cleanupErrors = mutableListOf<Throwable>()
        fun clean(action: () -> Unit) { runCatching(action).exceptionOrNull()?.let { cleanupErrors.add(it) } }
        var primary: Throwable? = null
        try {
        check(root.mkdirs()) { "could not create fixture directory" }
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        setupCleanup.addFirst { server.close() }
        server.soTimeout = 15000
        val io = Executors.newFixedThreadPool(3)
        setupCleanup.addFirst { io.shutdownNow(); check(io.awaitTermination(5, TimeUnit.SECONDS)) { "io did not terminate" } }
        val cleanup = Executors.newFixedThreadPool(2)
        setupCleanup.addFirst { cleanup.shutdownNow(); check(cleanup.awaitTermination(5, TimeUnit.SECONDS)) { "cleanup executor did not terminate" } }
        val completion = Executors.newFixedThreadPool(2)
        setupCleanup.addFirst { completion.shutdownNow(); check(completion.awaitTermination(5, TimeUnit.SECONDS)) { "completion executor did not terminate" } }
        val serverExecutor = Executors.newSingleThreadExecutor()
        setupCleanup.addFirst { serverExecutor.shutdownNow(); check(serverExecutor.awaitTermination(5, TimeUnit.SECONDS)) { "server executor did not terminate" } }
        val sentPrefix = CountDownLatch(1)
        val release = CountDownLatch(1)
        val socket = AtomicReference<Socket?>()
        val serverFailure = AtomicReference<Throwable?>()
        val bytesSent = AtomicInteger(0)
        val unexpectedPlayback = AtomicBoolean(false)
        val thread = HandlerThread("bridge-local-player")
        setupCleanup.addFirst { thread.quitSafely(); thread.join(5000); check(!thread.isAlive) { "player thread did not terminate" } }
        thread.start()
        val handler = Handler(thread.looper)
        fun <T> onLoop(block: () -> T): T {
            val result = AtomicReference<T>()
            val error = AtomicReference<Throwable?>()
            val done = CountDownLatch(1)
            check(handler.post { try { result.set(block()) } catch (t: Throwable) { error.set(t) } finally { done.countDown() } })
            check(done.await(10, TimeUnit.SECONDS))
            error.get()?.let { throw it }
            return result.get()
        }
        var manager: ExtensionManager? = null
        var wrapped: WrappedPlayer? = null
        var eventHandler: EventHandler? = null
        var deck: AudioplayersPlugin.ExperimentalProgressiveDeck? = null
        var controller: ProgressiveDeckController? = null
        try {
            val producer = serverExecutor.submit {
                try {
                    server.accept().use { client ->
                        socket.set(client)
                        client.soTimeout = 10000
                        val input = client.getInputStream()
                        var tail = ""
                        while (!tail.endsWith("\r\n\r\n")) {
                            val b = input.read(); check(b >= 0)
                            tail = (tail + b.toChar()).takeLast(4)
                        }
                        val out = client.getOutputStream()
                        out.write("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                        out.write(bytes, 0, bytes.size - 1024); out.flush()
                        bytesSent.set(bytes.size - 1024); sentPrefix.countDown()
                        release.await() // only test cleanup releases this barrier
                    }
                } catch (t: Throwable) {
                    // Record every error, including expected socket closure after cancellation.
                    serverFailure.set(t); sentPrefix.countDown()
                }
            }
            val id = "example.audio"
            val sources = File(root, "sources").apply { mkdirs() }
            val extension = File(sources, id).apply { mkdirs() }
            val output = File(root, "output").apply { mkdirs() }
            File(extension, "manifest.json").writeText("""{"name":"$id","version":"1","description":"local fixture","type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true},"skipMetadataEnrichment":true,"qualityOptions":[{"id":"aac_128","kind":"lossy"}]}""")
            File(extension, "index.js").writeText("""registerExtension({download(id,q,path){let d=file.download("http://127.0.0.1:${server.localPort}/audio",path,{maxAttempts:1,resume:false,chunked:true});return d.success?{success:true,file_path:d.path,actual_extension:'.m4a'}:d;}});""")
            val native = ExtensionManager(sources.path, File(root, "data").path, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", 10000uL)
            manager = native
            native.environment().use { it.setAllowPrivateNetwork(true); it.setAllowedDownloadDirectories(listOf(output.path)) }
            native.loadAll(); native.setEnabled(id, true)
            val request = JSONObject().apply {
                put("service", id); put("source", id); put("provider_track_id", "fixture")
                put("temporary_playback", true); put("use_extensions", true); put("use_fallback", false)
                put("output_dir", output.path); put("track_name", "Fixture"); put("artist_name", "Fixture")
                put("album_name", "Fixture"); put("filename_format", "{title}"); put("output_ext", ".m4a")
                put("quality", "aac_128"); put("allow_quality_fallback", true); put("embed_metadata", false); put("embed_lyrics", false)
            }.toString()
            onLoop {
                val plugin = AudioplayersPlugin(experimentalProgressiveForTesting = true)
                field(plugin, "context").set(plugin, instrumentation.targetContext)
                field(plugin, "playbackThread").set(plugin, thread); field(plugin, "playbackHandler").set(plugin, handler)
                val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
                val events = EventHandler(EventChannel(messenger, "test/bridge-local")); eventHandler = events
                val player = WrappedPlayer::class.java.constructors.single().newInstance(plugin, events, AudioContextAndroid(), SoundPoolManager(plugin)) as WrappedPlayer
                wrapped = player
                // configAndPrepare applies this to the newly created Exo before prepare().
                player.volume = 0f
                @Suppress("UNCHECKED_CAST")
                (field(plugin, "players").get(plugin) as ConcurrentHashMap<String, WrappedPlayer>)["bridge-local"] = player
                val generation = field(plugin, "generation").getInt(plugin)
                val ctor = Class.forName("xyz.luan.audioplayers.AudioplayersPlugin\$ExperimentalProgressiveDeck").declaredConstructors.single().apply { isAccessible = true }
                deck = ctor.newInstance(plugin, player, "bridge-local", generation, true) as AudioplayersPlugin.ExperimentalProgressiveDeck
            }
            val attached = CountDownLatch(1)
            val result = CountDownLatch(1)
            val failures = CountDownLatch(1)
            controller = ExperimentalProgressiveBridge(io, true, cleanup, completion).start(native, request, deck,
                fallback = { failures.countDown() }, onSourceAttached = { attached.countDown() },
                onDownloadResult = { result.countDown() }, onCancellationFailure = { failures.countDown() },
                onTerminalFailure = { failures.countDown() })
            assertNotNull(controller)
            assertTrue("server did not send prefix", sentPrefix.await(15, TimeUnit.SECONDS))
            serverFailure.get()?.let { throw AssertionError("local server failed", it) }
            assertEquals(bytes.size - 1024, bytesSent.get())
            assertFalse("server finished before attachment", producer.isDone)
            assertTrue("bridge did not attach source before completion", attached.await(15, TimeUnit.SECONDS))
            onLoop {
                val media3 = field(wrapped!!, "player").get(wrapped)
                val exo = field(media3, "player").get(media3) as ExoPlayer
                assertEquals(0f, exo.volume, 0f)
                if (exo.isPlaying || exo.playWhenReady || wrapped!!.playing) unexpectedPlayback.set(true)
                exo.addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(isPlaying: Boolean) { if (isPlaying) unexpectedPlayback.set(true) }
                    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) { if (playWhenReady) unexpectedPlayback.set(true) }
                })
            }
            val deadline = SystemClock.elapsedRealtime() + 15000
            while (SystemClock.elapsedRealtime() < deadline && !onLoop { wrapped!!.prepared }) Thread.sleep(50)
            assertTrue("Media3 did not prepare from the incomplete local download; fixture/admission may be inadequate", onLoop { wrapped!!.prepared })
            assertEquals("download completed before withheld tail", 1L, result.count)
            assertEquals("fixture bytes unexpectedly completed", bytes.size - 1024, bytesSent.get())
            assertFalse("local producer finished before READY", producer.isDone)
            serverFailure.get()?.let { throw AssertionError("server failed before cancellation", it) }
            assertEquals("bridge failed", 1L, failures.count)
            onLoop {
                val media3 = field(wrapped!!, "player").get(wrapped)
                val exo = field(media3, "player").get(media3) as ExoPlayer
                assertEquals(Player.STATE_READY, exo.playbackState)
                assertFalse(exo.playWhenReady); assertFalse(exo.isPlaying); assertFalse(wrapped!!.playing)
                assertEquals(0f, exo.volume, 0f)
            }
            val closed = CountDownLatch(1)
            val closeOk = AtomicReference<Boolean>()
            controller!!.closeAndNotify { closeOk.set(it); closed.countDown() }
            assertTrue("controller cancellation did not settle", closed.await(15, TimeUnit.SECONDS))
            assertEquals(true, closeOk.get())
            assertNull("source remained attached", onLoop { wrapped!!.source })
            assertFalse(onLoop { wrapped!!.playing })
            assertFalse("playback observed after attachment", unexpectedPlayback.get())
            release.countDown()
            producer.get(10, TimeUnit.SECONDS)
            serverFailure.get()?.let { throw AssertionError("local server failed during cancellation", it) }
        } finally {
            release.countDown()
            clean { socket.get()?.close() }; clean { server.close() }
            clean { controller?.let { active ->
                val closed = CountDownLatch(1)
                val outcome = AtomicReference<Boolean>()
                active.closeAndNotify { outcome.set(it); closed.countDown() }
                check(closed.await(15, TimeUnit.SECONDS)) { "controller cleanup did not settle" }
                check(outcome.get() == true) { "controller reported unsuccessful cleanup" }
            } }
            clean {
                val detached = CountDownLatch(1)
                if (deck != null) { deck!!.close { detached.countDown() }; check(detached.await(10, TimeUnit.SECONDS)) }
            }
            clean { onLoop { wrapped?.release() } }
            clean { onLoop { eventHandler?.dispose() } }
            clean { manager?.close() }
            listOf(io, cleanup, completion, serverExecutor).forEach { executor ->
                clean { executor.shutdownNow(); check(executor.awaitTermination(5, TimeUnit.SECONDS)) { "executor did not terminate" } }
            }
            clean { thread.quitSafely(); thread.join(5000); check(!thread.isAlive) }
        }
        } catch (t: Throwable) {
            primary = t
        } finally {
            setupCleanup.forEach { clean(it) }
            clean { check(!root.exists() || root.deleteRecursively()) { "fixture directory was not deleted" } }
        }
        val failure = primary
        if (failure != null) { cleanupErrors.forEach { failure.addSuppressed(it) }; throw failure }
        if (cleanupErrors.isNotEmpty()) {
            val failureOnCleanup = AssertionError("cleanup failed", cleanupErrors.first())
            cleanupErrors.drop(1).forEach { failureOnCleanup.addSuppressed(it) }
            throw failureOnCleanup
        }
    }
}
