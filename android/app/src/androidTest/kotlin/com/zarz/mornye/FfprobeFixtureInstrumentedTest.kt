package com.zarz.mornye

import android.os.Bundle
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Native, no Flutter engine / player / Dart: runs the same in-process FFprobeKit media-information
 * path that FFmpegKitFlutterPlugin runs for FFprobeKit.getMediaInformation on the synthetic final
 * file. A SIGSEGV between FFPROBE_BEGIN and FFPROBE_END_* would confirm the in-process ffprobe hypothesis.
 *
 * The ffmpeg-kit classes are reached by reflection on purpose: the app declares the AAR as
 * compileOnly, so direct imports are not guaranteed on the androidTest compile classpath.
 * At runtime the plugin's implementation dependency supplies the classes and the native libs.
 */
@RunWith(AndroidJUnit4::class)
class FfprobeFixtureInstrumentedTest {
    private enum class Stage { FFPROBE_FIXTURE_READY, FFPROBE_BEGIN, FFPROBE_END_OK, FFPROBE_END_ERROR, CASE_SUCCESS }

    /** Closed identifiers only: never log paths, exceptions or media content. */
    private fun stage(value: Stage) {
        Log.i("MusaFfprobeFixture", value.name)
        runCatching {
            InstrumentationRegistry.getInstrumentation().sendStatus(2, android.os.Bundle().apply {
                putString("musa_ffprobe_stage", value.name)
            })
        }
    }

    private val pkg = "com.antonkarpenko.ffmpegkit."

    /** Same sequence as FFmpegKitFlutterPlugin: MediaInformationSession.create(args, null, null) then
     *  FFmpegKitConfig.getMediaInformationExecute(session, DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT).
     *  Arguments are exactly those built by Dart FFprobeKit.getMediaInformation. Returns true when ffprobe
     *  succeeded and produced a parseable MediaInformation. */
    private fun probe(path: String): Boolean {
        val sessionClass = Class.forName(pkg + "MediaInformationSession")
        val callback = Class.forName(pkg + "MediaInformationSessionCompleteCallback")
        val logCallback = Class.forName(pkg + "LogCallback")
        val config = Class.forName(pkg + "FFmpegKitConfig")
        val abstractSession = Class.forName(pkg + "AbstractSession")
        val args = arrayOf("-v", "error", "-hide_banner", "-print_format", "json",
            "-show_format", "-show_streams", "-show_chapters", "-i", path)
        val session = sessionClass.getMethod("create", Array<String>::class.java, callback, logCallback)
            .invoke(null, args, null, null)
        val timeout = abstractSession.getField("DEFAULT_TIMEOUT_FOR_ASYNCHRONOUS_MESSAGES_IN_TRANSMIT").getInt(null)
        config.getMethod("getMediaInformationExecute", sessionClass, Int::class.javaPrimitiveType)
            .invoke(null, session, timeout)
        val information = sessionClass.getMethod("getMediaInformation").invoke(session)
        return information != null
    }

    private fun begin(path: String): Boolean {
        stage(Stage.FFPROBE_BEGIN)
        val ok = try { probe(path) } catch (t: Throwable) { stage(Stage.FFPROBE_END_ERROR); throw t }
        stage(if (ok) Stage.FFPROBE_END_OK else Stage.FFPROBE_END_ERROR)
        return ok
    }

    @Test(timeout = 120000)
    fun ffprobeMediaInformationOnSyntheticFinalFileSurvivesRepeatedAndOffMainThreadCalls() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("Refuse ordinary debug app", "org.musa.music.catalogintegration", context.packageName)
        val bytes = instrumentation.context.assets.open("synthetic_fragmented_aac_test.m4a").use { it.readBytes() }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals("6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58", digest)
        val root = File(context.cacheDir, "ffprobe-fixture-" + java.util.UUID.randomUUID()).apply { check(mkdir()) }
        try {
            val finalFile = File(root, "synthetic-final.m4a")
            finalFile.writeBytes(bytes)
            assertEquals(bytes.size.toLong(), finalFile.length())
            stage(Stage.FFPROBE_FIXTURE_READY)
            // Three sequential calls from the instrumentation thread.
            repeat(3) { assertTrue("ffprobe returned no media information", begin(finalFile.path)) }
            // One call from a plain worker thread, like the plugin's asyncExecutorService.
            val done = CountDownLatch(1)
            val outcome = AtomicReference<Result<Boolean>>()
            Thread({
                outcome.set(runCatching { begin(finalFile.path) })
                done.countDown()
            }, "musa-ffprobe-worker").start()
            assertTrue("ffprobe worker timed out", done.await(60, TimeUnit.SECONDS))
            assertTrue("ffprobe worker returned no media information", outcome.get().getOrThrow())
            stage(Stage.CASE_SUCCESS)
        } finally {
            assertEquals(context.cacheDir.canonicalFile, root.canonicalFile.parentFile)
            check(root.name.startsWith("ffprobe-fixture-"))
            root.deleteRecursively()
        }
    }
}
