package com.zarz.mornye

import android.content.Context
import android.util.Log
import com.zarz.mornye.SafDownloadHandler.normalizeExt
import com.zarz.mornye.NativeFinalizationPolicy.normalizeAudioCodec
import java.io.File
import java.util.Locale

internal fun NativeDownloadFinalizer.finalizeAutoConversion(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
) {
    // Legacy conversion settings do not authorize changing the downloaded codec.
    // The source file and measured metadata remain unchanged.

}

private fun NativeDownloadFinalizer.uniqueAutoConversionOutputPath(inputPath: String, extension: String): String {
    val source = File(inputPath)
    val requested = File(source.parentFile, "${source.nameWithoutExtension}$extension")
    if (!requested.exists()) return requested.absolutePath
    for (index in 2..Int.MAX_VALUE) {
        val candidate = File(
            source.parentFile,
            "${source.nameWithoutExtension} ($index)$extension",
        )
        if (!candidate.exists()) return candidate.absolutePath
    }
    throw IllegalStateException("could not allocate automatic conversion output")
}

internal fun NativeDownloadFinalizer.finalizeContainerConversion(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
) {
    if (outputExt(input) != ".flac") return
    val forceContainerConversion = shouldForceContainerConversion(input, state)
    // The decrypted container may still contain FLAC. Only the measured
    // stream codec can decide whether an M4A/MP4 should be preserved.
    val mayNeedContainerConversion = forceContainerConversion ||
        looksLikeM4a(state.filePath, state.fileName) ||
        isMP4ContainerFile(state.filePath) ||
        state.filePath.startsWith("content://")
    if (!mayNeedContainerConversion) return

    val localInput = materializeForFFmpeg(context, input, state)
    val deleteLocalInput = state.filePath.startsWith("content://")
    var producerUnconfirmed = false
    try {
        val codec = probePrimaryAudioCodec(localInput, shouldCancel)
        val isAlreadyNativeFlac = isNativeFlacFile(localInput)
        // Keep the original container and codec. The requested extension is
        // not permission to encode or convert a lossless stream.
        if (isAlreadyNativeFlac) {
            state.audioCodec = "flac"
        } else {
            adoptPreservedContainerExtension(state, localInput, codec)
        }

    } catch (e: FFmpegProducerUnconfirmed) {
        producerUnconfirmed = true
        throw e
    } finally {
        if (!producerUnconfirmed && deleteLocalInput) File(localInput).delete()
    }
}

/// Renames a preserved lossy/unknown stream away from its requested .flac
/// name to match its actual container (mirrors the Dart pipeline's
/// post-download rename). Local files only: legacy content:// outputs are
/// left untouched. No-op when the container cannot be identified.
private fun NativeDownloadFinalizer.adoptPreservedContainerExtension(
    state: NativeDownloadFinalizer.FinalizeState,
    localInput: String,
    codec: String,
) {
    check(!state.filePath.startsWith("content://")) {
        "Cannot safely rename preserved content URI to its actual container"
    }
    val currentFile = File(state.filePath)
    if (!currentFile.exists()) return
    if (!currentFile.name.lowercase(Locale.ROOT).endsWith(".flac")) return

    val newExt = when {
        isMP4ContainerFile(localInput) ->
            NativeFinalizationPolicy.isoBmffAudioExtension(codec)
        codec == "mp3" -> ".mp3"
        codec == "opus" -> ".opus"
        else -> throw IllegalStateException("Cannot determine preserved audio container")
    }
    val renamed = File(uniqueAutoConversionOutputPath(currentFile.path, newExt))
    check(currentFile.renameTo(renamed)) { "Failed to rename preserved container" }
    Log.i(TAG, "Preserved container renamed")
    state.filePath = renamed.absolutePath
    if (state.fileName.isNotBlank()) {
        state.fileName = renamed.name
    }
    state.audioCodec = normalizeAudioCodec(codec)
}

private fun NativeDownloadFinalizer.outputExt(input: NativeDownloadFinalizer.FinalizeInput): String {
    val safExt = input.request.optString("saf_output_ext", "")
    val ext = safExt.ifBlank { input.request.optString("output_ext", "") }
    return normalizeExt(ext.ifBlank { ".flac" })
}

private fun NativeDownloadFinalizer.looksLikeM4a(path: String, fileName: String): Boolean {
    val lowerPath = path.lowercase(Locale.ROOT)
    val lowerName = fileName.lowercase(Locale.ROOT)
    return lowerPath.endsWith(".m4a") ||
        lowerPath.endsWith(".mp4") ||
        lowerName.endsWith(".m4a") ||
        lowerName.endsWith(".mp4")
}
