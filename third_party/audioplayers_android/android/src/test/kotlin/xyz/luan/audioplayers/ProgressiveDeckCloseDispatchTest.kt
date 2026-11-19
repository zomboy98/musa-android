package xyz.luan.audioplayers

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ProgressiveDeckCloseDispatchTest {
    @Test fun unavailableHandlerDoesNotConfirmPlayerDetach() {
        var emergency = 0; var detached = 0; var result: Pair<Int?, Boolean>? = null
        dispatchProgressiveDeckClose({ false }, { detached++; 42 }, { emergency++ }) { position, confirmed -> result = position to confirmed }
        assertEquals(1, emergency); assertEquals(0, detached); assertEquals(null to false, result)
    }

    @Test fun successfulDetachMayHaveNullPosition() {
        var task: (() -> Unit)? = null; var result: Pair<Int?, Boolean>? = null
        dispatchProgressiveDeckClose({ task = it; true }, { null }, { fail("unexpected emergency close") }) { position, confirmed -> result = position to confirmed }
        assertNull(result); checkNotNull(task).invoke(); assertEquals(null to true, result)
    }

    @Test fun throwingPostReportsUnconfirmedOnce() {
        val results = mutableListOf<Pair<Int?, Boolean>>(); var emergency = 0
        dispatchProgressiveDeckClose({ throw IllegalStateException() }, { 1 }, { emergency++ }) { p, ok -> results.add(p to ok) }
        assertEquals(1, emergency); assertEquals(listOf(null to false), results)
    }

    @Test fun throwingDetachReportsUnconfirmedOnce() {
        val results = mutableListOf<Pair<Int?, Boolean>>()
        dispatchProgressiveDeckClose({ it(); true }, { throw IllegalStateException() }, {}) { p, ok -> results.add(p to ok) }
        assertEquals(listOf(null to false), results)
    }

    @Test fun throwingEmergencyCloseStillReportsUnconfirmedOnce() {
        val results = mutableListOf<Pair<Int?, Boolean>>()
        dispatchProgressiveDeckClose({ false }, { 1 }, { throw IllegalStateException() }) { p, ok -> results.add(p to ok) }
        assertEquals(listOf(null to false), results)
    }

    @Test fun lateCallbackCanReenterFromAnotherThread() {
        val callbacks = ProgressiveDeckCloseCallbacks()
        assertTrue(callbacks.register { _, _ -> }); callbacks.finish(null, false)
        var reentered = false
        callbacks.register { _, _ ->
            val entered = CountDownLatch(1)
            Thread { callbacks.register { _, _ -> }; entered.countDown() }.apply { isDaemon = true; start() }
            reentered = entered.await(300, TimeUnit.MILLISECONDS)
        }
        assertTrue("late callback must not hold close monitor", reentered)
    }

    @Test fun callbacksAreDeliveredOnceAndLateSubscribersSeeOriginalStatus() {
        val callbacks = ProgressiveDeckCloseCallbacks(); val results = mutableListOf<Pair<Int?, Boolean>>()
        assertTrue(callbacks.register { p, ok -> results.add(p to ok) })
        assertFalse(callbacks.register { p, ok -> results.add(p to ok) })
        callbacks.finish(null, false); callbacks.finish(42, true)
        assertFalse(callbacks.register { p, ok -> results.add(p to ok) })
        assertEquals(List(3) { null to false }, results)
    }

    @Test fun detachFailureStillClosesSourceAndReportsUnconfirmed() {
        var closed = 0; val results = mutableListOf<Pair<Int?, Boolean>>()
        dispatchProgressiveDeckClose({ it(); true }, {
            detachProgressiveSource({ throw IllegalStateException("detach") }, { closed++ })
        }, {}) { p, ok -> results.add(p to ok) }
        assertEquals(1, closed); assertEquals(listOf(null to false), results)
    }
}
