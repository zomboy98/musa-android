package com.zarz.mornye

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class ProgressiveStartupHandoffTest {
    @Test(timeout = 10000) fun closeDuringStartupDisposesLateRealControllerAndCancelsItsSession() {
        val io = Executors.newFixedThreadPool(3)
        val reserved = CountDownLatch(1)
        val publish = CountDownLatch(1)
        val downloadStarted = CountDownLatch(1)
        val sessionClosed = CountDownLatch(1)
        val disposed = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val startupError = AtomicReference<Throwable>()
        val session = object : ProgressiveControllerSession {
            override fun download() { downloadStarted.countDown(); check(sessionClosed.await(5, TimeUnit.SECONDS)) }
            override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate {
                sessionClosed.await(10, TimeUnit.MILLISECONDS)
                return if (sessionClosed.count == 0L) ProgressiveCandidate.Closed else ProgressiveCandidate.Pending
            }
            override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int) = ProgressiveTerminal.Pending
            override fun close() { closeCalls.incrementAndGet(); sessionClosed.countDown() }
        }
        val handoff = ProgressiveStartupHandoff<ProgressiveDeckController> { controller, done ->
            controller.closeAndNotify { ok -> done(ok); disposed.countDown() }
        }
        val starter = Thread {
            try {
                val controller = ProgressiveDeckController(io, { session }, object : ProgressiveControllerDeck {
                    override fun open(lease: ProgressiveAudioLease) = error("No candidate expected")
                    override fun discard() {}
                }, {}, downloadWaitMs = 500L)
                controller.start()
                check(downloadStarted.await(3, TimeUnit.SECONDS))
                reserved.countDown()
                check(publish.await(3, TimeUnit.SECONDS))
                handoff.complete(controller)
            } catch (t: Throwable) { startupError.set(t); reserved.countDown() }
        }
        try {
            starter.start()
            assertTrue(reserved.await(4, TimeUnit.SECONDS))
            startupError.get()?.let { throw it }
            val cancelReplies = mutableListOf<Boolean>()
            // Exactly the old failure window: controller exists but is not published.
            handoff.close { cancelReplies.add(it) }
            assertEquals(listOf(false), cancelReplies)
            assertEquals(1L, disposed.count)
            publish.countDown()
            assertTrue(disposed.await(3, TimeUnit.SECONDS))
            starter.join(1000)
            startupError.get()?.let { throw it }
            assertFalse(starter.isAlive)
            assertEquals(0L, sessionClosed.count)
            assertEquals(1, closeCalls.get())
            assertEquals("No second, contradictory cancellation reply", listOf(false), cancelReplies)
        } finally {
            publish.countDown()
            sessionClosed.countDown()
            starter.join(1000)
            io.shutdownNow()
            assertTrue(io.awaitTermination(2, TimeUnit.SECONDS))
        }
    }

    @Test(timeout = 5000) fun closeCannotWaitForeverForUnpublishedStartup() {
        val calls = AtomicInteger()
        val handoff = ProgressiveStartupHandoff<Any> { _, done -> calls.incrementAndGet(); done(true) }
        val reply = AtomicReference<Boolean>()
        val returned = CountDownLatch(1)
        val closer = Thread { handoff.close { reply.set(it) }; returned.countDown() }
        closer.start()
        try {
            assertTrue(returned.await(1, TimeUnit.SECONDS))
            assertEquals(false, reply.get())
            assertEquals(0, calls.get())
            // The factory may never publish. Cancellation must not claim success.
        } finally { closer.join(1000) }
    }

    @Test fun exceptionBeforePublicationStillDisposesPartialResource() {
        val closes = AtomicInteger()
        val handoff = ProgressiveStartupHandoff<AutoCloseable> { resource, done -> resource.close(); done(true) }
        val deck = AutoCloseable { closes.incrementAndGet() }
        val replies = mutableListOf<Boolean>()
        try {
            throw IllegalStateException("synthetic startup failed after reserving deck")
        } catch (_: IllegalStateException) {
            handoff.close { replies.add(it) }
        } finally { handoff.complete(deck) }
        assertEquals(1, closes.get())
        assertEquals(listOf(false), replies)
        handoff.close { replies.add(it) }
        assertEquals(listOf(false, false), replies)
        assertEquals(1, closes.get())
    }

    @Test fun publishedCancelWaitsForRealDisposalAndRetainsFailure() {
        val closes = AtomicInteger()
        var acknowledge: ((Boolean) -> Unit)? = null
        val handoff = ProgressiveStartupHandoff<Any> { _, done -> closes.incrementAndGet(); acknowledge = done }
        handoff.complete(Any())
        val replies = mutableListOf<Boolean>()
        handoff.close { replies.add(it) }
        handoff.close { replies.add(it) }
        assertTrue(replies.isEmpty())
        assertEquals(1, closes.get())
        acknowledge!!(false)
        assertEquals(listOf(false, false), replies)
        handoff.close { replies.add(it) }
        assertEquals(listOf(false, false, false), replies)
        assertEquals(1, closes.get())
    }

    @Test(timeout = 10000) fun concurrentPublicationAndCancelDisposeExactlyOnce() {
        repeat(50) {
            val closes = AtomicInteger()
            val notifications = AtomicInteger()
            val barrier = CountDownLatch(1)
            val finished = CountDownLatch(2)
            val failure = AtomicReference<Throwable>()
            val handoff = ProgressiveStartupHandoff<Any> { _, done -> closes.incrementAndGet(); done(true) }
            val workers = listOf(
                Thread {
                    try { check(barrier.await(2, TimeUnit.SECONDS)); handoff.complete(Any()) }
                    catch (t: Throwable) { failure.set(t) } finally { finished.countDown() }
                },
                Thread {
                    try { check(barrier.await(2, TimeUnit.SECONDS)); handoff.close { notifications.incrementAndGet() } }
                    catch (t: Throwable) { failure.set(t) } finally { finished.countDown() }
                })
            try {
                workers.forEach { it.start() }
                barrier.countDown()
                assertTrue(finished.await(3, TimeUnit.SECONDS))
                failure.get()?.let { throw it }
                assertEquals(1, closes.get())
                assertEquals(1, notifications.get())
            } finally { barrier.countDown(); workers.forEach { it.join(1000) } }
        }
    }

    @Test(timeout = 6000) fun disposerAndReplyCanReenterFromAnotherThreadWithoutMonitorDeadlock() {
        lateinit var handoff: ProgressiveStartupHandoff<Any>
        fun reenter() {
            val returned = CountDownLatch(1)
            val thread = Thread { handoff.close {}; returned.countDown() }.apply { start() }
            try { assertTrue(returned.await(1, TimeUnit.SECONDS)) }
            finally { thread.join(1000) }
        }
        handoff = ProgressiveStartupHandoff { _, done -> reenter(); done(true) }
        handoff.complete(Any())
        var replied = false
        handoff.close { assertTrue(it); reenter(); replied = true }
        assertTrue(replied)
    }

    @Test fun throwingDisposerReportsFailureOnce() {
        val closes = AtomicInteger()
        val handoff = ProgressiveStartupHandoff<Any> { _, _ ->
            closes.incrementAndGet(); error("synthetic close failure")
        }
        handoff.complete(Any())
        val replies = mutableListOf<Boolean>()
        handoff.close { replies.add(it) }
        handoff.close { replies.add(it) }
        assertEquals(listOf(false, false), replies)
        assertEquals(1, closes.get())
    }
}
