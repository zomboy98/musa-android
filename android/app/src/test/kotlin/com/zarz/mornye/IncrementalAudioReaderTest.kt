package com.zarz.mornye

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class IncrementalAudioReaderTest {
    private fun fixture(block: (File, IncrementalAudioReader) -> Unit) {
        val dir = Files.createTempDirectory("incremental-audio-").toFile()
        val file = File(dir, "track.partial").apply { writeBytes(byteArrayOf()) }
        val reader = IncrementalAudioReader(file, 4)
        try { block(file, reader) } finally { reader.close(); dir.deleteRecursively() }
    }

    @Test fun waitsForBytesAndForCommitBeforeEof() = fixture { file, reader ->
        val executor = Executors.newSingleThreadExecutor()
        try {
            val target = ByteArray(3)
            val started = CountDownLatch(1)
            val pending = executor.submit<Int> { started.countDown(); reader.readAt(0, target, 0, 3) }
            assertEquals(true, started.await(2, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { pending.get(100, TimeUnit.MILLISECONDS) }
            file.appendBytes(byteArrayOf(1, 2, 3))
            reader.available(4, 3)
            assertEquals(3, pending.get(2, TimeUnit.SECONDS))
            assertArrayEquals(byteArrayOf(1, 2, 3), target)
            val eofStarted = CountDownLatch(1)
            val eof = executor.submit<Int> { eofStarted.countDown(); reader.readAt(3, target, 0, 1) }
            assertEquals(true, eofStarted.await(2, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { eof.get(100, TimeUnit.MILLISECONDS) }
            reader.commit(4, 3)
            assertEquals(-1, eof.get(2, TimeUnit.SECONDS))
            assertEquals(3L, reader.size())
        } finally { executor.shutdownNow() }
    }

    @Test fun futureSeekWaitsAndReadsOnlyPublishedPrefix() = fixture { file, reader ->
        file.writeBytes(byteArrayOf(10, 11, 12, 13, 14))
        reader.available(4, 2)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val target = ByteArray(5)
            val started = CountDownLatch(1)
            val pending = executor.submit<Int> { started.countDown(); reader.readAt(3, target, 1, 4) }
            assertEquals(true, started.await(2, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { pending.get(100, TimeUnit.MILLISECONDS) }
            reader.available(4, 5)
            assertEquals(2, pending.get(2, TimeUnit.SECONDS))
            assertArrayEquals(byteArrayOf(0, 13, 14, 0, 0), target)
        } finally { executor.shutdownNow() }
    }

    @Test fun abortAndInvalidationWakeWaitersAndRejectOldGeneration() = fixture { _, reader ->
        val executor = Executors.newSingleThreadExecutor()
        try {
            val started = CountDownLatch(1)
            val pending = executor.submit<Boolean> {
                started.countDown()
                try { reader.readAt(0, ByteArray(1), 0, 1); false } catch (_: IOException) { true }
            }
            assertEquals(true, started.await(2, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { pending.get(100, TimeUnit.MILLISECONDS) }
            reader.invalidate(4)
            assertEquals(true, pending.get(2, TimeUnit.SECONDS))
            assertThrows(IOException::class.java) { reader.available(4, 1) }
            assertThrows(IOException::class.java) { reader.available(5, 1) }
        } finally { executor.shutdownNow() }
    }

    @Test fun cancellationAndCloseWakeReaders() {
        for (close in listOf(false, true)) fixture { _, reader ->
            val executor = Executors.newSingleThreadExecutor()
            try {
                val started = CountDownLatch(1)
                val pending = executor.submit<Boolean> {
                    started.countDown()
                    try { reader.readAt(0, ByteArray(1), 0, 1); false } catch (_: IOException) { true }
                }
                assertEquals(true, started.await(2, TimeUnit.SECONDS))
                assertThrows(TimeoutException::class.java) { pending.get(100, TimeUnit.MILLISECONDS) }
                if (close) reader.close() else reader.abort(4)
                assertEquals(true, pending.get(2, TimeUnit.SECONDS))
            } finally { executor.shutdownNow() }
        }
    }

    @Test fun rejectsNonMonotonicOrUnwrittenPrefix() = fixture { file, reader ->
        file.writeBytes(byteArrayOf(1, 2))
        reader.available(4, 2)
        assertThrows(IOException::class.java) { reader.available(4, 1) }
        assertThrows(IOException::class.java) { reader.available(4, 3) }
        assertThrows(IOException::class.java) { reader.commit(4, 3) }
        assertEquals(-1L, reader.size())
    }
}
