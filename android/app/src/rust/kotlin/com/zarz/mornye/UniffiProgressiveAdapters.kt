package com.zarz.mornye

import com.mornye.backend.*
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveRead

// Experimental adapter; no production caller enables it.
internal class UniffiLeaseAdapter(private val native: ProgressiveLeaseInterface) : ProgressiveAudioLease, TimedProgressiveLease {
    private val closed = AtomicBoolean(false)
    override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead {
        require(position >= 0 && maxBytes in 1..65536 && timeoutMs in 0..1000)
        return try {
            when (val result = native.readAt(position.toULong(), maxBytes.toUInt(), timeoutMs.toUInt())) {
                is com.mornye.backend.ProgressiveRead.Bytes -> ProgressiveRead.Data(result.bytes)
                com.mornye.backend.ProgressiveRead.Pending -> ProgressiveRead.Pending
                com.mornye.backend.ProgressiveRead.End -> ProgressiveRead.End
            }
        } catch (_: ProgressiveReadException) { throw IOException("Progressive read failed") }
    }
    override fun size(): Long? = try {
        native.size()?.let { if (it > Long.MAX_VALUE.toULong()) throw IOException("Invalid progressive size") else it.toLong() }
    } catch (_: ProgressiveReadException) { throw IOException("Progressive size unavailable") }
    override fun readChunk(position: Long, maxBytes: Int, timeoutMs: Int): TimedProgressiveRead =
        when (val result = readAt(position, maxBytes, timeoutMs)) {
            is ProgressiveRead.Data -> TimedProgressiveRead.Bytes(result.bytes)
            ProgressiveRead.Pending -> TimedProgressiveRead.Pending
            ProgressiveRead.End -> TimedProgressiveRead.End
        }
    override fun knownSize(): Long? = size()
    override fun close() {
        if (closed.compareAndSet(false, true)) try { native.cancelRead() } finally { (native as? Disposable)?.destroy() }
    }
    fun terminal(timeoutMs: Int): ProgressiveTerminal = try {
        when (native.waitTerminal(timeoutMs.toUInt())) {
            ProgressiveLeaseState.PENDING -> ProgressiveTerminal.Pending
            ProgressiveLeaseState.COMMITTED -> ProgressiveTerminal.Committed
            ProgressiveLeaseState.INVALIDATED -> ProgressiveTerminal.Invalidated
            ProgressiveLeaseState.ABORTED -> ProgressiveTerminal.Aborted
        }
    } catch (_: ProgressiveReadException) { throw IOException("Progressive terminal unavailable") }
}

internal class UniffiSessionAdapter(
    private val native: ProgressiveSessionInterface,
    private val runDownload: () -> String,
    private val isSuccess: (String) -> Boolean,
    private val onResult: (String) -> Unit = {},
) : ProgressiveControllerSession {
    private val closed = AtomicBoolean(false)
    override fun download() {
        val result = try { runDownload() } catch (_: Exception) { throw IOException("Progressive download failed") }
        if (closed.get() || !isSuccess(result)) throw IOException("Progressive download failed")
        onResult(result)
    }
    override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate {
        require(afterSequence >= 0 && timeoutMs in 0..1000)
        return try {
            when (val next = native.nextLease(afterSequence.toULong(), timeoutMs.toUInt())) {
                is ProgressiveNext.Available -> {
                    if (next.sequence > Long.MAX_VALUE.toULong()) { next.lease.cancelRead(); next.lease.destroy(); throw IOException("Invalid sequence") }
                    ProgressiveCandidate.Available(next.sequence.toLong(), UniffiLeaseAdapter(next.lease))
                }
                ProgressiveNext.Pending -> ProgressiveCandidate.Pending
                ProgressiveNext.Finished -> ProgressiveCandidate.Finished
                ProgressiveNext.Closed -> ProgressiveCandidate.Closed
            }
        } catch (_: ProgressiveReadException) { throw IOException("Progressive session unavailable") }
    }
    override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int): ProgressiveTerminal =
        (lease as? UniffiLeaseAdapter ?: throw IOException("Invalid lease")).terminal(timeoutMs)
    override fun close() {
        if (closed.compareAndSet(false, true)) try { native.cancelSession() } finally { (native as? Disposable)?.destroy() }
    }
}


