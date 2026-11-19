package xyz.luan.audioplayers.player

import org.junit.Assert.*
import org.junit.Test

class Media3EffectSessionControllerTest {
    private class Effect(val session: Int, val events: MutableList<String>) : Media3SessionEffect {
        var fail = false
        override fun configure(config: Map<String, Any?>) { events.add("config:$session:${config["gain"]}"); if (fail) error("effect failed") }
        override fun close() { events.add("close:$session") }
    }
    @Test fun disabledDoesNotCreateEffectAndSessionZeroWaits() {
        val events = mutableListOf<String>(); val controller = Media3EffectSessionController { id -> Effect(id, events).also { events.add("create:$id") } }
        controller.onSession(0, 1); controller.configure(mapOf("enabled" to true, "gain" to 3)); assertTrue(events.isEmpty())
        controller.onSession(12, 1); assertEquals(listOf("create:12", "config:12:3"), events)
        controller.configure(mapOf("enabled" to false)); assertEquals("close:12", events.last()); controller.onSession(13, 1)
        assertFalse(events.contains("create:13"))
    }
    @Test fun replacementClosesOldBeforeCreatingNewAndReappliesDesiredConfiguration() {
        val events = mutableListOf<String>(); val controller = Media3EffectSessionController { id -> Effect(id, events).also { events.add("create:$id") } }
        controller.configure(mapOf("enabled" to true, "gain" to 4)); controller.onSession(7, 1); controller.onSession(8, 1); controller.onSession(8, 1)
        assertEquals(listOf("create:7", "config:7:4", "close:7", "create:8", "config:8:4"), events)
    }
    @Test fun configureFailureClosesEffectAndCanRetry() {
        val events = mutableListOf<String>(); var first = true
        val controller = Media3EffectSessionController { Effect(it, events).also { effect -> effect.fail = first; first = false; events.add("create:$it") } }
        controller.onSession(7, 1)
        try { controller.configure(mapOf("enabled" to true, "gain" to 2)); fail("expected failure") } catch (_: IllegalStateException) {}
        assertEquals(listOf("create:7", "config:7:2", "close:7"), events)
        controller.configure(mapOf("enabled" to true, "gain" to 2)); assertEquals("config:7:2", events.last())
    }
    @Test fun staleGenerationIgnoredAndReleaseIsIdempotent() {
        val events = mutableListOf<String>(); val controller = Media3EffectSessionController { id -> Effect(id, events).also { events.add("create:$id") } }
        controller.configure(mapOf("enabled" to true)); controller.onSession(7, 2); controller.onSession(8, 1)
        controller.release(); controller.release(); controller.onSession(9, 3)
        assertEquals(listOf("create:7", "config:7:null", "close:7"), events)
    }
    @Test fun newGenerationRecreatesEffectEvenWhenSessionIdIsReused() {
        val events = mutableListOf<String>(); val controller = Media3EffectSessionController { id -> Effect(id, events).also { events.add("create:$id") } }
        controller.configure(mapOf("enabled" to true)); controller.onSession(7, 1); controller.onSession(7, 2); controller.onSession(8, 1)
        assertEquals(listOf("create:7", "config:7:null", "close:7", "create:7", "config:7:null"), events)
    }
    @Test fun failedCloseDoesNotCreateAnotherEffectOnRetry() {
        val events = mutableListOf<String>()
        val controller = Media3EffectSessionController { id -> object : Media3SessionEffect {
            init { events.add("create:$id") }
            override fun configure(config: Map<String, Any?>) {}
            override fun close() { events.add("close:$id"); error("close failed") }
        } }
        controller.configure(mapOf("enabled" to true)); controller.onSession(7, 1)
        try { controller.onSession(8, 1); fail("expected close failure") } catch (_: IllegalStateException) {}
        try { controller.onSession(8, 1); fail("unconfirmed close must remain failed") } catch (_: IllegalStateException) {}
        assertEquals(listOf("create:7", "close:7"), events)
    }
    @Test fun appliedStatusRequiresValidSessionAndSuccessfulConfiguration() {
        val events = mutableListOf<String>(); val controller = Media3EffectSessionController { id -> Effect(id, events) }
        assertFalse(controller.configureConfirmed(mapOf("enabled" to true)))
        assertFalse(controller.onSessionConfirmed(0, 1))
        assertTrue(controller.onSessionConfirmed(8, 1))
        assertTrue(controller.configureConfirmed(mapOf("enabled" to false)))
        assertNull(events.find { it.startsWith("create:") })
    }
    @Test fun removedDeckRevokesOnlyItsOwnOptInBeforeAsyncClose() {
        val owner = Media3EqOptInOwner(); val a = Any()
        owner.enable(a); assertTrue(owner.enabled())
        owner.revoke(a); assertFalse("a new deck without opt-in must use retirement", owner.enabled())
    }
    @Test fun lateCloseOfOldDeckCannotRevokeNewDeckOptIn() {
        val owner = Media3EqOptInOwner(); val a = Any(); val b = Any()
        owner.enable(a); owner.revoke(a); owner.enable(b); owner.revoke(a)
        assertTrue(owner.enabled()); owner.revoke(b); assertFalse(owner.enabled())
    }
    @Test fun staleDeckCannotOverwriteNewDeckOwner() {
        val owner = Media3EqOptInOwner(); val a = Any(); val b = Any()
        owner.enable(a); owner.revoke(a); assertTrue(owner.enable(b)); assertFalse(owner.enable(a))
        owner.revoke(a); assertTrue(owner.enabled()); owner.revoke(b); assertFalse(owner.enabled())
    }
    @Test fun nonOptedSourceCannotUseAnotherDeckOwnerBeforeOldClose() {
        val owner = Media3EqOptInOwner(); val a = Any(); val b = Any()
        assertTrue(owner.enable(a)); assertTrue(owner.enabledFor(a)); assertFalse(owner.enabledFor(b))
        owner.revoke(a); assertFalse(owner.enabledFor(b))
    }
}
