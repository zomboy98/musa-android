package com.zarz.mornye

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/** Experimental capability contract; implementations must wake blocked reads on close. */
internal interface ProgressiveAudioLease {
    @Throws(IOException::class)
    fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead
    @Throws(IOException::class)
    fun size(): Long?
    fun close()
}

internal sealed class ProgressiveRead {
    class Data(val bytes: ByteArray) : ProgressiveRead()
    data object Pending : ProgressiveRead()
    data object End : ProgressiveRead()
}

/** No paths or producer state are exposed; the lease owns generation and EOF semantics. */
internal class ProgressiveLeaseReader(private val lease: ProgressiveAudioLease) {
    private val closed = AtomicBoolean(false)

    @Throws(IOException::class)
    fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        require(position >= 0 && offset >= 0 && size >= 0 && offset <= buffer.size && size <= buffer.size - offset)
        if (closed.get()) throw IOException("Progressive lease closed")
        if (size == 0) return 0
        val limit = minOf(size, 65536)
        while (true) {
            val result = lease.readAt(position, limit, 1000)
            if (closed.get()) throw IOException("Progressive lease closed")
            when (result) {
                ProgressiveRead.Pending -> continue
                ProgressiveRead.End -> return -1
                is ProgressiveRead.Data -> {
                    if (result.bytes.isEmpty() || result.bytes.size > limit) throw IOException("Invalid progressive read length")
                    result.bytes.copyInto(buffer, offset)
                    return result.bytes.size
                }
            }
        }
    }

    @Throws(IOException::class)
    fun size(): Long {
        if (closed.get()) throw IOException("Progressive lease closed")
        return lease.size()?.also { if (it < 0) throw IOException("Invalid progressive size") } ?: -1
    }

    fun close() {
        if (closed.compareAndSet(false, true)) lease.close()
    }
}
