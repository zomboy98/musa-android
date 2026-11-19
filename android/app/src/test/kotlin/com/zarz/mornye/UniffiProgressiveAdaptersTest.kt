package com.zarz.mornye
import com.mornye.backend.*
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class UniffiAdaptersTest {
    private class Lease : ProgressiveLeaseInterface {
        var canceled = false
        var result: com.mornye.backend.ProgressiveRead = com.mornye.backend.ProgressiveRead.Pending
        var currentSize: ULong? = null
        override fun readAt(offset: ULong, maxBytes: UInt, timeoutMs: UInt) = result
        override fun size() = currentSize
        override fun waitTerminal(timeoutMs: UInt) = ProgressiveLeaseState.INVALIDATED
        override fun cancelRead() { canceled = true }
    }
    private class Session : ProgressiveSessionInterface {
        var canceled = false
        override fun nextLease(afterSequence: ULong, timeoutMs: UInt): ProgressiveNext = ProgressiveNext.Pending
        override fun cancelSession() { canceled = true }
    }
    @Test fun leaseMapsReadSizeAndCancel() {
        val native = Lease(); val adapter = UniffiLeaseAdapter(native)
        assertSame(ProgressiveRead.Pending, adapter.readAt(42, 3, 1000))
        native.result = com.mornye.backend.ProgressiveRead.Bytes(byteArrayOf(4,5))
        assertArrayEquals(byteArrayOf(4,5), (adapter.readAt(1, 2, 1) as ProgressiveRead.Data).bytes)
        native.result = com.mornye.backend.ProgressiveRead.End
        assertSame(ProgressiveRead.End, adapter.readAt(3, 1, 1))
        assertNull(adapter.size()); native.currentSize = 99u; assertEquals(99L, adapter.size())
        assertEquals(ProgressiveTerminal.Invalidated, adapter.terminal(1000)); adapter.close(); assertTrue(native.canceled)
    }
    @Test fun timedBridgePreservesPendingBytesAndEof() {
        val native=Lease(); val adapter=UniffiLeaseAdapter(native)
        assertSame(xyz.luan.audioplayers.source.TimedProgressiveRead.Pending,adapter.readChunk(7,2,250))
        native.result=com.mornye.backend.ProgressiveRead.Bytes(byteArrayOf(4,5))
        assertArrayEquals(byteArrayOf(4,5),(adapter.readChunk(7,2,250) as xyz.luan.audioplayers.source.TimedProgressiveRead.Bytes).value)
        native.result=com.mornye.backend.ProgressiveRead.End
        assertSame(xyz.luan.audioplayers.source.TimedProgressiveRead.End,adapter.readChunk(9,2,250))
        assertNull(adapter.knownSize()); native.currentSize=9u; assertEquals(9L,adapter.knownSize())
        adapter.close(); assertTrue(native.canceled)
    }
    @Test fun oversizedLengthAndFailedJsonAreErrors() {
        val native = Lease(); native.currentSize = ULong.MAX_VALUE
        try { UniffiLeaseAdapter(native).size(); fail() } catch (_: IOException) { }
        val session = Session(); val adapter = UniffiSessionAdapter(session, { "failure" }, { false })
        try { adapter.download(); fail() } catch (_: IOException) { }
        assertSame(ProgressiveCandidate.Pending, adapter.nextLease(0, 1000)); adapter.close(); assertTrue(session.canceled)
    }
    @Test fun successfulDownloadProducesExactlyOneFinalResult() {
        val session = Session(); val outputs = mutableListOf<String>()
        val adapter = UniffiSessionAdapter(session, { "result" }, { it == "result" }, { outputs.add(it) })
        adapter.download()
        assertEquals(listOf("result"), outputs)
        adapter.close()
        try { adapter.download(); fail() } catch (_: IOException) { }
        assertEquals(1, outputs.size)
    }
}

