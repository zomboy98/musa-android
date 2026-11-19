package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test

class SessionGenerationGateTest {
    @Test fun oldWorkerCannotRequeueAfterOffOnOrRestart() {
        var persisted = 0L
        val store = SessionGenerationGate({ persisted }, { persisted = it; true })
        val old = store.current()!!
        assertEquals(old, store.invalidate())
        val resumed = SessionGenerationGate({ persisted }, { persisted = it; true })
        assertFalse(resumed.runIfCurrent(old) { fail("old worker scheduled") })
        assertTrue(resumed.runIfCurrent(1L) { })
    }
    @Test fun failedWriteAndInvalidDataFailClosed() {
        val failed = SessionGenerationGate({ 4L }, { false })
        assertNull(failed.invalidate())
        assertNull(failed.current())
        assertFalse(failed.runIfCurrent(4L) { fail() })
        assertNull(SessionGenerationGate({ null }, { true }).current())
        assertNull(SessionGenerationGate({ Long.MAX_VALUE }, { true }).invalidate())
    }
    @Test fun scheduleAndInvalidateAreSerialized() {
        var persisted = 0L
        val gate = SessionGenerationGate({ persisted }, { persisted = it; true })
        val inside = java.util.concurrent.CountDownLatch(1)
        val exit = java.util.concurrent.CountDownLatch(1)
        val attempted = java.util.concurrent.CountDownLatch(1)
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val scheduled = pool.submit<Boolean> { gate.runIfCurrent(0) { inside.countDown(); check(exit.await(5, java.util.concurrent.TimeUnit.SECONDS)) } }
            assertTrue(inside.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val invalidated = pool.submit<Long?> { attempted.countDown(); gate.invalidate() }
            assertTrue(attempted.await(5, java.util.concurrent.TimeUnit.SECONDS))
            assertFalse(invalidated.isDone)
            exit.countDown()
            assertTrue(scheduled.get(5, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(0L, invalidated.get(5, java.util.concurrent.TimeUnit.SECONDS))
            assertFalse(gate.runIfCurrent(0) { fail() })
        } finally { exit.countDown(); pool.shutdownNow() }
    }
    @Test fun failedProviderIsInvalidatedWithoutAffectingOthers() {
        var alphaValue = 2L
        var betaValue = 7L
        val alpha = SessionGenerationGate({ alphaValue }, { alphaValue = it; true })
        val beta = SessionGenerationGate({ betaValue }, { betaValue = it; true })
        assertEquals(2L, alpha.invalidate())
        assertFalse(alpha.runIfCurrent(2L) { fail() })
        assertTrue(beta.runIfCurrent(7L) { })
    }
}
