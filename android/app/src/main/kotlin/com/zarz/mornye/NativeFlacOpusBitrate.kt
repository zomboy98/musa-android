package com.zarz.mornye

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

internal fun nativeFlacOpusBitrateKbps(localPath: String, requestedKbps: Int): Int {
    if (requestedKbps != 320 || localPath.startsWith("content://")) return requestedKbps
    val source = File(localPath)
    if (!source.isFile) return requestedKbps

    // Native FLAC carries a single audio stream. Its first metadata block must
    // be the 34-byte STREAMINFO, even when later blocks contain cover art.
    val mono = try {
        RandomAccessFile(source, "r").use { file ->
            if (file.readInt() != 0x664C6143 || file.readInt() and 0x7FFFFFFF != 34) {
                return@use false
            }
            val streamInfo = ByteArray(34)
            file.readFully(streamInfo)
            val minBlockSize = ((streamInfo[0].toInt() and 0xFF) shl 8) or
                (streamInfo[1].toInt() and 0xFF)
            val maxBlockSize = ((streamInfo[2].toInt() and 0xFF) shl 8) or
                (streamInfo[3].toInt() and 0xFF)
            val audioProperties = streamInfo[12].toInt() and 0xFF
            val sampleRate = ((streamInfo[10].toInt() and 0xFF) shl 12) or
                ((streamInfo[11].toInt() and 0xFF) shl 4) or (audioProperties shr 4)
            val channels = ((audioProperties shr 1) and 7) + 1
            val bitDepth = ((audioProperties and 1) shl 4) +
                ((streamInfo[13].toInt() and 0xFF) shr 4) + 1
            minBlockSize >= 16 && maxBlockSize >= minBlockSize &&
                sampleRate in 1..655350 && bitDepth in 4..32 && channels == 1
        }
    } catch (_: IOException) {
        false
    }
    return if (mono) 256 else requestedKbps
}
