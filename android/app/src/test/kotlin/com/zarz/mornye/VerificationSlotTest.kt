package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VerificationSlotTest {
    @Test
    fun firstRequestStartsAndSecondIsBusy() {
        val s = VerificationSlot()
        assertEquals(VerificationSlot.Begin.STARTED, s.begin("a", true))
        assertEquals(VerificationSlot.Begin.BUSY, s.begin("b", true))
        assertEquals("a", s.activeId)
    }

    @Test
    fun busyWinsOverInvalid() {
        val s = VerificationSlot()
        s.begin("a", true)
        assertEquals(VerificationSlot.Begin.BUSY, s.begin("", false))
    }

    @Test
    fun blankIdOrInvalidDestinationIsInvalidAndKeepsSlotFree() {
        val s = VerificationSlot()
        assertEquals(VerificationSlot.Begin.INVALID, s.begin("  ", true))
        assertEquals(VerificationSlot.Begin.INVALID, s.begin("a", false))
        assertNull(s.activeId)
        assertEquals(VerificationSlot.Begin.STARTED, s.begin("a", true))
    }

    @Test
    fun onlyHolderCanFinishAndSlotIsReusable() {
        val s = VerificationSlot()
        s.begin("a", true)
        assertFalse(s.finish("b"))
        assertFalse(s.finish(null))
        assertTrue(s.isActive("a"))
        assertTrue(s.finish("a"))
        assertFalse(s.finish("a"))
        assertNull(s.activeId)
        // Five providers chained one after another reuse the same slot.
        for (i in 1..5) {
            assertEquals(VerificationSlot.Begin.STARTED, s.begin("p$i", true))
            assertTrue(s.finish("p$i"))
        }
    }

    @Test
    fun hostPolicyNeedsLiveStartedOwner() {
        assertTrue(VerificationHostPolicy.canHost(true, false, true))
        assertFalse(VerificationHostPolicy.canHost(false, false, true))
        assertFalse(VerificationHostPolicy.canHost(true, true, true))
        assertFalse(VerificationHostPolicy.canHost(true, false, false))
    }
}
