package com.zarz.mornye

import java.io.InputStream

/** Test-only strict projection of AOSP tombstone.proto, schema blob
 * 9deeeec9e185f79747acf5fb6a7e71586eb7da16. Never serializes raw protobuf.
 * Unknown fields are skipped, including registers/memory/logs/abort messages.
 * Noncanonical ordering/ambiguous records fail closed, not guessed.
 */
internal object TestTombstoneSanitizer {
    // Names validated against archived build10 ARM64 APK; output is a fixed ID.
    // A basename match is only a candidate, not proof of binary identity or cause.
    private val apkModules = mapOf(
        "libVkLayer_khronos_validation.so" to "APK_MODULE_01",
        "libavcodec.so" to "APK_MODULE_02",
        "libavdevice.so" to "APK_MODULE_03",
        "libavfilter.so" to "APK_MODULE_04",
        "libavformat.so" to "APK_MODULE_05",
        "libavutil.so" to "APK_MODULE_06",
        "libc++_shared.so" to "APK_MODULE_07",
        "libdart_smb2.so" to "APK_MODULE_08",
        "libdartjni.so" to "APK_MODULE_09",
        "libdatastore_shared_counter.so" to "APK_MODULE_10",
        "libffmpegkit.so" to "APK_MODULE_11",
        "libffmpegkit_abidetect.so" to "APK_MODULE_12",
        "libflutter.so" to "APK_MODULE_13",
        "libjnidispatch.so" to "APK_MODULE_14",
        "libmornye_audio.so" to "APK_MODULE_15",
        "libmornye_discord.so" to "APK_MODULE_16",
        "libmornye_mobile.so" to "APK_MODULE_17",
        "libswresample.so" to "APK_MODULE_18",
        "libswscale.so" to "APK_MODULE_19"
    )
    private val legacyModules = setOf("libc.so", "libart.so", "libmedia_jni.so",
        "libaudioclient.so", "libaudioprocessing.so", "libaaudio.so", "libstagefright.so")
    val modules = apkModules.values.toSet() + legacyModules
    private fun moduleId(name: String?): String? = apkModules[name] ?: name?.takeIf { it in legacyModules }
    // Closed categories for frames whose map is not allowlisted. The map name
    // itself is never emitted; only one of these fixed IDs and the numeric rel_pc.
    const val ANON_OR_JIT = "ANON_OR_JIT"
    const val APK_CONTAINER = "APK_CONTAINER"
    const val UNKNOWN_MAP = "UNKNOWN_MAP"
    val mapCategories = setOf(ANON_OR_JIT, APK_CONTAINER, UNKNOWN_MAP)
    // Closed fault-address categories; the address value itself is never emitted.
    const val FAULT_NONE = "FAULT_NONE"
    const val FAULT_NULL_PAGE = "FAULT_NULL_PAGE"
    const val FAULT_OTHER = "FAULT_OTHER"
    val faultCategories = setOf(FAULT_NONE, FAULT_NULL_PAGE, FAULT_OTHER)
    private val offsetSuffix = Regex("""\s*\(offset 0x[0-9a-fA-F]+\)\s*$""")
    // extractNativeLibs=false: AOSP names APK-mapped libs ".../base.apk!libX.so",
    // optionally with " (offset 0x...)". Reduce to the bare library name.
    internal fun normalizeMapName(raw: String): String {
        val s = raw.replace(offsetSuffix, "").trim()
        val bang = s.lastIndexOf('!')
        if (bang < 0) return s.substringAfterLast('/').trim()
        val tail = s.substring(bang + 1).substringAfterLast('/').trim()
        return if (tail.isNotEmpty()) tail else s.substring(0, bang).substringAfterLast('/').trim()
    }
    internal fun mapCategory(raw: String?): String {
        if (raw == null) return ANON_OR_JIT
        val t = raw.trim(); val name = normalizeMapName(raw)
        return when {
            t.isEmpty() || name.isEmpty() || t.startsWith("<anonymous:") || t.startsWith("[anon:") ||
                name.startsWith("memfd:") -> ANON_OR_JIT
            name.endsWith(".apk") -> APK_CONTAINER
            else -> UNKNOWN_MAP
        }
    }
    data class Frame(val module: String, val relativePc: Long)
    // Invariant: anonOrJit + apkContainer + unknownMap == total - allowed.
    data class Counts(val total: Int, val named: Int, val missingName: Int,
        val allowed: Int, val unallowed: Int, val pcPresent: Int, val pcMissing: Int,
        val emitted: Int, val unknownFields: Int,
        val anonOrJit: Int = 0, val apkContainer: Int = 0, val unknownMap: Int = 0)
    // frames: allowlisted modules only (unchanged contract). otherFrames: category
    // ID + rel_pc for non-allowlisted frames that carried a rel_pc.
    data class Projection(val signal: Int, val frames: List<Frame>, val counts: Counts,
        val otherFrames: List<Frame> = emptyList(), val fault: String = FAULT_NONE)

