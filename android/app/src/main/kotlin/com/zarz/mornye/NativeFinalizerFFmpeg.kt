package com.zarz.mornye

import android.util.Log
import com.antonkarpenko.ffmpegkit.FFmpegKit
import com.antonkarpenko.ffmpegkit.FFmpegKitConfig
import com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin
import com.antonkarpenko.ffmpegkit.FFmpegSession
import com.antonkarpenko.ffmpegkit.LogRedirectionStrategy
import com.antonkarpenko.ffmpegkit.ReturnCode
import com.zarz.mornye.SafDownloadHandler.normalizeExt
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.pow

/** Cancellation was requested, but the producer has not acknowledged termination. */
internal class FFmpegProducerUnconfirmed : CancellationException("FFmpeg termination not acknowledged")

internal class FFmpegOperationTimeout(val terminationConfirmed: Boolean) :
    IllegalStateException("FFmpeg operation timed out")

/** Per-session terminal notification. Only one actual terminal event is delivered. */
internal class FFmpegTerminalNotifier(
    private val onStopped: (() -> Unit)?,
    private val onNotStarted: (() -> Unit)?,
) {
    private val delivered = java.util.concurrent.atomic.AtomicBoolean(false)
    fun stopped() = deliver(onStopped)
    fun notStarted() = deliver(onNotStarted)
    private fun deliver(callback: (() -> Unit)?) {
        if (delivered.compareAndSet(false, true)) {
            try { callback?.invoke() } catch (_: Exception) { }
        }
    }
}

internal fun awaitFFmpegCancellation(latch: CountDownLatch, timeoutMs: Long) {
    if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) throw FFmpegProducerUnconfirmed()
    throw CancellationException("Native FFmpeg session cancelled")
}

/** Bound one FFmpeg operation, including time spent waiting for cancellation acknowledgement. */
internal fun awaitFFmpegOperation(
    waitForCompletion: (Long) -> Boolean,
    nowNanos: () -> Long,
    shouldCancel: () -> Boolean,
    cancel: () -> Unit,
    timeoutNanos: Long,
    pollMs: Long = 200,
    acknowledgementMs: Long = 5_000,
    timeoutAsFailure: Boolean = false,
) {
    val deadline = nowNanos() + timeoutNanos
    while (!waitForCompletion(pollMs)) {
        val cancelled = shouldCancel()
        if (cancelled || nowNanos() - deadline >= 0) {
            try { cancel() } catch (_: Exception) {}
            val stopped = waitForCompletion(acknowledgementMs)
            if (timeoutAsFailure && !cancelled && !shouldCancel()) throw FFmpegOperationTimeout(stopped)
            if (!stopped) throw FFmpegProducerUnconfirmed()
            throw CancellationException("Native FFmpeg session cancelled")
        }
    }
}

internal fun isMP4ContainerFile(path: String): Boolean {
    return try {
        File(path).inputStream().use { stream ->
            val header = ByteArray(12)
            val read = stream.read(header)
            read >= 8 &&
                header[4] == 'f'.code.toByte() &&
                header[5] == 't'.code.toByte() &&
                header[6] == 'y'.code.toByte() &&
                header[7] == 'p'.code.toByte()
        }
    } catch (_: Exception) {
        false
    }
}

internal fun NativeDownloadFinalizer.formatForPath(path: String): String {
    return when (normalizeExt(File(path).extension)) {
        ".mp3" -> "mp3"
        ".opus", ".ogg" -> "opus"
        ".m4a", ".mp4", ".aac" -> "m4a"
        else -> "flac"
    }
}

internal fun NativeDownloadFinalizer.scanReplayGain(path: String, shouldCancel: () -> Boolean = { false }): NativeDownloadFinalizer.ReplayGainScan? {
    val command = "-hide_banner -nostats -loglevel info -i ${q(path)} -map 0:a:0 -vn -sn -dn -af ebur128=peak=true:framelog=quiet -f null -"
    val result = runFFmpeg(command, shouldCancel)
    val output = result.second
    if (!result.first) {
        Log.w(TAG, FinalizerDiagnostics.message(FinalizerDiagnostics.Failure.REPLAYGAIN_SCAN, output))
        return null
    }
    val integrated = Regex("I:\\s+(-?\\d+\\.?\\d*)\\s+LUFS")
        .findAll(output)
        .lastOrNull()
        ?.groupValues
        ?.getOrNull(1)
        ?.toDoubleOrNull() ?: return null
    val truePeak = Regex("Peak:\\s+(-?\\d+\\.?\\d*)\\s+dBFS")
        .findAll(output)
        .mapNotNull { it.groupValues.getOrNull(1)?.toDoubleOrNull() }
        .maxOrNull()
    val gain = -18.0 - integrated
    val peak = if (truePeak != null) 10.0.pow(truePeak / 20.0) else 1.0
    return NativeDownloadFinalizer.ReplayGainScan(
        trackGain = "${if (gain >= 0) "+" else ""}${"%.2f".format(Locale.US, gain)} dB",
        trackPeak = "%.6f".format(Locale.US, peak),
        integratedLufs = integrated,
        truePeakLinear = peak,
    )
}

