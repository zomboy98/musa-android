package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test

class ProgressiveDeckRegistryTest {
    private class Lease : ProgressiveAudioLease {
        var closes = 0
        override fun readAt(position: Long, maxBytes: Int, timeoutMs: Int) = ProgressiveRead.End
        override fun size(): Long? = null
        override fun close() { closes++ }
    }

    @Test fun disabledRejectsAndClosesCapability() {
        val registry = ProgressiveDeckRegistry()
        val lease = Lease()
        assertFalse(registry.attach(ProgressiveDeckKey(), lease))
        assertEquals(1, lease.closes)
    }

    @Test fun keysAreOpaqueAndDeckReleaseRevokesOnlyItsOwnLease() {
        val registry = ProgressiveDeckRegistry(enabledForTesting = true)
        val first = ProgressiveDeckKey()
        val second = ProgressiveDeckKey()
        val a = Lease()
        val b = Lease()
        assertTrue(registry.attach(first, a))
        assertTrue(registry.attach(second, b))
        assertSame(a, registry.lookup(first))
        assertNull(registry.lookup(ProgressiveDeckKey()))
        registry.release(first)
        registry.release(first)
        assertNull(registry.lookup(first))
        assertEquals(1, a.closes)
        assertEquals(0, b.closes)
        registry.close()
        assertEquals(1, b.closes)
    }

    @Test fun replacementRevokesOldLeaseAndClosedRegistryRejectsNew() {
        val registry = ProgressiveDeckRegistry(enabledForTesting = true)
        val key = ProgressiveDeckKey()
        val a = Lease()
        val b = Lease()
        assertTrue(registry.attach(key, a))
        assertTrue(registry.attach(key, b))
        assertEquals(1, a.closes)
        assertSame(b, registry.lookup(key))
        registry.close()
        val late = Lease()
        assertFalse(registry.attach(key, late))
        assertEquals(1, late.closes)
    }
}
