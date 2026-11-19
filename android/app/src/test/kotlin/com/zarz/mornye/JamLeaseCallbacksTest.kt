package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Test

class JamLeaseCallbacksTest {
    @Test fun concurrentStartsBothCompleteOnce() {
        val pending = JamLeaseCallbacks()
        val results = mutableListOf<String>()
        pending.add { results.add("first:$it") }
        pending.add { results.add("second:$it") }
        pending.complete(true)
        pending.complete(false)
        assertEquals(listOf("first:true", "second:true"), results)
    }

    @Test fun destroyedBeforePromotionFailsAllWaiters() {
        val pending = JamLeaseCallbacks()
        val results = mutableListOf<Boolean>()
        pending.add { results.add(it) }
        pending.add { results.add(it) }
        pending.complete(false)
        assertEquals(listOf(false, false), results)
    }
}
