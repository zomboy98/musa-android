package com.zarz.mornye

import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.os.Build
import android.os.Bundle
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Test-only post-crash collector. Requires separately verified same-install
 * UID/PID and device epoch bounds from the exact crash attempt; no auto selection.
 * Never writes a file, logs protobuf, prints descriptions, or reads other traces.
 * Must run before removing the two isolated packages. Not built or executed.
 */
@RunWith(AndroidJUnit4::class)
class OwnNativeExitTraceInstrumentedTest {
    @Test(timeout = 10000)
    fun collectOnlyExactOwnNativeCrashProjection() {
        try { collect() } catch (_: Throwable) {
            // Never let framework exception messages/cause leak arbitrary trace data.
            throw AssertionError("OWN_NATIVE_TRACE_UNAVAILABLE_OR_UNCONFIRMED")
        }
    }
    private fun collect() {
        check(Build.VERSION.SDK_INT >= 31)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        check(context.packageName == "org.musa.music.catalogintegration")
        check(context.applicationContext.javaClass == Application::class.java)
        check(Application.getProcessName() == context.packageName)
        val args = InstrumentationRegistry.getArguments()
        val uid = checkNotNull(args.getString("diagUid")?.toIntOrNull())
        val pid = checkNotNull(args.getString("diagPid")?.toIntOrNull())
        val began = checkNotNull(args.getString("diagStartEpochMs")?.toLongOrNull())
        val ended = checkNotNull(args.getString("diagEndEpochMs")?.toLongOrNull())
        val nonce = checkNotNull(args.getString("diagNonce"))
        val expectedSummary = checkNotNull(TestOwnCrashCorrelation.summary(nonce))
        val now = System.currentTimeMillis()
        check(uid >= 10000 && uid == Process.myUid() && uid == context.applicationInfo.uid)
        check(pid > 0 && pid != Process.myPid())
        check(began > 0 && ended >= began && ended - began <= 180000)
        check(now >= ended && now - ended <= 60000)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        val projection = AtomicReference<TestTombstoneSanitizer.Projection>()
        val failure = AtomicReference<String>()
        val stream = AtomicReference<InputStream>()
        val done = CountDownLatch(1)
        val worker = Thread({
            try {
                val manager = context.getSystemService(ActivityManager::class.java)
                val matches = manager.getHistoricalProcessExitReasons(context.packageName, pid, 16).filter {
                    it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE && it.pid == pid &&
                        it.realUid == uid && it.packageUid == uid &&
                        it.processName == context.packageName && it.timestamp in began..ended &&
                        it.processStateSummary?.contentEquals(expectedSummary) == true
                }
                check(matches.size == 1)
                check(System.nanoTime() < deadline)
                val input = checkNotNull(matches.single().traceInputStream)
                stream.set(input)
                input.use {
                    val value = TestTombstoneSanitizer.parse(it, 8388608, uid, pid, deadline)
                    check(System.nanoTime() < deadline)
                    projection.set(value)
                }
            } catch (_: Throwable) {
                failure.set("TRACE_UNAVAILABLE_OR_REJECTED")
            } finally { done.countDown() }
        }, "musa-own-exit-trace").apply { isDaemon = true }
        worker.start()
        if (!done.await(3500, TimeUnit.MILLISECONDS)) {
            worker.interrupt()
            // Blocking framework read/close is not promised cancellable. Bound caller
            // latency; no worker may emit or persist anything, even after timeout.
            Thread({ runCatching { stream.get()?.close() } }, "musa-trace-close")
                .apply { isDaemon = true }.start()
            throw AssertionError("TRACE_TIMEOUT_CLEANUP_UNCONFIRMED")
        }
        worker.join(100)
        check(!worker.isAlive && failure.get() == null)
        val value = checkNotNull(projection.get())
        // All output is a checked signal number and fixed module/relative-PC projection.
        // No uid/pid/tid/time/path/symbol/register/memory/description leaves this test.
        instrumentation.sendStatus(2, Bundle().apply { putInt("musa_own_trace_signal", value.signal) })
        instrumentation.sendStatus(2, Bundle().apply {
            val c = value.counts
            check(listOf(c.total,c.named,c.missingName,c.allowed,c.unallowed,c.pcPresent,c.pcMissing,c.emitted,
                c.anonOrJit,c.apkContainer,c.unknownMap).all { it in 0..256 })
            check(c.unknownFields in 0..1024)
            check(c.anonOrJit + c.apkContainer + c.unknownMap == c.total - c.allowed)
            putInt("musa_own_trace_count_total", c.total)
            putInt("musa_own_trace_count_named", c.named)
            putInt("musa_own_trace_count_missing_name", c.missingName)
            putInt("musa_own_trace_count_allowed", c.allowed)
            putInt("musa_own_trace_count_unallowed", c.unallowed)
            putInt("musa_own_trace_count_pc_present", c.pcPresent)
            putInt("musa_own_trace_count_pc_missing", c.pcMissing)
            putInt("musa_own_trace_count_emitted", c.emitted)
            putInt("musa_own_trace_count_unknown_fields", c.unknownFields)
            putInt("musa_own_trace_count_anon_or_jit", c.anonOrJit)
            putInt("musa_own_trace_count_apk_container", c.apkContainer)
            putInt("musa_own_trace_count_unknown_map", c.unknownMap)
        })
        // Closed fault category only (never the address) and closed map categories + rel_pc.
        check(value.fault in TestTombstoneSanitizer.faultCategories)
        instrumentation.sendStatus(2, Bundle().apply { putString("musa_own_trace_fault", value.fault) })
        check(value.otherFrames.size <= 64)
        value.otherFrames.forEach { frame ->
            check(frame.module in TestTombstoneSanitizer.mapCategories && frame.relativePc in 0..0xffffffffL)
            instrumentation.sendStatus(2, Bundle().apply {
                putString("musa_own_trace_other_frame", frame.module + "@" + frame.relativePc.toString(16))
            })
        }
        value.frames.forEach { frame ->
            check(frame.module in TestTombstoneSanitizer.modules && frame.relativePc in 0..0xffffffffL)
            instrumentation.sendStatus(2, Bundle().apply {
                putString("musa_own_trace_frame", frame.module + "@" + frame.relativePc.toString(16))
            })
        }
    }
}