internal fun NativeDownloadFinalizer.runFFmpeg(command: String, shouldCancel: () -> Boolean = { false }): Pair<Boolean, String> {
    return runFFmpegArguments(FFmpegKitConfig.parseArguments(command), shouldCancel)
}

internal fun NativeDownloadFinalizer.runFFmpegArguments(
    arguments: Array<String>,
    shouldCancel: () -> Boolean = { false },
    trackFinalizerSession: Boolean = true,
    onProducerStopped: (() -> Unit)? = null,
    onProducerNotStarted: (() -> Unit)? = null,
    timeoutAsFailure: Boolean = false,
): Pair<Boolean, String> {
    val terminal = FFmpegTerminalNotifier(onProducerStopped, onProducerNotStarted)
    val latch = CountDownLatch(1)
    var completedSession: FFmpegSession? = null
    val session = try {
        checkCancelled(shouldCancel)
        installNativeFFmpegCallbackFilter()
        FFmpegSession.create(
        arguments,
        { finishedSession ->
            completedSession = finishedSession
            synchronized(activeFFmpegSessionLock) {
                activeFFmpegSessionIds.remove(finishedSession.sessionId)
            }
            terminal.stopped()
            latch.countDown()
        },
        null,
        null,
        LogRedirectionStrategy.NEVER_PRINT_LOGS,
        )
    } catch (error: Exception) {
        terminal.notStarted()
        throw error
    }
    val sessionId = session.sessionId
    synchronized(activeFFmpegSessionLock) {
        if (trackFinalizerSession) activeFFmpegSessionIds.add(sessionId)
    }
    nativeFFmpegSessionIds.add(sessionId)
    try {
        FFmpegKitConfig.asyncFFmpegExecute(session)
    } catch (e: Exception) {
        // Launch may have reached native code even if the wrapper threw.
        throw FFmpegProducerUnconfirmed()
    }
    try {
        // This is a per-session limit, not a limit for the entire download.
        awaitFFmpegOperation(
            waitForCompletion = { latch.await(it, TimeUnit.MILLISECONDS) },
            nowNanos = System::nanoTime,
            shouldCancel = shouldCancel,
            cancel = { FFmpegKit.cancel(sessionId) },
            timeoutNanos = TimeUnit.MINUTES.toNanos(30),
            timeoutAsFailure = timeoutAsFailure,
        )
        val finalSession = completedSession ?: session
        val output = finalSession.getAllLogsAsString(1000) ?: ""
        checkCancelled(shouldCancel)
        return ReturnCode.isSuccess(finalSession.returnCode) to output
    } catch (_: InterruptedException) {
        try { FFmpegKit.cancel(sessionId) } catch (_: Exception) {}
        Thread.currentThread().interrupt()
        throw FFmpegProducerUnconfirmed()
    } finally { /* The completion callback owns session retirement. */ }
}

internal fun NativeDownloadFinalizer.installNativeFFmpegCallbackFilter() {
    // The plugin registers its callback once, possibly later; wrap it only after that.
    FFmpegKitFlutterPlugin.ensureGlobalCallbacksRegistered()
    synchronized(ffmpegCompleteCallbackLock) {
        val current = FFmpegKitConfig.getFFmpegSessionCompleteCallback()
        if (current !== nativeFilteringFFmpegCompleteCallback) {
            forwardedFFmpegCompleteCallback = current
            FFmpegKitConfig.enableFFmpegSessionCompleteCallback(nativeFilteringFFmpegCompleteCallback)
        }
    }
}

/**
 * Staged sibling name for conversion outputs: "song.flac" -> "song.partial.flac".
 * The ".partial<ext>" shape is ignored by library scans and duplicate checks,
 * while the real trailing extension still lets FFmpeg infer the muxer. A
 * process kill mid-conversion therefore never leaves a partial file under a
 * real audio name in the user's music folder.
 */
