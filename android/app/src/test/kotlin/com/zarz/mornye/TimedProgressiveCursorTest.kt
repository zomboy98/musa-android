package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test
import xyz.luan.audioplayers.source.*
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class TimedProgressiveCursorTest {
    @Test fun rangesSeekWithoutClosingSharedLease() {
        val bytes = byteArrayOf(1,2,3,4,5)
        val lease = object : TimedProgressiveLease {
            override fun knownSize() = bytes.size.toLong()
            override fun readChunk(position:Long,maxBytes:Int,timeoutMs:Int):TimedProgressiveRead {
                if(position >= bytes.size) return TimedProgressiveRead.End
                return TimedProgressiveRead.Bytes(bytes.copyOfRange(position.toInt(),minOf(bytes.size,position.toInt()+maxBytes)))
            }
        }
        val a=TimedProgressiveCursor(lease,1,2); val out=ByteArray(4)
        assertEquals(2,a.read(out,1,3)); assertArrayEquals(byteArrayOf(0,2,3,0),out)
        assertEquals(-1,a.read(out,0,1)); a.close()
        val b=TimedProgressiveCursor(lease,4,null); assertEquals(1,b.read(out,0,4)); assertEquals(5,out[0].toInt())
        assertEquals(-1,b.read(out,0,1)); b.close()
    }
    @Test fun pendingIsNotEofAndCloseRetiresAnInFlightRead() {
        val started=CountDownLatch(1); val resume=CountDownLatch(1)
        val lease=object:TimedProgressiveLease {
            override fun knownSize():Long?=null
            override fun readChunk(position:Long,maxBytes:Int,timeoutMs:Int):TimedProgressiveRead {
                assertEquals(250,timeoutMs); started.countDown(); assertTrue(resume.await(2,TimeUnit.SECONDS)); return TimedProgressiveRead.Pending
            }
        }
        val cursor=TimedProgressiveCursor(lease,0,null); val pool=Executors.newSingleThreadExecutor()
        try {
            val read=pool.submit<Boolean> { try { cursor.read(ByteArray(2),0,2); false } catch(_:IOException) { true } }
            assertTrue(started.await(2,TimeUnit.SECONDS)); cursor.close(); resume.countDown(); assertTrue(read.get(2,TimeUnit.SECONDS))
        } finally { resume.countDown(); cursor.close(); pool.shutdownNow() }
    }
    @Test fun pendingWaitsForDataInsteadOfReturningEof() {
        var calls=0
        val lease=object:TimedProgressiveLease { override fun knownSize():Long?=null; override fun readChunk(position:Long,maxBytes:Int,timeoutMs:Int):TimedProgressiveRead = if(calls++ == 0) TimedProgressiveRead.Pending else TimedProgressiveRead.Bytes(byteArrayOf(7)) }
        val out=ByteArray(1); assertEquals(1,TimedProgressiveCursor(lease,0,null).read(out,0,1)); assertEquals(7,out[0].toInt()); assertEquals(2,calls)
    }
    @Test fun emptyOrOversizedProviderBytesAreRejected() {
        for (data in listOf(byteArrayOf(),byteArrayOf(1,2,3))) {
            val lease=object:TimedProgressiveLease { override fun knownSize():Long?=null; override fun readChunk(position:Long,maxBytes:Int,timeoutMs:Int)=TimedProgressiveRead.Bytes(data) }
            try { TimedProgressiveCursor(lease,0,null).read(ByteArray(2),0,2); fail("invalid length accepted") } catch(_:IOException) { }
        }
    }
}


