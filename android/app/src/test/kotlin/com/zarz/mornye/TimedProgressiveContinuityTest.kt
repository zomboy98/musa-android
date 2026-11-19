package com.zarz.mornye

import android.net.Uri
import androidx.media3.datasource.DataSpec
import com.mornye.backend.ProgressiveLeaseInterface
import com.mornye.backend.ProgressiveLeaseState
import com.mornye.backend.ProgressiveRead as NativeRead
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import xyz.luan.audioplayers.source.TimedProgressiveDataSource

class TimedProgressiveContinuityTest {
    private class Lease : ProgressiveLeaseInterface {
        val bytes = byteArrayOf(10, 20, 30, 40)
        @Volatile var committed = false
        @Volatile var cancelled = false
        val pending = CountDownLatch(1)
        val wake = CountDownLatch(1)
        override fun readAt(offset: ULong, maxBytes: UInt, timeoutMs: UInt): NativeRead {
            if (cancelled) throw IOException("cancelled")
            val available = if (committed) bytes.size else 2
            if (offset.toInt() < available) return NativeRead.Bytes(bytes.copyOfRange(offset.toInt(), minOf(available, offset.toInt() + maxBytes.toInt())))
            if (committed) return NativeRead.End
            pending.countDown(); wake.await(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            if (cancelled) throw IOException("cancelled")
            return NativeRead.Pending
        }
        override fun size(): ULong? = if (committed) bytes.size.toULong() else null
        override fun waitTerminal(timeoutMs: UInt) = if (committed) ProgressiveLeaseState.COMMITTED else ProgressiveLeaseState.PENDING
        override fun cancelRead() { cancelled = true; wake.countDown() }
    }
    private fun spec(position: Long = 0) = DataSpec.Builder().setUri(Uri.parse("musa-progressive://lease")).setPosition(position).build()

    @Test fun sameDataSourceReadsAfterCommitAndReopensForSeekWithoutRevokingLease() {
        val native = Lease(); val lease = UniffiLeaseAdapter(native); val source = TimedProgressiveDataSource(lease)
        val io = Executors.newSingleThreadExecutor(); val buffer = ByteArray(2)
        try {
            assertEquals(-1L, source.open(spec())); assertEquals(2, source.read(buffer, 0, 2)); assertArrayEquals(byteArrayOf(10, 20), buffer)
            val blocked = io.submit<Int> { source.read(buffer, 0, 2) }
            assertTrue(native.pending.await(1, TimeUnit.SECONDS)); assertFalse(blocked.isDone)
            native.committed = true; native.wake.countDown()
            assertEquals(2, blocked.get(1, TimeUnit.SECONDS).toInt()); assertArrayEquals(byteArrayOf(30, 40), buffer)
            assertEquals(ProgressiveTerminal.Committed, lease.terminal(0)); assertEquals(-1, source.read(buffer, 0, 2))
            source.close(); assertFalse(native.cancelled)
            assertEquals(3L, source.open(spec(1))); assertEquals(2, source.read(buffer, 0, 2)); assertArrayEquals(byteArrayOf(20, 30), buffer)
            source.close(); assertFalse(native.cancelled); lease.close(); assertTrue(native.cancelled)
        } finally { native.wake.countDown(); source.close(); lease.close(); io.shutdownNow() }
    }

    @Test fun closingPendingCursorWakesWithoutConvertingPendingToEof() {
        val native = Lease(); val lease = UniffiLeaseAdapter(native); val source = TimedProgressiveDataSource(lease); val io = Executors.newSingleThreadExecutor()
        try {
            source.open(spec(2)); val blocked = io.submit<Boolean> { try { source.read(ByteArray(1), 0, 1); false } catch (_: IOException) { true } }
            assertTrue(native.pending.await(1, TimeUnit.SECONDS)); assertFalse(blocked.isDone)
            source.close(); native.wake.countDown(); assertTrue(blocked.get(1, TimeUnit.SECONDS)); assertFalse(native.cancelled)
            lease.close(); assertTrue(native.cancelled)
        } finally { native.wake.countDown(); source.close(); lease.close(); io.shutdownNow() }
    }

    @Test fun ownerCancellationInterruptsPendingReadWithoutEof() {
        val native = Lease(); val lease = UniffiLeaseAdapter(native); val source = TimedProgressiveDataSource(lease); val io = Executors.newSingleThreadExecutor()
        try {
            source.open(spec(2)); val blocked = io.submit<Boolean> { try { source.read(ByteArray(1), 0, 1); false } catch (_: IOException) { true } }
            assertTrue(native.pending.await(1, TimeUnit.SECONDS)); assertFalse(blocked.isDone)
            lease.close(); assertTrue(blocked.get(1, TimeUnit.SECONDS)); assertTrue(native.cancelled)
        } finally { native.wake.countDown(); source.close(); lease.close(); io.shutdownNow() }
    }
}