internal fun NativeDownloadFinalizer.stagedConversionPath(finalPath: String): String {
    val file = File(finalPath)
    val ext = file.extension
    val id = java.util.UUID.randomUUID().toString()
    val name = if (ext.isBlank()) "${file.name}.$id.partial" else "${file.nameWithoutExtension}.$id.partial.$ext"
    return File(file.parentFile, name).absolutePath
}

internal fun NativeDownloadFinalizer.promoteStagedConversion(stagedPath: String, finalPath: String): Boolean {
    val staged = File(stagedPath)
    if (!staged.isFile || staged.length() == 0L) return false
    fsyncQuietly(staged)
    val final = File(finalPath)
    val backup = File("$finalPath.mornye-backup-${System.nanoTime()}")
    val backedUp = final.exists()
    if (backedUp && (!final.isFile || !final.renameTo(backup))) return false
    if (staged.renameTo(final)) {
        if (backedUp) backup.delete()
        return true
    }
    if (backedUp) check(backup.renameTo(final)) { "failed to restore conversion source" }
    return false
}

internal fun NativeDownloadFinalizer.promoteStagedOpus(
    stagedPath: String,
    finalPath: String,
    decode: (Array<String>, () -> Boolean) -> Pair<Boolean, String> = { arguments, cancel ->
        runFFmpegArguments(arguments, cancel, timeoutAsFailure = true)
    },
    requireSingleMonoStream: Boolean = false,
    shouldCancel: () -> Boolean,
): Boolean {
    checkCancelled(shouldCancel)
    if (!isCompleteOggOpus(File(stagedPath), requireSingleMonoStream) { checkCancelled(shouldCancel) }) return false
    val (decoded, diagnostics) = decode(arrayOf(
        "-hide_banner", "-nostdin", "-loglevel", "error", "-xerror",
        "-abort_on", "empty_output_stream", "-protocol_whitelist", "file",
        "-f", "ogg", "-c:a", "opus", "-i", stagedPath,
        "-map", "0:a", "-f", "null", "-",
    ), shouldCancel)
    if (!decoded || diagnostics.isNotBlank()) return false
    checkCancelled(shouldCancel)
    return promoteStagedConversion(stagedPath, finalPath)
}

private data class OggStreamPosition(var nextPage: Int, var packetContinues: Boolean)

/** A decoder may accept EOF at an Ogg page boundary without seeing the end of the stream. */
private fun isCompleteOggOpus(
    file: File,
    requireSingleMonoStream: Boolean,
    checkCancelled: () -> Unit,
): Boolean {
    if (!file.isFile) return false
    return RandomAccessFile(file, "r").use { input ->
        val end = input.length()
        val page = ByteBuffer.allocate(27).order(ByteOrder.LITTLE_ENDIAN)
        val segments = ByteArray(255)
        val packetId = ByteArray(8)
        val seenStreams = mutableSetOf<Int>()
        val openStreams = mutableMapOf<Int, OggStreamPosition>()
        while (input.filePointer < end) {
            checkCancelled()
            if (end - input.filePointer < page.capacity()) return false
            input.readFully(page.array())
            if (String(page.array(), 0, 4, Charsets.US_ASCII) != "OggS" || page[4] != 0.toByte()) return false
            val flags = page[5].toInt() and 0xff
            val serial = page.getInt(14)
            val sequence = page.getInt(18)
            val segmentCount = page[26].toInt() and 0xff
            if (flags and 0xf8 != 0 || end - input.filePointer < segmentCount) return false
            input.readFully(segments, 0, segmentCount)
            var bodySize = 0
            var completePackets = 0
            for (index in 0 until segmentCount) {
                val segmentSize = segments[index].toInt() and 0xff
                bodySize += segmentSize
                if (segmentSize < 255) completePackets++
            }
            val pageEnd = input.filePointer + bodySize
            if (pageEnd > end) return false
            val endsWithPartialPacket = segmentCount > 0 && segments[segmentCount - 1] == 0xff.toByte()
            if (flags and 0x02 != 0) {
                // RFC 7845 sections 3 and 4 require OpusHead alone on its BOS page.
                if (flags != 0x02 || page.getLong(6) != 0L || sequence != 0 || !seenStreams.add(serial) ||
                    bodySize < 19 || completePackets != 1 || endsWithPartialPacket) return false
                input.readFully(packetId)
                if (String(packetId, Charsets.US_ASCII) != "OpusHead") return false
                if (requireSingleMonoStream) {
                    input.readUnsignedByte() // OpusHead version
                    if (seenStreams.size != 1 || input.readUnsignedByte() != 1) return false
                }
                openStreams[serial] = OggStreamPosition(nextPage = 1, packetContinues = false)
            } else {
                val position = openStreams[serial] ?: return false
                val continuation = flags and 0x01 != 0
                if (position.nextPage != sequence || continuation != (segmentCount > 0 && position.packetContinues)) {
                    return false
                }
                if (segmentCount > 0) position.packetContinues = endsWithPartialPacket
                if (flags and 0x04 != 0) {
                    if (position.packetContinues) return false
                    openStreams.remove(serial)
                } else {
                    position.nextPage++
                }
            }
            input.seek(pageEnd)
        }
        seenStreams.isNotEmpty() && openStreams.isEmpty()
    }
}

