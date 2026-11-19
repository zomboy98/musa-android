package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test

class ProgressiveAttemptGateTest {
    @Test fun acceptedAndFinalResultAreIndependentAndTerminalIsSingle() {
        val events = mutableListOf<String>()
        val gate = ProgressiveAttemptGate({ events.add("attached") }, { events.add("result") }, { events.add("fallback") })
        gate.sourceAttached(); gate.sourceAttached(); gate.result("sensitive"); gate.sourceCommitted(); gate.unavailable(); gate.result("late")
        assertEquals(listOf("attached", "result"), events)
    }
    @Test fun resultBeforeInvalidationDoesNotMasqueradeAsValidDeck() {
        val events = mutableListOf<String>()
        val gate = ProgressiveAttemptGate({ events.add("attached") }, { events.add("result") }, { events.add("fallback") }, { events.add("failed") }, { events.add("invalidated") })
        gate.sourceAttached(); gate.result("result"); gate.unavailable(); gate.sourceCommitted()
        assertEquals(listOf("attached", "invalidated", "result"), events)
    }
    @Test fun fallbackOrCancelRejectsLateEvents() {
        for (cancelled in listOf(false, true)) {
            val events = mutableListOf<String>()
            val gate = ProgressiveAttemptGate({ events.add("attached") }, { events.add("result") }, { events.add("fallback") })
            if (cancelled) gate.cancel() else gate.unavailable()
            gate.result("late"); gate.sourceAttached(); gate.unavailable()
            assertEquals(if (cancelled) emptyList<String>() else listOf("fallback"), events)
        }
    }
}
