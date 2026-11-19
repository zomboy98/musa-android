package com.zarz.mornye

import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ProgressiveDeckControllerTest {
    private class Queue : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.add(command) }
        fun runNext() { tasks.removeFirst().run() }
    }
    private class Lease : ProgressiveAudioLease {
        var closed = false
        override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int) = ProgressiveRead.End
        override fun size(): Long? = null
        override fun close() { closed = true }
    }
    private class Session : ProgressiveControllerSession {
        val lease = Lease()
        var available = true
        var downloadFails = false
        var terminal = ProgressiveTerminal.Committed
        @Volatile var closed = false
        override fun download() { if (downloadFails) throw IllegalStateException("download failed") }
        override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate =
            if (available) ProgressiveCandidate.Available(1, lease) else ProgressiveCandidate.Finished
        override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int) = terminal
        override fun close() { closed = true; lease.close() }
    }
    private class Deck : ProgressiveControllerDeck {
        var starts = 0
        var stops = 0
        override fun open(lease: ProgressiveAudioLease) { starts++ }
        override fun discard() { stops++ }
    }
    @Test fun unavailableFallsBackWithoutOpeningDeck() {
        val queue = Queue(); val session = Session().apply { available = false }; val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(0, deck.starts); assertEquals(1, fallback); assertTrue(session.closed)
    }
    @Test fun invalidationDiscardsBeforeFallback() {
        val queue = Queue(); val session = Session().apply { terminal = ProgressiveTerminal.Invalidated }; val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { assertEquals(1, deck.stops); fallback++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(1, deck.starts); assertEquals(1, fallback); assertTrue(session.closed)
    }
    @Test fun closeBeforeWorkersPreventsStartAndFallback() {
        val queue = Queue(); val session = Session(); val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext(); controller.close(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(0, deck.starts); assertEquals(0, fallback); assertTrue(session.closed)
    }
    @Test fun committedIsNotFallbackAndReadErrorAfterStartDoesNotPretendEof() {
        val queue = Queue(); val session = Session(); val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(1, deck.starts); assertEquals(0, fallback)
        controller.close(); queue.runNext(); assertEquals(1, deck.stops)
    }
    @Test fun abortedAfterStartDiscardsAndFallsBackAfterProducerExit() {
        val queue = Queue(); val session = Session().apply { terminal = ProgressiveTerminal.Aborted }; val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(1, deck.starts); assertEquals(1, deck.stops)
        assertEquals(1, fallback); assertTrue(session.closed)
    }
    @Test fun sourceAcceptanceIsSeparateFromPlaybackAndFallback() {
        val queue = Queue(); val session = Session(); val deck = Deck(); var fallback = 0; var attached = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ }, { attached++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(1, attached); assertEquals(1, deck.starts); assertEquals(0, fallback)
        controller.close(); queue.runNext()
        assertEquals(1, attached)
    }
    @Test fun downloadFailureBeforeStartFallsBack() {
        val queue = Queue(); val session = Session().apply { downloadFails = true }; val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext(); queue.runNext()
        assertEquals(0, deck.starts); assertEquals(1, fallback); assertTrue(session.closed)
    }
    @Test fun downloadFailureAfterStartDiscardsAndFallsBack() {
        val queue = Queue(); val session = Session().apply { downloadFails = true }; val deck = Deck(); var fallback = 0
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext()
        queue.tasks.removeLast().run()
        queue.runNext(); queue.runNext()
        assertEquals(1, deck.starts); assertEquals(1, deck.stops); assertEquals(1, fallback)
        assertTrue(session.closed)
    }
    @Test fun closeWhileDeckIsOpeningDoesNotWaitForOpenOrFallback() {
        val executor = Executors.newFixedThreadPool(3)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val discarded = CountDownLatch(1)
        val session = Session(); var fallback = 0
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
            override fun discard() { discarded.countDown(); release.countDown() }
        }
        try {
            val controller = ProgressiveDeckController(executor, { session }, deck, { fallback++ })
            controller.start(); assertTrue(entered.await(2, TimeUnit.SECONDS))
            controller.close(); assertTrue(discarded.await(2, TimeUnit.SECONDS))
            assertEquals(0, fallback)
        } finally { release.countDown(); executor.shutdownNow() }
    }
    @Test fun fallbackWaitsForProducerToExitAfterCancellation() {
        val executor = Executors.newFixedThreadPool(3)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val closed = CountDownLatch(1); val fallback = CountDownLatch(1)
        val session = object : ProgressiveControllerSession {
            override fun download() { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
            override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate { entered.await(2, TimeUnit.SECONDS); return ProgressiveCandidate.Closed }
            override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int) = ProgressiveTerminal.Aborted
            override fun close() { closed.countDown() }
        }
        try {
            val controller = ProgressiveDeckController(executor, { session }, Deck(), { fallback.countDown() })
            controller.start(); assertTrue(closed.await(2, TimeUnit.SECONDS))
            assertFalse(fallback.await(100, TimeUnit.MILLISECONDS))
            release.countDown(); assertTrue(fallback.await(2, TimeUnit.SECONDS))
        } finally { release.countDown(); executor.shutdownNow() }
    }
    @Test fun abortedAfterSourceWaitsForProducerBeforeFallback() {
        val executor = Executors.newFixedThreadPool(3)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val closed = CountDownLatch(1); val fallback = CountDownLatch(1)
        val session = object : ProgressiveControllerSession {
            override fun download() { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
            override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate { entered.await(2, TimeUnit.SECONDS); return ProgressiveCandidate.Available(1, Lease()) }
            override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int) = ProgressiveTerminal.Aborted
            override fun close() { closed.countDown() }
        }
        try {
            val deck = Deck(); val controller = ProgressiveDeckController(executor, { session }, deck, { fallback.countDown() })
            controller.start(); assertTrue(closed.await(2, TimeUnit.SECONDS)); assertEquals(1, deck.starts); assertEquals(1, deck.stops)
            assertFalse(fallback.await(100, TimeUnit.MILLISECONDS))
            release.countDown(); assertTrue(fallback.await(2, TimeUnit.SECONDS))
        } finally { release.countDown(); executor.shutdownNow() }
    }
    @Test fun finishedBeforeProducerReturnKeepsSuccessfulResult() {
        val executor = Executors.newFixedThreadPool(3)
        val observed = CountDownLatch(1); val release = CountDownLatch(1); val delivered = CountDownLatch(1)
        val events = java.util.concurrent.CopyOnWriteArrayList<String>()
        val gate = ProgressiveAttemptGate({}, { events.add("result"); delivered.countDown() }, { events.add("fallback"); delivered.countDown() }, invalidated = { events.add("invalidated") })
        val session = object : ProgressiveControllerSession {
            override fun download() { release.await(2, TimeUnit.SECONDS); gate.result("ok") }
            override fun nextLease(afterSequence: Long, timeoutMs: Int): ProgressiveCandidate { observed.countDown(); return ProgressiveCandidate.Finished }
            override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int) = ProgressiveTerminal.Aborted
            override fun close() { events.add("closed") }
        }
        try {
            val controller = ProgressiveDeckController(executor, { session }, Deck(), gate::unavailable)
            controller.start(); assertTrue(observed.await(2, TimeUnit.SECONDS))
            assertFalse(delivered.await(100, TimeUnit.MILLISECONDS))
            assertFalse(events.contains("closed"))
            release.countDown(); assertTrue(delivered.await(2, TimeUnit.SECONDS))
            assertTrue(events.contains("result")); assertFalse(events.contains("fallback"))
        } finally { release.countDown(); executor.shutdownNow() }
    }
    @Test fun retireBeforeCommitKeepsProducerAndDeliversResultOnce() {
        val executor=Executors.newFixedThreadPool(4); val attached=CountDownLatch(1); val release=CountDownLatch(1); val retired=CountDownLatch(1); val result=CountDownLatch(1)
        val events=java.util.concurrent.CopyOnWriteArrayList<String>(); val deck=Deck()
        val gate=ProgressiveAttemptGate({attached.countDown()},{events.add("result");result.countDown()},{events.add("fallback")})
        val session=object:ProgressiveControllerSession {
            override fun download(){ release.await(2,TimeUnit.SECONDS); gate.result("ok") }
            override fun nextLease(afterSequence:Long,timeoutMs:Int)=ProgressiveCandidate.Available(1,Lease())
            override fun waitTerminal(lease:ProgressiveAudioLease,timeoutMs:Int):ProgressiveTerminal { release.await(2,TimeUnit.SECONDS); return ProgressiveTerminal.Aborted }
            override fun close(){ events.add("closed") }
        }
        try {
            val controller=ProgressiveDeckController(executor,{session},deck,gate::unavailable,gate::sourceAttached,onSourceCommitted=gate::sourceCommitted,onSourceRetired={events.add("retired");retired.countDown()})
            controller.start(); assertTrue(attached.await(2,TimeUnit.SECONDS)); controller.retireSource(); controller.retireSource()
            assertTrue(retired.await(2,TimeUnit.SECONDS)); assertEquals(1,deck.stops); assertFalse(events.contains("closed")); assertFalse(result.await(100,TimeUnit.MILLISECONDS))
            release.countDown(); assertTrue(result.await(2,TimeUnit.SECONDS)); assertEquals(listOf("retired","result"),events.toList()); controller.close()
        } finally { release.countDown(); executor.shutdownNow() }
    }
    @Test fun retireAfterCommitIsIndependentFromTerminalDownloadResult() {
        val queue=Queue(); val session=Session(); val deck=Deck(); var committed=0; var retired=0; var fallback=0
        val controller=ProgressiveDeckController(queue,{session},deck,{fallback++},onSourceCommitted={committed++},onSourceRetired={retired++})
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext(); assertEquals(1,committed)
        controller.retireSource(); controller.retireSource(); queue.runNext(); assertEquals(1,retired); assertEquals(1,deck.stops); assertEquals(0,fallback)
    }

    @Test fun sharedPoolCanCancelWhenMultipleProducersAndWatchersBlock() {
        val executor=Executors.newFixedThreadPool(3); val cleanup=Executors.newFixedThreadPool(2)
        val entered=CountDownLatch(3); val closeA=CountDownLatch(1); val closeB=CountDownLatch(1); val acknowledged=CountDownLatch(1)
        fun session(closed:CountDownLatch)=object:ProgressiveControllerSession {
            override fun download() { entered.countDown(); closed.await(3,TimeUnit.SECONDS) }
            override fun nextLease(afterSequence:Long,timeoutMs:Int):ProgressiveCandidate { entered.countDown(); closed.await(3,TimeUnit.SECONDS); return ProgressiveCandidate.Closed }
            override fun waitTerminal(lease:ProgressiveAudioLease,timeoutMs:Int)=ProgressiveTerminal.Pending
            override fun close(){ closed.countDown() }
        }
        val a=ProgressiveDeckController(executor,{session(closeA)},Deck(),{},cleanup=cleanup)
        val b=ProgressiveDeckController(executor,{session(closeB)},Deck(),{},cleanup=cleanup)
        try {
            a.start(); b.start(); assertTrue(entered.await(2,TimeUnit.SECONDS))
            a.closeAndNotify { acknowledged.countDown() }
            assertTrue("cancel must not wait for saturated worker pool",closeA.await(500,TimeUnit.MILLISECONDS))
            assertTrue(acknowledged.await(2,TimeUnit.SECONDS))
        } finally { closeA.countDown();closeB.countDown();executor.shutdownNow();cleanup.shutdownNow() }
    }
    @Test fun rejectedNestedDispatchClosesNewlyCreatedSession() {
        val session=Session(); var calls=0
        val executor=Executor { task -> if(calls++ == 0) task.run() else throw java.util.concurrent.RejectedExecutionException() }
        val controller=ProgressiveDeckController(executor,{session},Deck(),{})
        runCatching { controller.start() }
        val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(2)
        while(!session.closed && System.nanoTime()<deadline) Thread.yield()
        assertTrue("owner must close after rejected dispatch",session.closed)
    }

    @Test fun simultaneousFactoryCancellationsDoNotStarveOwnerCleanup() {
        val io=Executors.newFixedThreadPool(3); val cleanup=Executors.newFixedThreadPool(2); val completion=Executors.newFixedThreadPool(2)
        val entered=CountDownLatch(2); val release=CountDownLatch(1); val closed=CountDownLatch(2); val done=CountDownLatch(2)
        val outcomes=java.util.concurrent.ConcurrentLinkedQueue<Boolean>()
        fun controller()=ProgressiveDeckController(io,{
            entered.countDown(); release.await(2,TimeUnit.SECONDS)
            object:ProgressiveControllerSession {
                override fun download() { fail("cancelled startup must not download") }
                override fun nextLease(afterSequence:Long,timeoutMs:Int)=ProgressiveCandidate.Closed
                override fun waitTerminal(lease:ProgressiveAudioLease,timeoutMs:Int)=ProgressiveTerminal.Pending
                override fun close() { closed.countDown() }
            }
        },Deck(),{},cleanup=cleanup,completion=completion)
        try {
            val a=controller(); val b=controller(); a.start(); b.start(); assertTrue(entered.await(2,TimeUnit.SECONDS))
            a.closeAndNotify { outcomes.add(it); done.countDown() }; b.closeAndNotify { outcomes.add(it); done.countDown() }
            release.countDown(); assertTrue(closed.await(2,TimeUnit.SECONDS)); assertTrue(done.await(2,TimeUnit.SECONDS))
            assertEquals(listOf(true,true),outcomes.toList().sorted())
        } finally { release.countDown(); io.shutdownNow(); cleanup.shutdownNow(); completion.shutdownNow() }
    }

    @Test fun cancellationDuringFactoryWaitsUntilCreatedOwnerIsClosed() {
        val io=Executors.newFixedThreadPool(3); val cleanup=Executors.newFixedThreadPool(2)
        val factoryEntered=CountDownLatch(1); val releaseFactory=CountDownLatch(1); val closed=CountDownLatch(1); val done=CountDownLatch(1); var result=false
        val session=object:ProgressiveControllerSession {
            override fun download() { fail("cancelled startup must not download") }
            override fun nextLease(afterSequence:Long,timeoutMs:Int)=ProgressiveCandidate.Closed
            override fun waitTerminal(lease:ProgressiveAudioLease,timeoutMs:Int)=ProgressiveTerminal.Aborted
            override fun close(){closed.countDown()}
        }
        try {
            val controller=ProgressiveDeckController(io,{factoryEntered.countDown();releaseFactory.await(2,TimeUnit.SECONDS);session},Deck(),{},cleanup=cleanup)
            controller.start(); assertTrue(factoryEntered.await(2,TimeUnit.SECONDS)); controller.closeAndNotify { result=it;done.countDown() }
            assertFalse("cannot acknowledge before factory settles",done.await(100,TimeUnit.MILLISECONDS)); releaseFactory.countDown()
            assertTrue(closed.await(2,TimeUnit.SECONDS)); assertTrue(done.await(2,TimeUnit.SECONDS)); assertTrue(result)
        } finally { releaseFactory.countDown();io.shutdownNow();cleanup.shutdownNow() }
    }
    @Test fun rejectedObserverClosesOwnerAndSkipsQueuedDownload() {
        val cleanup=Executors.newFixedThreadPool(2); val closed=CountDownLatch(1); val fallback=CountDownLatch(1); var queued:Runnable?=null; var dispatch=0; var downloads=0
        val io=Executor { task -> when(dispatch++) { 0 -> task.run(); 1 -> queued=task; else -> throw java.util.concurrent.RejectedExecutionException() } }
        val session=object:ProgressiveControllerSession {
            override fun download(){downloads++}
            override fun nextLease(afterSequence:Long,timeoutMs:Int)=ProgressiveCandidate.Closed
            override fun waitTerminal(lease:ProgressiveAudioLease,timeoutMs:Int)=ProgressiveTerminal.Aborted
            override fun close(){closed.countDown()}
        }
        try {
            val controller=ProgressiveDeckController(io,{session},Deck(),{fallback.countDown()},cleanup=cleanup)
            controller.start(); assertTrue(closed.await(2,TimeUnit.SECONDS)); assertFalse(fallback.await(100,TimeUnit.MILLISECONDS))
            checkNotNull(queued).run(); assertTrue(fallback.await(2,TimeUnit.SECONDS)); assertEquals(0,downloads)
        } finally {cleanup.shutdownNow()}
    }

    @Test fun failedDeckOpenClosesLeaseEvenIfSessionDoesNot() {
        val queue=Queue(); val lease=Lease(); var fallback=0
        val session=object:ProgressiveControllerSession {
            override fun download() {}
            override fun nextLease(afterSequence:Long,timeoutMs:Int)=ProgressiveCandidate.Available(1,lease)
            override fun waitTerminal(lease:ProgressiveAudioLease,timeoutMs:Int)=ProgressiveTerminal.Pending
            override fun close() {}
        }
        val deck=object:ProgressiveControllerDeck { override fun open(lease:ProgressiveAudioLease){throw IllegalStateException("open failed")}; override fun discard(){} }
        val controller=ProgressiveDeckController(queue,{session},deck,{fallback++})
        controller.start(); queue.runNext();queue.runNext();queue.runNext();queue.runNext()
        assertTrue(lease.closed);assertEquals(1,fallback)
    }

    private class ThrowingDeck : ProgressiveControllerDeck {
        var discards = 0
        override fun open(lease: ProgressiveAudioLease) {}
        override fun discard() { discards++; throw IllegalStateException("discard failed") }
    }

    @Test fun discardFailureOnInvalidationStillClosesSessionAndReportsFailure() {
        val queue = Queue(); val session = Session().apply { terminal = ProgressiveTerminal.Invalidated }
        var fallback = 0; var failures = 0
        val controller = ProgressiveDeckController(queue, { session }, ThrowingDeck(), { fallback++ }, onCancellationFailure = { failures++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext(); queue.runNext()
        assertTrue(session.closed); assertEquals(1, failures); assertEquals(0, fallback)
    }

    @Test fun discardFailureOnCloseStillClosesSessionAndNotifiesFalse() {
        val queue = Queue(); val session = Session(); val deck = ThrowingDeck(); var result: Boolean? = null
        val controller = ProgressiveDeckController(queue, { session }, deck, {})
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext()
        controller.closeAndNotify { result = it }; queue.runNext()
        assertTrue(session.closed); assertEquals(false, result); assertEquals(1, deck.discards)
    }

    @Test fun discardFailureOnRetireReportsWithoutClaimingRetirement() {
        val queue = Queue(); val session = Session(); var retired = 0; var failures = 0
        val controller = ProgressiveDeckController(queue, { session }, ThrowingDeck(), {}, onCancellationFailure = { failures++ }, onSourceRetired = { retired++ })
        controller.start(); queue.runNext(); queue.runNext(); queue.runNext()
        controller.retireSource()
        assertEquals(1, failures); assertEquals(0, retired)
    }

    @Test fun retirementWaitsForDeckCloseAndTimeoutDoesNotClaimSuccess() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val attached = CountDownLatch(1); val close = CountDownLatch(1); val retired = CountDownLatch(1); val failed = CountDownLatch(1)
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() {}
            override fun awaitDiscard(timeoutMs: Long) = close.await(timeoutMs, TimeUnit.MILLISECONDS)
        }
        try {
            val controller = ProgressiveDeckController(io, { Session() }, deck, { fail("unexpected fallback") },
                onSourceAttached = { attached.countDown() }, onSourceRetired = { retired.countDown() },
                onCancellationFailure = { failed.countDown() }, cleanup = cleanup, discardWaitMs = 200)
            controller.start(); assertTrue(attached.await(2, TimeUnit.SECONDS)); controller.retireSource()
            assertFalse(retired.await(50, TimeUnit.MILLISECONDS)); assertTrue(failed.await(1, TimeUnit.SECONDS))
            close.countDown(); assertFalse(retired.await(100, TimeUnit.MILLISECONDS))
        } finally { close.countDown(); io.shutdownNow(); cleanup.shutdownNow() }
    }

    @Test fun retirementReportsAfterDeckClose() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val attached = CountDownLatch(1); val close = CountDownLatch(1); val retired = CountDownLatch(1)
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() {}
            override fun awaitDiscard(timeoutMs: Long) = close.await(timeoutMs, TimeUnit.MILLISECONDS)
        }
        try {
            val controller = ProgressiveDeckController(io, { Session() }, deck, { fail("unexpected fallback") },
                onSourceAttached = { attached.countDown() }, onSourceRetired = { retired.countDown() }, cleanup = cleanup)
            controller.start(); assertTrue(attached.await(2, TimeUnit.SECONDS)); controller.retireSource()
            assertFalse(retired.await(100, TimeUnit.MILLISECONDS)); close.countDown(); assertTrue(retired.await(1, TimeUnit.SECONDS))
        } finally { close.countDown(); io.shutdownNow(); cleanup.shutdownNow() }
    }

    @Test fun cancellationDuringRetirementSuppressesLateRetiredEvent() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val attached = CountDownLatch(1); val waiting = CountDownLatch(1); val close = CountDownLatch(1); val done = CountDownLatch(1)
        val events = java.util.concurrent.CopyOnWriteArrayList<String>()
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() {}
            override fun awaitDiscard(timeoutMs: Long): Boolean { waiting.countDown(); return close.await(timeoutMs, TimeUnit.MILLISECONDS) }
        }
        try {
            val controller = ProgressiveDeckController(io, { Session() }, deck, { events.add("fallback") },
                onSourceAttached = { attached.countDown() }, onSourceRetired = { events.add("retired") },
                onCancellationFailure = { events.add("failed") }, cleanup = cleanup)
            controller.start(); assertTrue(attached.await(2, TimeUnit.SECONDS)); controller.retireSource()
            assertTrue(waiting.await(1, TimeUnit.SECONDS)); controller.closeAndNotify { done.countDown() }; close.countDown()
            assertTrue(done.await(2, TimeUnit.SECONDS)); assertTrue(events.isEmpty())
        } finally { close.countDown(); io.shutdownNow(); cleanup.shutdownNow() }
    }

    @Test fun closeAcknowledgementWaitsForDeckCallbackAndTimesOutFalse() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val attached = CountDownLatch(1); val closeRequested = CountDownLatch(1); val closed = CountDownLatch(1); val done = CountDownLatch(1)
        var result: Boolean? = null
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() { closeRequested.countDown() }
            override fun awaitDiscard(timeoutMs: Long) = closed.await(timeoutMs, TimeUnit.MILLISECONDS)
        }
        try {
            val controller = ProgressiveDeckController(io, { Session() }, deck, {}, onSourceAttached = { attached.countDown() }, cleanup = cleanup, discardWaitMs = 300)
            controller.start(); assertTrue(attached.await(2, TimeUnit.SECONDS)); controller.closeAndNotify { result = it; done.countDown() }
            assertTrue(closeRequested.await(1, TimeUnit.SECONDS)); assertFalse(done.await(100, TimeUnit.MILLISECONDS))
            assertTrue(done.await(1, TimeUnit.SECONDS)); assertEquals(false, result)
        } finally { closed.countDown(); io.shutdownNow(); cleanup.shutdownNow() }
    }

    @Test fun closeAcknowledgementSucceedsOnlyAfterDeckCallback() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val attached = CountDownLatch(1); val requested = CountDownLatch(1); val closed = CountDownLatch(1); val done = CountDownLatch(1)
        var result: Boolean? = null
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() { requested.countDown() }
            override fun awaitDiscard(timeoutMs: Long) = closed.await(timeoutMs, TimeUnit.MILLISECONDS)
        }
        try {
            val controller = ProgressiveDeckController(io, { Session() }, deck, {}, onSourceAttached = { attached.countDown() }, cleanup = cleanup)
            controller.start(); assertTrue(attached.await(2, TimeUnit.SECONDS)); controller.closeAndNotify { result = it; done.countDown() }
            assertTrue(requested.await(1, TimeUnit.SECONDS)); assertFalse(done.await(100, TimeUnit.MILLISECONDS))
            closed.countDown(); assertTrue(done.await(1, TimeUnit.SECONDS)); assertEquals(true, result)
        } finally { closed.countDown(); io.shutdownNow(); cleanup.shutdownNow() }
    }

    @Test fun invalidationFallbackWaitsForDeckCloseCallback() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val attached = CountDownLatch(1); val invalidate = CountDownLatch(1); val closeRequested = CountDownLatch(1); val closed = CountDownLatch(1); val fallback = CountDownLatch(1)
        val session = object : ProgressiveControllerSession {
            override fun download() {}
            override fun nextLease(afterSequence: Long, timeoutMs: Int) = ProgressiveCandidate.Available(1, Lease())
            override fun waitTerminal(lease: ProgressiveAudioLease, timeoutMs: Int): ProgressiveTerminal { invalidate.await(2, TimeUnit.SECONDS); return ProgressiveTerminal.Invalidated }
            override fun close() {}
        }
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() { closeRequested.countDown() }
            override fun awaitDiscard(timeoutMs: Long) = closed.await(timeoutMs, TimeUnit.MILLISECONDS)
        }
        try {
            val controller = ProgressiveDeckController(io, { session }, deck, { fallback.countDown() }, onSourceAttached = { attached.countDown() }, cleanup = cleanup)
            controller.start(); assertTrue(attached.await(2, TimeUnit.SECONDS)); invalidate.countDown(); assertTrue(closeRequested.await(1, TimeUnit.SECONDS))
            assertFalse(fallback.await(100, TimeUnit.MILLISECONDS)); closed.countDown(); assertTrue(fallback.await(1, TimeUnit.SECONDS))
        } finally { invalidate.countDown(); closed.countDown(); io.shutdownNow(); cleanup.shutdownNow() }
    }

    @Test fun discardCanReenterControllerWithoutWaitingForControllerLock() {
        val io = Executors.newFixedThreadPool(3); val cleanup = Executors.newSingleThreadExecutor()
        val discardFinished = CountDownLatch(1); val fallback = CountDownLatch(1)
        var reentryCompleted = false
        lateinit var controller: ProgressiveDeckController
        val deck = object : ProgressiveControllerDeck {
            override fun open(lease: ProgressiveAudioLease) {}
            override fun discard() {
                val entered = CountDownLatch(1)
                Thread { controller.closeAndNotify {}; entered.countDown() }.apply { isDaemon = true; start() }
                reentryCompleted = entered.await(300, TimeUnit.MILLISECONDS)
                discardFinished.countDown()
            }
        }
        try {
            controller = ProgressiveDeckController(io, { Session().apply { terminal = ProgressiveTerminal.Invalidated } }, deck,
                { fallback.countDown() }, cleanup = cleanup)
            controller.start(); assertTrue(discardFinished.await(2, TimeUnit.SECONDS))
            assertTrue("discard must not hold the controller lock across external calls", reentryCompleted)
        } finally { io.shutdownNow(); cleanup.shutdownNow() }
    }


    @Test fun repeatedCloseAnswersOnlyWhenRealCloseSettles() {
        val io = Queue(); val completion = Queue(); val session = Session(); val results = mutableListOf<Boolean>()
        val controller = ProgressiveDeckController(io, { session }, Deck(), {}, completion = completion)
        controller.start(); io.runNext(); io.runNext(); io.runNext()
        controller.closeAndNotify { results.add(it) }; controller.closeAndNotify { results.add(it) }
        io.runNext(); assertTrue(session.closed); assertTrue("must not answer before real close", results.isEmpty())
        completion.runNext(); assertEquals(listOf(true, true), results)
        controller.closeAndNotify { results.add(it) }; assertEquals(listOf(true, true, true), results)
    }

    @Test fun closeAfterFailureWaitsForFailureCleanup() {
        val io = Queue(); val completion = Queue(); var fallback = 0; var result: Boolean? = null
        val session = Session().apply { terminal = ProgressiveTerminal.Invalidated }
        val controller = ProgressiveDeckController(io, { session }, Deck(), { fallback++ }, completion = completion)
        controller.start(); io.runNext(); io.runNext(); io.runNext()
        controller.closeAndNotify { result = it }
        assertNull("failure cleanup still pending", result)
        io.runNext(); assertNull(result)
        completion.runNext(); assertEquals(true, result); assertEquals(1, fallback)
    }

    @Test fun finishedWithProducerTimeoutClosesSessionReportsOnceAndNoFallback() {
        val io = Queue(); val cleanup = Queue(); val session = Session().apply { available = false }
        var fallback = 0; var failures = 0; val results = mutableListOf<Boolean>()
        val controller = ProgressiveDeckController(io, { session }, Deck(), { fallback++ },
            onCancellationFailure = { failures++ }, cleanup = cleanup, downloadWaitMs = 0)
        controller.start(); io.runNext()
        // The download task stays queued (producer never returns); run only the observer.
        io.tasks.removeLast().run()
        assertFalse("close must not run inline on the observer", session.closed)
        assertEquals(0, failures)
        cleanup.runNext()
        assertTrue(session.closed); assertEquals(1, failures); assertEquals(0, fallback)
        controller.closeAndNotify { results.add(it) }; controller.close()
        assertEquals(listOf(false), results); assertEquals(1, failures); assertTrue(cleanup.tasks.isEmpty())
    }

    @Test fun failureWhileOpeningDiscardsAndFallsBackOnce() {
        val queue = Queue(); val session = Session(); var fallback = 0; var stops = 0
        val deck = object : ProgressiveControllerDeck {
            // The producer fails while the deck is still opening.
            override fun open(lease: ProgressiveAudioLease) { session.downloadFails = true; queue.runNext() }
            override fun discard() { stops++ }
        }
        val controller = ProgressiveDeckController(queue, { session }, deck, { fallback++ })
        controller.start(); queue.runNext(); queue.tasks.removeLast().run()
        while (queue.tasks.isNotEmpty()) queue.runNext()
        assertTrue(session.closed); assertEquals(1, fallback); assertTrue(stops >= 1)
    }

}
