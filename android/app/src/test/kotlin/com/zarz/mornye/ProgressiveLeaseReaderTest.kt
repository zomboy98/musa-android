package com.zarz.mornye

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ProgressiveLeaseReaderTest {
    @Test fun pendingRetriesSamePositionAndCopiesOnlyReturnedBytes() {
        val calls = mutableListOf<Pair<Long, Int>>()
        val lease = object : ProgressiveAudioLease {
            override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead {
                calls.add(position to maxBytes)
                return if (calls.size == 1) ProgressiveRead.Pending else ProgressiveRead.Data(byteArrayOf(4, 5))
            }
            override fun size(): Long? = null
            override fun close() {}
        }
        val reader = ProgressiveLeaseReader(lease)
        val buffer = ByteArray(8)
        assertEquals(2, reader.readAt(23, buffer, 3, 5))
        assertEquals(listOf(23L to 5, 23L to 5), calls)
        assertArrayEquals(byteArrayOf(0, 0, 0, 4, 5, 0, 0, 0), buffer)
        assertEquals(-1L, reader.size())
    }

    @Test fun limitsReadAndOnlyEndReturnsEof() {
        var requested = 0
        val lease = object : ProgressiveAudioLease {
            override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead {
                requested = maxBytes
                return ProgressiveRead.End
            }
            override fun size(): Long? = 42
            override fun close() {}
        }
        val reader = ProgressiveLeaseReader(lease)
        assertEquals(-1, reader.readAt(42, ByteArray(100000), 0, 100000))
        assertEquals(65536, requested)
        assertEquals(42L, reader.size())
    }

    @Test fun closeWakesBlockedReadAndDoesNotBecomeEof() {
        val entered = CountDownLatch(1)
        val wake = CountDownLatch(1)
        val lease = object : ProgressiveAudioLease {
            override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead {
                entered.countDown()
                wake.await(2, TimeUnit.SECONDS)
                throw IOException("cancelled")
            }
            override fun size(): Long? = null
            override fun close() { wake.countDown() }
        }
        val reader = ProgressiveLeaseReader(lease)
        var failed = false
        val thread = Thread { try { reader.readAt(0, ByteArray(1), 0, 1) } catch (_: IOException) { failed = true } }
        thread.start()
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        reader.close()
        thread.join(2000)
        assertFalse(thread.isAlive)
        assertTrue(failed)
    }

    @Test fun invalidationAndMalformedDataAreErrors() {
        for (malformed in listOf(false, true)) {
            val lease = object : ProgressiveAudioLease {
                override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead {
                    if (!malformed) throw IOException("invalidated")
                    return ProgressiveRead.Data(byteArrayOf())
                }
                override fun size(): Long? = null
                override fun close() {}
            }
            try {
                ProgressiveLeaseReader(lease).readAt(0, ByteArray(1), 0, 1)
                fail("expected IOException")
            } catch (_: IOException) { }
        }
    }

    @Test fun positionsAreIndependentAndCloseIsIdempotent() {
        val positions = mutableListOf<Long>()
        var closes = 0
        val lease = object : ProgressiveAudioLease {
            override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int): ProgressiveRead {
                positions.add(position)
                assertEquals(1000, timeoutMs)
                return ProgressiveRead.Data(byteArrayOf(position.toByte()))
            }
            override fun size(): Long? = null
            override fun close() { closes++ }
        }
        val reader = ProgressiveLeaseReader(lease)
        assertEquals(1, reader.readAt(100, ByteArray(1), 0, 1))
        assertEquals(1, reader.readAt(3, ByteArray(1), 0, 1))
        assertEquals(0, reader.readAt(3, ByteArray(1), 0, 0))
        assertEquals(listOf(100L, 3L), positions)
        reader.close()
        reader.close()
        assertEquals(1, closes)
        try {
            reader.readAt(0, ByteArray(1), 0, 1)
            fail("closed read must fail")
        } catch (_: IOException) { }
    }
}
