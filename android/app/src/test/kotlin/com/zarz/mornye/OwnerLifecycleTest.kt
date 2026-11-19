package com.zarz.mornye

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class OwnerLifecycleTest {
    @Test fun closeWaitsForActiveOperationAndReinitializeWaitsForClose() {
        val lifecycle = OwnerLifecycle()
        val pool = Executors.newFixedThreadPool(3)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closing = CountDownLatch(1)
        val closeAttempted = CountDownLatch(1)
        val finishClose = CountDownLatch(1)
        try {
            val operation = pool.submit { lifecycle.operation { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val close = pool.submit { closeAttempted.countDown(); lifecycle.exclusive { closing.countDown(); check(finishClose.await(5, TimeUnit.SECONDS)) } }
            assertTrue(closeAttempted.await(5, TimeUnit.SECONDS))
            assertFalse(closing.await(200, TimeUnit.MILLISECONDS))
            release.countDown()
            assertTrue(closing.await(5, TimeUnit.SECONDS))
            val initialized = CountDownLatch(1)
            val init = pool.submit { lifecycle.exclusive { initialized.countDown() } }
            assertFalse(initialized.await(200, TimeUnit.MILLISECONDS))
            finishClose.countDown()
            operation.get(5, TimeUnit.SECONDS); close.get(5, TimeUnit.SECONDS); init.get(5, TimeUnit.SECONDS)
            assertEquals(0, initialized.count)
        } finally { release.countDown(); finishClose.countDown(); pool.shutdownNow() }
    }

    @Test fun operationExceptionReleasesLease() {
        val lifecycle = OwnerLifecycle()
        try { lifecycle.operation { error("expected") }; fail() } catch (_: IllegalStateException) {}
        val pool = Executors.newSingleThreadExecutor()
        try { assertEquals(7, pool.submit<Int> { lifecycle.exclusive { 7 } }.get(5, TimeUnit.SECONDS)) }
        finally { pool.shutdownNow() }
    }

    @Test fun cleanupAttemptsEveryActionAndRetainsAllFailures() {
        val calls = mutableListOf<Int>()
        val first = IllegalStateException("first")
        val second = IllegalArgumentException("second")
        val failure = closeOwnerResources(listOf(
            { calls.add(1); throw first },
            { calls.add(2) },
            { calls.add(3); throw second },
            { calls.add(4) },
        ))
        assertEquals(listOf(1, 2, 3, 4), calls)
        assertSame(first, failure)
        assertEquals(listOf(second), failure!!.suppressed.toList())
    }
}
