package com.it_nomads.fluttersecurestorage;

import static org.junit.Assert.*;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;

public class AsyncStorageQueueTest {
    @Test public void cancelledQueuedReadNeverStartsOrCallsBack() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        AtomicReference<Runnable> finish = new AtomicReference<>();
        java.util.concurrent.atomic.AtomicInteger reads = new java.util.concurrent.atomic.AtomicInteger();
        java.util.concurrent.atomic.AtomicInteger callbacks = new java.util.concurrent.atomic.AtomicInteger();
        CancellableRead request = new CancellableRead();
        queue.submit(finish::set);
        queue.submit(done -> {
            if (request.tryStart()) { reads.incrementAndGet(); request.deliver(callbacks::incrementAndGet); }
            done.run();
        });
        request.cancel();
        finish.get().run();
        assertEquals(0, reads.get()); assertEquals(0, callbacks.get());
        queue.submit(done -> { callbacks.incrementAndGet(); done.run(); });
        assertEquals(1, callbacks.get());
    }

    @Test public void readerAdmissionBoundsCancelledTurnsBehindUnrelatedWork() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        ReadAdmission admission = new ReadAdmission();
        AtomicReference<Runnable> finish = new AtomicReference<>();
        java.util.concurrent.atomic.AtomicInteger started = new java.util.concurrent.atomic.AtomicInteger();
        queue.submit(finish::set);
        assertTrue(admission.tryAcquire());
        CancellableRead request = new CancellableRead();
        queue.submit(done -> { if (request.tryStart()) started.incrementAndGet(); admission.release(); done.run(); });
        request.cancel();
        for (int i = 0; i < 1000; i++) assertFalse(admission.tryAcquire());
        finish.get().run();
        assertEquals(0, started.get());
        assertTrue(admission.tryAcquire());
        admission.release();
    }

    @Test public void cancelAfterStartSuppressesLateDelivery() {
        CancellableRead request = new CancellableRead();
        java.util.concurrent.atomic.AtomicBoolean delivered = new java.util.concurrent.atomic.AtomicBoolean();
        assertTrue(request.tryStart());
        request.cancel();
        request.deliver(() -> delivered.set(true));
        assertFalse(delivered.get());
    }

    @Test public void cancellingNeverWaitsForAnAlreadyClaimedCallback() throws Exception {
        CancellableRead request = new CancellableRead();
        assertTrue(request.tryStart());
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        Thread callback = new Thread(() -> request.deliver(() -> {
            entered.countDown();
            try { release.await(2, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }));
        callback.start();
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS));
            java.util.concurrent.ExecutorService pool = java.util.concurrent.Executors.newSingleThreadExecutor();
            try { assertFalse(pool.submit(request::cancel).get(1, TimeUnit.SECONDS)); }
            finally { pool.shutdownNow(); }
        } finally { release.countDown(); callback.join(1000); }
        assertFalse(callback.isAlive());
    }
    @Test public void holdsTurnUntilCallbackFromAnotherThread() throws Exception {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        List<Integer> events = java.util.Collections.synchronizedList(new ArrayList<>());
        AtomicReference<Runnable> finish = new AtomicReference<>();
        CountDownLatch second = new CountDownLatch(1);
        queue.submit(done -> { events.add(1); finish.set(done); });
        queue.submit(done -> { events.add(2); second.countDown(); done.run(); });
        assertFalse(second.await(100, TimeUnit.MILLISECONDS));
        Thread completion = new Thread(() -> finish.get().run());
        completion.start(); completion.join(5000);
        assertTrue(second.await(5, TimeUnit.SECONDS));
        assertEquals(java.util.Arrays.asList(1, 2), events);
    }
    @Test public void doubleCompletionAndReentrantSubmissionDoNotOverlap() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        List<Integer> events = new ArrayList<>();
        queue.submit(done -> {
            events.add(1);
            queue.submit(next -> { events.add(3); next.run(); });
            events.add(2); done.run(); done.run();
        });
        assertEquals(java.util.Arrays.asList(1, 2, 3), events);
    }
    @Test public void thrownOperationReleasesQueue() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        AtomicReference<Throwable> error = new AtomicReference<>();
        queue.submit(done -> { throw new IllegalStateException("fixture"); }, error::set);
        assertTrue(error.get() instanceof IllegalStateException);
        List<Integer> events = new ArrayList<>();
        queue.submit(done -> { events.add(1); done.run(); });
        assertEquals(java.util.Collections.singletonList(1), events);
    }
    @Test public void asyncCompletionDoesNotInheritNextOperationFailure() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        AtomicReference<Runnable> finish = new AtomicReference<>();
        AtomicReference<Throwable> nextError = new AtomicReference<>();
        queue.submit(finish::set);
        queue.submit(done -> { throw new IllegalStateException("next"); }, nextError::set);
        finish.get().run();
        assertTrue(nextError.get() instanceof IllegalStateException);
    }
    @Test public void failedTurnDoesNotStopLaterAsyncTurn() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        AtomicReference<Throwable> error = new AtomicReference<>();
        queue.submit(done -> { throw new IllegalArgumentException("first"); }, error::set);
        AtomicReference<Runnable> finish = new AtomicReference<>();
        queue.submit(finish::set);
        assertNotNull(finish.get()); finish.get().run();
        assertTrue(error.get() instanceof IllegalArgumentException);
    }
    @Test public void manySynchronousCallbacksDoNotGrowStack() {
        AsyncStorageQueue queue = new AsyncStorageQueue();
        java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
        queue.submit(done -> {
            for (int i = 0; i < 10_000; i++) queue.submit(next -> { calls.incrementAndGet(); next.run(); });
            done.run();
        });
        assertEquals(10_000, calls.get());
    }
}
