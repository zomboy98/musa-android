package com.zarz.mornye

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ExperimentalKeyAccessTest {
    @Test fun cancellationBeforeBridgeRegistersIsForwarded() {
        val request = KeyReadRequest()
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        request.cancel()
        request.onCancel { cancelled.set(true) }
        assertTrue(cancelled.get())
    }
    @Test fun disabledNeverCallsReader() {
        var invoked = false
        val access = ExperimentalKeyAccess(false, QueuedExtensionKeyReader { _, callback -> invoked = true; callback("value") })
        assertNull(access.read({ true }, 100))
        assertFalse(invoked)
    }
    @Test fun missingReaderOrCancelledAttemptFailsClosed() {
        assertNull(ExperimentalKeyAccess(true, null).read({ true }, 100))
        val active = java.util.concurrent.atomic.AtomicBoolean(true)
        val access = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { _, callback -> active.set(false); callback("value") })
        assertNull(access.read({ active.get() }, 100))
    }
    @Test fun callbackIsOneShotAndTimeoutDoesNotReturnLateKey() {
        val callback = java.util.concurrent.atomic.AtomicReference<(String?) -> Unit>()
        val submitted = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val access = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { request, cb -> request.onCancel { cancelled.countDown() }; callback.set(cb); submitted.countDown() })
        assertNull(access.read({ true }, 100))
        assertTrue(submitted.await(1, TimeUnit.SECONDS))
        assertTrue(cancelled.await(1, TimeUnit.SECONDS))
        callback.get().invoke("late")
        val done = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { _, cb -> cb("first"); cb("second") })
        assertEquals("first", done.read({ true }, 100))
    }

    @Test fun stopCancelsQueuedReaderWithoutWaitingForTimeout() {
        val active = java.util.concurrent.atomic.AtomicBoolean(true)
        val submitted = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val pool = Executors.newSingleThreadExecutor()
        try {
            val access = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { request, _ -> request.onCancel { cancelled.countDown() }; submitted.countDown() })
            val result = pool.submit<String?> { access.read({ active.get() }, 5_000) }
            assertTrue(submitted.await(1, TimeUnit.SECONDS))
            active.set(false)
            assertNull(result.get(1, TimeUnit.SECONDS))
            assertTrue(cancelled.await(1, TimeUnit.SECONDS))
        } finally { pool.shutdownNow() }
    }

    @Test fun synchronousReaderCannotHoldCallerPastDeadline() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val access = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { request, cb ->
            request.onCancel { cancelled.countDown() }
            entered.countDown()
            release.await(2, TimeUnit.SECONDS)
            cb("late")
        })
        try {
            assertNull(access.read({ true }, 100))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
        } finally { release.countDown() }
        assertTrue(cancelled.await(1, TimeUnit.SECONDS))
    }

    @Test fun blockedReaderDoesNotCreateAnotherWorker() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val exited = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val first = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { _, _ ->
            entered.countDown()
            try { release.await(2, TimeUnit.SECONDS) } finally { exited.countDown() }
        })
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val second = ExperimentalKeyAccess(true, QueuedExtensionKeyReader { _, _ -> calls.incrementAndGet(); secondEntered.countDown() })
        try {
            assertNull(first.read({ true }, 100))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            repeat(20) {
                assertNull(second.read({ true }, 5))
                assertEquals(0, ExperimentalKeyAccess.pendingCountForTest())
            }
            assertEquals(0, calls.get())
        } finally {
            release.countDown()
            assertTrue(exited.await(1, TimeUnit.SECONDS))
        }
        assertFalse(secondEntered.await(200, TimeUnit.MILLISECONDS))
    }
}
