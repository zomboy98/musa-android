package xyz.luan.audioplayers.source

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/** A lease remains owned by the attempt. Closing a cursor does not close it. */
interface TimedProgressiveLease {
    fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead
    fun knownSize(): Long?
}
sealed class TimedProgressiveRead {
    class Bytes(val value: ByteArray) : TimedProgressiveRead()
    data object Pending : TimedProgressiveRead()
    data object End : TimedProgressiveRead()
}

/** One Media3 open/range. Timed reads let a close retire this cursor even on seek. */
class TimedProgressiveCursor(
    private val lease: TimedProgressiveLease,
    position: Long,
    length: Long?,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private var position = position
    private var remaining = length

    init { require(position >= 0 && (length == null || length >= 0)) }

    fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        require(offset >= 0 && length >= 0 && offset <= buffer.size && length <= buffer.size - offset)
        if (closed.get()) throw IOException("Progressive cursor closed")
        if (length == 0) return 0
        while (true) {
            if (closed.get()) throw IOException("Progressive cursor closed")
            val available = remaining
            if (available == 0L) return -1
            val count = minOf(length.toLong(), available ?: Long.MAX_VALUE, 65536L).toInt()
            when (val result = lease.readChunk(position, count, 250)) {
                TimedProgressiveRead.Pending -> continue
                TimedProgressiveRead.End -> {
                    if (closed.get()) throw IOException("Progressive cursor closed")
                    return -1
                }
                is TimedProgressiveRead.Bytes -> {
                    if (closed.get()) throw IOException("Progressive cursor closed")
                    if (result.value.isEmpty() || result.value.size > count || position > Long.MAX_VALUE - result.value.size)
                        throw IOException("Invalid progressive read")
                    result.value.copyInto(buffer, offset)
                    position += result.value.size
                    remaining = available?.minus(result.value.size)
                    return result.value.size
                }
            }
        }
    }
    override fun close() { closed.set(true) }
}