    private class Reader(val input: InputStream, val limit: Int, val deadline: Long) {
        var position = 0
        var eofReached = false
        fun byte(end: Int, allowEof: Boolean = false): Int {
            check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline)
            check(position < end && position < limit)
            val value = input.read()
            if (value < 0 && allowEof) { eofReached = true; return -1 }
            check(value >= 0)
            position++
            return value
        }
        fun number(end: Int, first: Int? = null): Long {
            var value = 0L
            for (i in 0..9) {
                val b = if (i == 0 && first != null) first else byte(end)
                if (i == 9) check(b <= 1)
                value = value or ((b and 127).toLong() shl (i * 7))
                if (b < 128) return value
            }
            error("INVALID_PROTO")
        }
        fun child(end: Int): Int {
            val size = number(end)
            check(size in 0..limit.toLong() && size <= end - position)
            return position + size.toInt()
        }
        fun skip(wire: Int, end: Int) {
            when (wire) {
                0 -> number(end)
                1 -> repeat(8) { byte(end) }
                2 -> { val until = child(end); while (position < until) byte(until) }
                5 -> repeat(4) { byte(end) }
                else -> error("INVALID_WIRE")
            }
        }
        fun text(end: Int): String {
            val until = child(end)
            check(until - position <= 512)
            return buildString { while (position < until) {
                val b = byte(until); check(b in 32..126); append(b.toChar())
            } }
        }
        fun fields(end: Int, allowEof: Boolean = false, action: (Int, Int) -> Unit) {
            while (position < end) {
                val first = if (allowEof) byte(end, true) else null
                if (first == -1) break
                val tag = number(end, first); check(tag in 8..Int.MAX_VALUE.toLong())
                action((tag ushr 3).toInt(), (tag and 7).toInt())
            }
            check(position == end || (allowEof && eofReached))
        }
    }

    fun parse(input: InputStream, length: Int, expectedUid: Int, expectedPid: Int,
              deadlineNanos: Long): Projection {
        check(length in 1..8388608 && expectedUid >= 10000 && expectedPid > 0)
        val r = Reader(input, length, deadlineNanos)
        var uid: Long? = null; var pid: Long? = null; var tid: Long? = null
        var signal: Int? = null; var signalSeen = false; var matchingThreadSeen = false
        var examinedFrames = 0
        var named = 0; var allowed = 0; var pcPresent = 0; var unknownFields = 0
        fun unknown() { unknownFields++; check(unknownFields <= 1024) }
        val frames = mutableListOf<Frame>()
        val otherFrames = mutableListOf<Frame>()
        var anonOrJit = 0; var apkContainer = 0; var unknownMap = 0
        var faultFlag: Boolean? = null; var faultAddress: Long? = null
        fun frame(end: Int) {
            examinedFrames++; check(examinedFrames <= 256)
            var relative = 0L; var relSeen = false; var name: String? = null
            r.fields(end) { field, wire -> when (field) {
                1 -> { check(wire == 0 && !relSeen); relSeen = true; relative = r.number(end); check(relative in 0..0xffffffffL) }
                6 -> { check(wire == 2 && name == null); name = r.text(end) }
                else -> { if (field !in 1..8) unknown(); r.skip(wire, end) }
            } }
            if (name != null) named++
            val module = moduleId(name?.let { normalizeMapName(it) })
            if (module != null) allowed++
            if (relSeen) pcPresent++
            // Proto3 may omit numeric zero. Missing rel_pc is unavailable, not
            // observed @0: omit the frame instead of manufacturing an offset.
            if (module != null && relSeen) {
                check(frames.size < 64); frames.add(Frame(module, relative))
            }
            if (module == null) {
                val category = mapCategory(name)
                when (category) { ANON_OR_JIT -> anonOrJit++; APK_CONTAINER -> apkContainer++; else -> unknownMap++ }
                if (relSeen) { check(otherFrames.size < 64); otherFrames.add(Frame(category, relative)) }
            }
        }
        fun thread(end: Int) {
            var idSeen = false
            r.fields(end) { field, wire -> when (field) {
                1 -> { check(wire == 0 && !idSeen); idSeen = true; check(r.number(end) == tid) }
                4 -> { check(wire == 2); frame(r.child(end)) }
                else -> { if (field !in 1..9) unknown(); r.skip(wire, end) }
            } }
            check(idSeen)
        }
        r.fields(length, allowEof = true) { field, wire -> when (field) {
            5 -> { check(wire == 0 && pid == null); pid = r.number(length); check(pid == expectedPid.toLong()) }
            6 -> { check(wire == 0 && tid == null); tid = r.number(length); check(tid!! > 0) }
            7 -> { check(wire == 0 && uid == null); uid = r.number(length); check(uid == expectedUid.toLong()) }
            10 -> {
                check(wire == 2 && !signalSeen); signalSeen = true
                val end = r.child(length)
                r.fields(end) { n, w -> when (n) {
                    1 -> { check(w == 0 && signal == null); val value = r.number(end); check(value in 1L..64L); signal = value.toInt() }
                    8 -> { check(w == 0 && faultFlag == null); val value = r.number(end); check(value in 0L..1L); faultFlag = value == 1L }
                    9 -> { check(w == 0 && faultAddress == null); faultAddress = r.number(end) }
                    else -> r.skip(w, end)
                } }
            }
            16 -> {
                check(wire == 2 && uid != null && pid != null && tid != null)
                val end = r.child(length); var key: Long? = null; var valueSeen = false
                r.fields(end) { n, w -> when (n) {
                    1 -> { check(w == 0 && key == null); key = r.number(end) }
                    2 -> {
                        check(w == 2 && key != null && !valueSeen); valueSeen = true
                        val valueEnd = r.child(end)
                        if (key == tid) { check(!matchingThreadSeen); matchingThreadSeen = true; thread(valueEnd) }
                        else while (r.position < valueEnd) r.byte(valueEnd)
                    }
                    else -> r.skip(w, end)
                } }
            }
            else -> r.skip(wire, length)
        } }
        check(r.eofReached) // Hitting the byte cap is incomplete, never success.
        check(uid == expectedUid.toLong() && pid == expectedPid.toLong() && matchingThreadSeen)
        // Only a closed category leaves here, never the fault address itself.
        val hasFault = faultFlag ?: (faultAddress != null)
        val fault = when {
            !hasFault -> FAULT_NONE
            (faultAddress ?: 0L) in 0L..0xfffL -> FAULT_NULL_PAGE
            else -> FAULT_OTHER
        }
        return Projection(checkNotNull(signal), frames.toList(), Counts(
            examinedFrames, named, examinedFrames - named, allowed, named - allowed,
            pcPresent, examinedFrames - pcPresent, frames.size, unknownFields,
            anonOrJit, apkContainer, unknownMap), otherFrames.toList(), fault)
    }
}
