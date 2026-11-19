package com.zarz.mornye

import org.junit.Assert.assertSame
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import java.util.concurrent.ConcurrentHashMap
import org.junit.Test

class ProgressiveChannelInstrumentationTest {
    @Test fun nonDebugInjectionIsRejectedBeforeProducerCanBeUsed() {
        var producerCalls = 0
        val options = ProgressiveChannelInstrumentation { _, _ ->
            producerCalls++
            error("Producer must not run during admission")
        }
        try {
            options.requireDebuggable(false)
            fail("Non-debug instrumentation must be rejected")
        } catch (_: IllegalStateException) { }
        assertEquals(0, producerCalls)
    }

    @Test fun debugValidationPreservesOnlyThisInstanceAndDoesNotStartProducer() {
        var producerCalls = 0
        val options = ProgressiveChannelInstrumentation { _, _ ->
            producerCalls++
            error("Producer must not run during admission")
        }
        assertSame(options, options.requireDebuggable(true))
        assertEquals(0, producerCalls)
        try {
            options.requireDebuggable(false)
            fail("Prior debug validation must not grant later non-debug admission")
        } catch (_: IllegalStateException) { }
    }

    // Reflect across the plugin module's Kotlin internal boundary, exercising the
    // actual compiled admission/registry helpers rather than a copied test model.
    private val pluginFunctions get() = Class.forName("xyz.luan.audioplayers.AudioplayersPluginKt")
    private fun media3(ready: Boolean, enabled: Boolean, optIn: Boolean, debug: Boolean) =
        pluginFunctions.getDeclaredMethod("permitsInstrumentedMedia3",
            Boolean::class.javaPrimitiveType, Boolean::class.javaPrimitiveType,
            Boolean::class.javaPrimitiveType, Boolean::class.javaPrimitiveType)
            .invoke(null, ready, enabled, optIn, debug) as Boolean

    @Test fun runtimeGateRemainsFalse() {
        val field = Class.forName("xyz.luan.audioplayers.AudioplayersPlugin")
            .getDeclaredField("MEDIA3_PROGRESSIVE_RUNTIME_READY").apply { isAccessible = true }
        assertFalse(field.getBoolean(null))
    }

    @Test fun ordinaryDebugAndReleaseCannotOptInToUnreadyMedia3() {
        assertFalse(media3(false, true, false, true))
        assertFalse(media3(false, true, true, false))
        assertFalse(media3(false, false, true, true))
        assertTrue(media3(false, true, true, true))
        assertFalse(media3(false, true, false, true))
    }

    @Test fun requestAdmissionIsDebugOnlyAndCannotBecomeSticky() {
        val method = pluginFunctions.getDeclaredMethod("permitsExperimentalProgressive",
            Boolean::class.javaPrimitiveType, Boolean::class.javaPrimitiveType,
            Boolean::class.javaPrimitiveType)
        fun admit(configured: Boolean, request: Boolean, debug: Boolean) =
            method.invoke(null, configured, request, debug) as Boolean
        assertFalse(admit(false, true, false))
        assertTrue(admit(false, true, true))
        assertFalse(admit(false, false, true))
        // Native configuration that existed before a channel remains valid.
        assertTrue(admit(true, false, true))
    }

    private fun register(map: ConcurrentHashMap<String, Any>, value: Any,
        close: (Any) -> Unit): Boolean =
        pluginFunctions.declaredMethods.single { it.name == "registerProgressiveDeck" }
            .invoke(null, map, "player", value, false, close) as Boolean

    @Test fun duplicatePlayerClaimDoesNotReplaceOrCloseExistingDeck() {
        val map = ConcurrentHashMap<String, Any>()
        val first = Any()
        val rejected = Any()
        val closed = mutableListOf<Any>()
        assertTrue(register(map, first) { closed.add(it) })
        assertFalse(register(map, rejected) { closed.add(it) })
        assertSame(first, map["player"])
        assertEquals(listOf(rejected), closed)
        // Delayed rejected-deck cleanup cannot remove the accepted capability.
        assertFalse(map.remove("player", rejected))
        assertSame(first, map["player"])
    }

    @Test fun exceptionClosingRejectedClaimLeavesOriginalDeckRegistered() {
        val first = Any()
        val map = ConcurrentHashMap<String, Any>().apply { put("player", first) }
        try {
            register(map, Any()) { error("synthetic rejected-close failure") }
            fail("Expected synthetic close failure")
        } catch (_: java.lang.reflect.InvocationTargetException) { }
        assertSame(first, map["player"])
    }

    @Test fun concurrentPlayerClaimsHaveExactlyOneWinner() {
        val map = ConcurrentHashMap<String, Any>()
        val barrier = java.util.concurrent.CountDownLatch(1)
        val done = java.util.concurrent.CountDownLatch(2)
        val winners = java.util.concurrent.atomic.AtomicInteger()
        val closed = java.util.concurrent.atomic.AtomicInteger()
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
        val workers = (1..2).map {
            Thread {
                try {
                    check(barrier.await(2, java.util.concurrent.TimeUnit.SECONDS))
                    if (register(map, Any()) { closed.incrementAndGet() }) winners.incrementAndGet()
                } catch (t: Throwable) { failure.compareAndSet(null, t) }
                finally { done.countDown() }
            }.apply { start() }
        }
        try {
            barrier.countDown()
            assertTrue(done.await(5, java.util.concurrent.TimeUnit.SECONDS))
            failure.get()?.let { throw it }
            assertEquals(1, winners.get())
            assertEquals(1, closed.get())
            assertEquals(1, map.size)
        } finally {
            barrier.countDown()
            workers.forEach { it.join(1000) }
        }
    }
}
