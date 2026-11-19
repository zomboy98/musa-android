package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test

class SessionStopGateTest {
    @Test fun stopBeforeRegistrationPreventsLateRegistration() {
        val gate = SessionStopGate()
        gate.stop()
        var calls = 0
        assertFalse(gate.register { calls++ })
        assertEquals(0, calls)
    }
    @Test fun stopCancelsRegisteredAttemptExactlyOnce() {
        val gate = SessionStopGate()
        var calls = 0
        assertTrue(gate.register { calls++ })
        gate.stop(); gate.stop()
        assertEquals(1, calls)
        assertFalse(gate.register { calls++ })
    }
    @Test fun completedAttemptIsNotCancelled() {
        val gate = SessionStopGate()
        var calls = 0
        assertTrue(gate.register { calls++ })
        gate.clear()
        gate.stop()
        assertEquals(0, calls)
    }
    @Test fun stopWaitsForCancellationBeforeReleaseCanProceed() {
        val gate = SessionStopGate()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val cleared = java.util.concurrent.CountDownLatch(1)
        assertTrue(gate.register { entered.countDown(); check(release.await(5, java.util.concurrent.TimeUnit.SECONDS)) })
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val stopped = pool.submit { gate.stop() }
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val clear = pool.submit { gate.clear(); cleared.countDown() }
            assertFalse(cleared.await(100, java.util.concurrent.TimeUnit.MILLISECONDS))
            release.countDown()
            stopped.get(5, java.util.concurrent.TimeUnit.SECONDS)
            clear.get(5, java.util.concurrent.TimeUnit.SECONDS)
        } finally { release.countDown(); pool.shutdownNow() }
    }
}
