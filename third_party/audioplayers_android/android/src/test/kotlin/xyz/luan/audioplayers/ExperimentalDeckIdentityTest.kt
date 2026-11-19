package xyz.luan.audioplayers

import org.junit.Assert.*
import org.junit.Test

class ExperimentalDeckIdentityTest {
    @Test fun capabilityCannotCrossDeckOrEngineGeneration() {
        val first = Any(); val second = Any()
        val identity = ExperimentalDeckIdentity(first, 3)
        assertTrue(identity.valid(first, 3))
        assertFalse(identity.valid(second, 3))
        assertFalse(identity.valid(first, 4))
        assertFalse(identity.valid(null, 3))
    }

    @Test fun revocationIsImmediateAndIdempotent() {
        val player = Any(); val identity = ExperimentalDeckIdentity(player, 0)
        assertTrue(identity.close())
        assertFalse(identity.valid(player, 0))
        assertFalse(identity.close())
    }
}