internal fun NativeDownloadFinalizer.buildOutputPath(inputPath: String, extension: String): String {
    val ext = normalizeExt(extension).ifBlank { ".tmp" }
    val file = File(inputPath)
    val base = file.nameWithoutExtension.ifBlank { "track" }
    // This is the final name. FFmpeg writes via stagedConversionPath even
    // when the source and final extensions match.
    return File(file.parentFile, "$base$ext").absolutePath
}

internal fun NativeDownloadFinalizer.desiredFileName(input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState, extension: String): String {
    val ext = normalizeExt(extension).ifBlank { normalizeExt(File(state.fileName).extension).ifBlank { ".flac" } }
    val rawName = input.result.optString("quality_variant_file_name", "")
        .ifBlank { input.result.optString("resolved_file_name", "") }
        .ifBlank { input.request.optString("saf_file_name", "") }
        .ifBlank { state.fileName }
        .ifBlank { "${trackString(input, "artistName", input.request.optString("artist_name", "Artist"))} - ${trackString(input, "name", input.request.optString("track_name", "Track"))}" }
    val knownExts = listOf(".flac", ".m4a", ".mp4", ".aac", ".mp3", ".opus", ".ogg", ".lrc")
    var base = rawName.trim()
    val lower = base.lowercase(Locale.ROOT)
    for (knownExt in knownExts) {
        if (lower.endsWith(knownExt)) {
            base = base.dropLast(knownExt.length)
            break
        }
    }
    base = base
        .replace("/", " ")
        .replace(Regex("[\\\\:*?\"<>|]"), " ")
        .trim()
        .trim('.', ' ')
        .ifBlank { "track" }
    return "$base$ext"
}

internal fun NativeDownloadFinalizer.shouldForceContainerConversion(input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState): Boolean {
    if (input.result.optBoolean("requires_container_conversion", false)) return true
    if (input.request.optBoolean("requires_container_conversion", false)) return true
    return false
}

internal fun NativeDownloadFinalizer.probePrimaryAudioCodec(path: String, shouldCancel: () -> Boolean = { false }): String {
    val result = runFFmpeg("-hide_banner -nostdin -i ${q(path)} -map 0:a:0 -frames:a 1 -f null -", shouldCancel)
    val output = result.second
    val match = Regex("Audio:\\s*([^,\\s]+)", RegexOption.IGNORE_CASE).find(output)
    return match?.groupValues?.getOrNull(1)
        ?.trim()
        ?.lowercase(Locale.ROOT)
        ?.replace('-', '_')
        .orEmpty()
}

/**
 * Returns true when the file on [path] starts with the native FLAC magic
 * bytes (`fLaC`). A file may contain a FLAC audio stream yet live inside
 * an MP4/fMP4 container; native FLAC tag writers require the raw fLaC
 * header, so detect that mismatch before skipping container conversion.
 */
internal fun NativeDownloadFinalizer.isNativeFlacFile(path: String): Boolean {
    return try {
        RandomAccessFile(path, "r").use { raf ->
            if (raf.length() < 4L) return false
            val header = ByteArray(4)
            raf.readFully(header)
            header[0] == 0x66.toByte() && // 'f'
                header[1] == 0x4C.toByte() && // 'L'
                header[2] == 0x61.toByte() && // 'a'
                header[3] == 0x43.toByte() // 'C'
        }
    } catch (e: Exception) {
        Log.w(TAG, FinalizerDiagnostics.message(FinalizerDiagnostics.Failure.FLAC_PROBE, e))
        false
    }
}
