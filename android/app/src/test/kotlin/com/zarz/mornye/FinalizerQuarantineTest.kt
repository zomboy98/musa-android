package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class FinalizerQuarantineTest {
    @Test
    fun cleanupRemainsQuarantinedUntilEveryProducerStops() {
        val quarantine = FinalizerQuarantine()
        val first = quarantine.register()
        val second = quarantine.register()
        quarantine.requestCleanup()
        assertNull(quarantine.tryClaimCleanup())
        assertTrue(quarantine.producerStopped(first))
        assertFalse(quarantine.producerStopped(first))
        assertNull(quarantine.tryClaimCleanup())
        assertTrue(quarantine.producerStopped(second))
        val claim = quarantine.tryClaimCleanup()!!
        assertNull(quarantine.tryClaimCleanup())
        quarantine.cleanupResult(claim, false)
        val retry = quarantine.tryClaimCleanup()!!
        try {
            quarantine.cleanupResult(claim, true)
            fail("stale claim must fail")
        } catch (_: IllegalStateException) { }
        quarantine.cleanupResult(retry, true)
        assertNull(quarantine.tryClaimCleanup())
    }

    @Test
    fun lateCallbackReleasesQuarantineAndOnlyOneCallerClaimsCleanup() {
        val quarantine = FinalizerQuarantine()
        val producer = quarantine.register()
        quarantine.requestCleanup()
        assertNull(quarantine.tryClaimCleanup())
        assertTrue(quarantine.producerStopped(producer))
        val start = CountDownLatch(1)
        val results = arrayOfNulls<FinalizerQuarantine.CleanupClaim>(2)
        val threads = (0..1).map { index -> thread {
            start.await()
            results[index] = quarantine.tryClaimCleanup()
        } }
        start.countDown()
        threads.forEach { it.join(TimeUnit.SECONDS.toMillis(2)); assertFalse(it.isAlive) }
        assertEquals(1, results.count { it != null })
        quarantine.cleanupResult(results.filterNotNull().single(), true)
    }

    @Test
    fun rejectsRegistrationAfterCleanupRequestAndForeignTokens() {
        val quarantine = FinalizerQuarantine()
        val foreign = FinalizerQuarantine().register()
        quarantine.requestCleanup()
        assertFalse(quarantine.producerStopped(foreign))
        try {
            quarantine.register()
            fail("registration after cleanup must fail")
        } catch (_: IllegalStateException) { }
        assertNotNull(quarantine.tryClaimCleanup())
    }
}
