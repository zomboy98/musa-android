package com.zarz.mornye

import android.media.MediaDataSource
import android.media.MediaPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Observes source ownership at the Android framework boundary. The callback
 * source exposes close(), which a path-based source does not expose to the app.
 */
@RunWith(AndroidJUnit4::class)
class AndroidMediaSourceDetachTest {
    @Test
    fun stoppedMediaPlayerRetainsSourceUntilRelease() {
        val source = ObservableWavSource()
        val player = MediaPlayer()
        try {
            player.setDataSource(source)
            player.prepare()
            player.stop()

            assertEquals("stop retains the source for another prepare", 1L, source.closed.count)
            player.prepare()
            assertTrue("the stopped source can be prepared again", player.duration > 0)
            assertEquals("reprepare retains the source until release", 1L, source.closed.count)
        } finally {
            player.release()
        }

        assertTrue("release closes the retained source", source.closed.await(5, TimeUnit.SECONDS))
    }

    private class ObservableWavSource : MediaDataSource() {
        val closed = CountDownLatch(1)
        private val bytes = ByteBuffer.allocate(44 + PCM_SIZE).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt(36 + PCM_SIZE)
            put("WAVEfmt ".toByteArray(Charsets.US_ASCII))
            putInt(16)
            putShort(1)
            putShort(1)
            putInt(SAMPLE_RATE)
            putInt(SAMPLE_RATE * 2)
            putShort(2)
            putShort(16)
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(PCM_SIZE)
        }.array()

        override fun getSize(): Long = bytes.size.toLong()

        override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
            check(closed.count != 0L) { "MediaPlayer read from a closed source" }
            if (size == 0) return 0
            if (position >= bytes.size) return -1
            val start = position.toInt()
            val count = minOf(size, bytes.size - start)
            bytes.copyInto(buffer, offset, start, start + count)
            return count
        }

        override fun close() {
            closed.countDown()
        }

        private companion object {
            const val SAMPLE_RATE = 8_000
            const val PCM_SIZE = SAMPLE_RATE * 2
        }
    }
}
