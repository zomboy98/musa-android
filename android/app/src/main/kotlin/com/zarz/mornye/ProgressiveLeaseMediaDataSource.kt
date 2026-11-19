package com.zarz.mornye

import android.media.MediaDataSource

/** Experimental adapter; not registered with the player or production channels. */
internal class ProgressiveLeaseMediaDataSource(lease: ProgressiveAudioLease) : MediaDataSource() {
    private val reader = ProgressiveLeaseReader(lease)
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int =
        reader.readAt(position, buffer, offset, size)
    override fun getSize(): Long = reader.size()
    override fun close() = reader.close()
}
