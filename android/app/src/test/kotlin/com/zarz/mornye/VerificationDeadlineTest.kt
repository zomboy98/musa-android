package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VerificationDeadlineTest {
    private var now = 1_000L
    private fun deadline() = VerificationDeadline({ now })

    @Test
    fun hardTimeoutIsTwentyFiveSeconds() {
        assertEquals(25_000L, VerificationDeadline.HARD_TIMEOUT_MS)
        assertEquals(25_000L, deadline().remainingMs())
        assertFalse(deadline().expired())
    }

    @Test
    fun expiresExactlyAtTimeout() {
        val d = deadline()
        now += 24_999L
        assertFalse(d.expired())
        assertEquals(1L, d.remainingMs())
        now += 1L
        assertTrue(d.expired())
        assertEquals(0L, d.remainingMs())
    }

    @Test
    fun doesNotExpireIfCompletedBefore() {
        val d = deadline()
        now += 5_000L
        d.markCompleted()
        now += 60_000L
        assertFalse(d.expired())
        assertEquals(0L, d.remainingMs())
    }

    @Test
    fun startRestartsCountdown() {
        val d = deadline()
        now += 20_000L
        d.start()
        now += 10_000L
        assertFalse(d.expired())
        assertEquals(15_000L, d.remainingMs())
    }

    @Test
    fun customTimeoutAndNewInstancePerVerificationAreIndependent() {
        val a = VerificationDeadline({ now }, timeoutMs = 1_000L)
        now += 1_000L
        assertTrue(a.expired())
        // Each chained verification gets its own deadline: a fresh one is not expired.
        val b = deadline()
        assertFalse(b.expired())
        assertEquals(VerificationDeadline.HARD_TIMEOUT_MS, b.remainingMs())
    }

    @Test
    fun markCompletedIsIdempotentAndFinal() {
        val d = deadline()
        d.markCompleted()
        d.markCompleted()
        assertTrue(d.completed)
        now += 100_000L
        assertFalse(d.expired())
    }
}
