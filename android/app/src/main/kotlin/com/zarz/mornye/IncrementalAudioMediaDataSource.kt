package com.zarz.mornye

import android.media.MediaDataSource

/** Experimental adapter only; callers own all producer signals and lifecycle. */
internal class IncrementalAudioMediaDataSource(
    private val reader: IncrementalAudioReader,
) : MediaDataSource() {
    override fun getSize(): Long = reader.size()
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int =
        reader.readAt(position, buffer, offset, size)
    override fun close() = reader.close()
}
