package com.zarz.mornye

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/** Synthetic protobuf only. No historical exit API/data/device logs are read.
 * Instrumented (androidTest source set): run with connectedAndroidTest; the
 * sanitizer cases below need no device state. Not run on the host JVM.
 */
@RunWith(AndroidJUnit4::class)
class TestTombstoneSanitizerInstrumentedTest {
    private fun number(value: Long): ByteArray {
        val out = ByteArrayOutputStream(); var n = value
        do { val b = (n and 127).toInt(); n = n ushr 7; out.write(if (n != 0L) b or 128 else b) } while (n != 0L)
        return out.toByteArray()
    }
    private fun n(field: Int, value: Long) = number((field shl 3).toLong()) + number(value)
    private fun b(field: Int, value: ByteArray) = number(((field shl 3) or 2).toLong()) + number(value.size.toLong()) + value
    private fun text(field: Int, value: String) = b(field, value.toByteArray())
    private fun frame(module: String, pc: Long) = n(1, pc) + n(2, 0xdeadbeef) + n(3, 0xcafebabe) +
        text(4, "SECRET_SYMBOL") + text(6, "/SECRET_PATH/" + module)
    private fun entry(tid: Int, frames: ByteArray): ByteArray = n(1, tid.toLong()) +
        b(2, n(1, tid.toLong()) + text(2, "SECRET_THREAD") + b(3, text(1, "SECRET_REGISTER")) +
            b(4, frames) + b(5, text(4, "SECRET_MEMORY")))
    private fun fixture(uid: Int = 12345, pid: Int = 456, module: String = "libflutter.so", pc: Long = 0x1234): ByteArray =
        n(5, pid.toLong()) + n(6, 789) + n(7, uid.toLong()) + text(9, "SECRET_COMMAND") +
        b(10, n(1, 11) + n(9, 0xdeadbeef)) + text(14, "SECRET_ABORT") +
        b(16, entry(789, frame(module, pc))) + b(16, entry(999, frame("libc.so", 0xaaaa))) +
        b(17, text(7, "SECRET_MAPPING")) + b(18, text(1, "SECRET_LOG"))
    private fun parse(bytes: ByteArray, limit: Int = 8388608, deadline: Long = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)) =
        TestTombstoneSanitizer.parse(ByteArrayInputStream(bytes), limit, 12345, 456, deadline)
    private fun rejected(action: () -> Unit) {
        try { action() } catch (_: Exception) { return }
        fail("Expected fail-closed rejection")
    }
    @Test fun nonceAbsentIsNoOpAndMalformedNonceRejected() {
        assertNull(TestOwnCrashCorrelation.summary(null))
        assertArrayEquals(("MUSA_TEST_TRACE:" + "a".repeat(32)).toByteArray(), TestOwnCrashCorrelation.summary("a".repeat(32)))
        rejected { TestOwnCrashCorrelation.summary("SECRET") }
        rejected { TestOwnCrashCorrelation.summary("a".repeat(31)) }
    }
    @Test fun keepsOnlySignalAndAllowedCrashingThreadRelativeFrame() {
        val value = parse(fixture())
        assertEquals(11, value.signal)
        assertEquals(listOf(TestTombstoneSanitizer.Frame("APK_MODULE_13", 0x1234)), value.frames)
        assertFalse(value.toString().contains("SECRET"))
        assertFalse(value.toString().contains("deadbeef"))
        assertFalse(value.toString().contains("libc.so"))
    }
    @Test fun missingRelativePcIsUnavailableButExplicitZeroIsObserved() {
        val identity = n(5, 456) + n(6, 789) + n(7, 12345) + b(10, n(1, 11))
        val missing = identity + b(16, entry(789, text(6, "/SECRET/libflutter.so")))
        assertTrue(parse(missing).frames.isEmpty())
        val explicitZero = identity + b(16, entry(789, frame("libflutter.so", 0)))
        assertEquals(listOf(TestTombstoneSanitizer.Frame("APK_MODULE_13", 0)), parse(explicitZero).frames)
    }
    @Test fun countersDistinguishAbsentAndUnallowedFieldsOnlyOnCrashingThread() {
        val identity = n(5,456) + n(6,789) + n(7,12345) + b(10,n(1,11))
        val mixed = n(1,789) +
            b(4,frame("libflutter.so",10)) +
            b(4,text(6,"/SECRET/UNLISTED.so")) +
            b(4,n(1,20)) +
            b(4,frame("libc.so",30) + n(99,123)) + n(100,456)
        val payload = identity + b(16,n(1,789) + b(2,mixed)) +
            b(16,entry(999,frame("libflutter.so",40) + n(101,999)))
        val counts = parse(payload).counts
        assertEquals(TestTombstoneSanitizer.Counts(4,3,1,2,1,3,1,2,2,1,0,1),counts)
        assertFalse(counts.toString().contains("SECRET"))
        val emptyThread = identity + b(16,n(1,789) + b(2,n(1,789)))
        assertEquals(TestTombstoneSanitizer.Counts(0,0,0,0,0,0,0,0,0),parse(emptyThread).counts)
    }
    @Test fun fixedApkIdsRejectCollisionsAndMissingNames() {
        assertEquals("APK_MODULE_15", parse(fixture(module = "libmornye_audio.so")).frames.single().module)
        for (name in listOf("libmornye_audio.so.extra", "prefixlibmornye_audio.so",
            "LIBMORNYE_AUDIO.SO", "")) {
            assertTrue(parse(fixture(module = name)).frames.isEmpty())
        }
        // Surrounding spaces are trimmed by name normalization (not a collision).
        assertEquals("APK_MODULE_15", parse(fixture(module = "libmornye_audio.so ")).frames.single().module)
        val identity = n(5,456) + n(6,789) + n(7,12345) + b(10,n(1,11))
        val missing = identity + b(16,entry(789,n(1,10)))
        assertTrue(parse(missing).frames.isEmpty())
        assertEquals(1, parse(missing).counts.missingName)
    }
    @Test fun rejectsOtherOwnerAndUntrustedOffsets() {
        rejected { parse(fixture(uid = 12346)) }
        rejected { parse(fixture(pid = 457)) }
        rejected { parse(fixture(pc = 0x100000000)) }
        assertTrue(parse(fixture(module = "SECRET.so")).frames.isEmpty())
    }
    @Test fun enforcesByteDeadlineAndMalformedPayloadLimits() {
        val bytes = fixture()
        rejected { parse(bytes, limit = bytes.size - 1) }
        rejected { parse(bytes, deadline = System.nanoTime() - 1) }
        rejected { parse(bytes.copyOf(bytes.size - 1)) }
        rejected { parse(number((16 shl 3 or 2).toLong()) + number(0x7fffffff)) }
        rejected { parse(n(5,456) + n(5,456)) }
    }
    private fun rawFrame(name: String, pc: Long) = n(1, pc) + text(6, name)
    private fun multi(sig: ByteArray, vararg frames: ByteArray) =
        n(5,456) + n(6,789) + n(7,12345) + b(10,sig) +
        b(16, n(1,789) + b(2, n(1,789) + frames.fold(ByteArray(0)) { a, f -> a + b(4, f) }))
    private val sig11 = n(1, 11)
    @Test fun apkWrappedNamesResolveToAllowlistIds() {
        val value = parse(multi(sig11,
            rawFrame("/data/app/~~SECRET/org.x-1/base.apk!libavformat.so", 1),
            rawFrame("/data/app/~~SECRET/org.x-1/base.apk!libflutter.so (offset 0x1234000)", 2),
            rawFrame("/data/app/x/base.apk!/lib/arm64-v8a/libflutter.so", 3),
            rawFrame("/apex/com.android.runtime/lib64/bionic/libc.so", 4)))
        assertEquals(listOf(
            TestTombstoneSanitizer.Frame("APK_MODULE_05", 1), TestTombstoneSanitizer.Frame("APK_MODULE_13", 2),
            TestTombstoneSanitizer.Frame("APK_MODULE_13", 3), TestTombstoneSanitizer.Frame("libc.so", 4)), value.frames)
        assertEquals(4, value.counts.allowed)
        assertTrue(value.otherFrames.isEmpty())
    }
    @Test fun unmatchedFramesFallIntoClosedCategoriesWithoutPaths() {
        val value = parse(multi(sig11,
            rawFrame("<anonymous:7f12345000>", 10),
            rawFrame("[anon:dalvik-jit-code-cache]", 11),
            rawFrame("/memfd:jit-cache (deleted)", 12),
            rawFrame("/data/app/~~SECRET/org.x-1/base.apk", 13),
            rawFrame("/system/lib64/libSECRETvendor.so", 14),
            rawFrame("/data/app/x/base.apk!libunlisted.so", 15),
            n(1, 16),
            rawFrame("/system/lib64/libc.so", 17)))
        assertEquals(listOf(
            TestTombstoneSanitizer.Frame("ANON_OR_JIT", 10), TestTombstoneSanitizer.Frame("ANON_OR_JIT", 11),
            TestTombstoneSanitizer.Frame("ANON_OR_JIT", 12), TestTombstoneSanitizer.Frame("APK_CONTAINER", 13),
            TestTombstoneSanitizer.Frame("UNKNOWN_MAP", 14), TestTombstoneSanitizer.Frame("UNKNOWN_MAP", 15),
            TestTombstoneSanitizer.Frame("ANON_OR_JIT", 16)), value.otherFrames)
        assertEquals(listOf(TestTombstoneSanitizer.Frame("libc.so", 17)), value.frames)
        val c = value.counts
        assertEquals(4, c.anonOrJit); assertEquals(1, c.apkContainer); assertEquals(2, c.unknownMap)
        assertEquals(c.total - c.allowed, c.anonOrJit + c.apkContainer + c.unknownMap)
        val text = value.toString()
        for (secret in listOf("SECRET", "/data", "/system", "base.apk", "anonymous", "anon:", "memfd", "libunlisted", "/"))
            assertFalse(secret, text.contains(secret))
    }
    @Test fun faultAddressIsReducedToClosedCategory() {
        fun fault(sig: ByteArray) = parse(multi(sig)).fault
        assertEquals("FAULT_NONE", fault(n(1, 11)))
        assertEquals("FAULT_NULL_PAGE", fault(n(1, 11) + n(8, 1)))
        assertEquals("FAULT_NULL_PAGE", fault(n(1, 11) + n(8, 1) + n(9, 0x10)))
        assertEquals("FAULT_NULL_PAGE", fault(n(1, 11) + n(8, 1) + n(9, 0xfff)))
        assertEquals("FAULT_OTHER", fault(n(1, 11) + n(8, 1) + n(9, 0x1000)))
        assertEquals("FAULT_OTHER", fault(n(1, 11) + n(8, 1) + n(9, 0xdeadbeef)))
        assertEquals("FAULT_NONE", fault(n(1, 11) + n(8, 0) + n(9, 0x10)))
        assertFalse(parse(multi(n(1, 11) + n(8, 1) + n(9, 0xdeadbeef))).toString().contains("deadbeef"))
        rejected { fault(n(1, 11) + n(9, 1) + n(9, 1)) }
        rejected { fault(n(1, 11) + n(8, 2)) }
    }
    @Test fun rejectsDuplicateCrashingThreadAndMissingIdentity() {
        rejected { parse(fixture() + b(16, entry(789, frame("libc.so", 10)))) }
        rejected { parse(b(16, entry(789, frame("libc.so", 10))) + fixture()) }
    }
}
