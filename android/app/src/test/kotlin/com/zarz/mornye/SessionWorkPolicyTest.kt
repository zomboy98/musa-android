package com.zarz.mornye
import org.junit.Assert.*
import org.junit.Test
class SessionWorkPolicyTest {
    @Test fun initialDeadlineAndClockChange() {
        assertEquals(SessionWorkPlan(5_200_000, 8_000_000, 0), initialSessionWork("valid_until", 8_000_000, 1_000_000))
        assertEquals(SessionWorkPlan(4_200_000, 8_000_000, 0), initialSessionWork("valid_until", 8_000_000, 2_000_000))
        assertNull(initialSessionWork("unavailable", 8_000_000, 1_000_000))
        assertNull(initialSessionWork("valid_until", 1_000_000, 1_000_000))
    }
    @Test fun refreshedShortLifetimeContinuesWhenExpiryAdvances() {
        assertEquals(SessionWorkPlan(300_000, 2_400_000, 0), nextSessionWork("refreshed", 2_400_000, 2_000_000, 0, 1_800_000))
    }
    @Test fun unavailableAndSameExpiryRetryBoundedBeforeExpiry() {
        val now = 1_000_000L
        assertEquals(SessionWorkPlan(300_000, 2_000_000, 1), nextSessionWork("unavailable", null, 2_000_000, 0, now))
        assertEquals(SessionWorkPlan(300_000, 2_000_000, 3), nextSessionWork("valid_until", 2_000_000, 2_000_000, 2, now))
        assertNull(nextSessionWork("unavailable", null, 2_000_000, 3, now))
        assertNull(nextSessionWork("unavailable", null, 1_000_000, 0, now))
        assertNull(nextSessionWork("missing", null, 2_000_000, 0, now))
    }
    @Test fun idsAreStrictAndBounded() {
        assertTrue(validSessionWorkId("musa-provider"))
        assertFalse(validSessionWorkId("../musa"))
        assertFalse(validSessionWorkId(""))
        assertFalse(validSessionWorkId("x".repeat(129)))
    }
}
