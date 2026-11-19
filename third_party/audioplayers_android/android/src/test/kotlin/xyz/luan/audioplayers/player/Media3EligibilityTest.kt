package xyz.luan.audioplayers.player

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class Media3EligibilityTest {
    @Test fun rejectsSettingsMedia3CannotPreserve() {
        assertTrue(supportsMedia3Progressive(true, false, 0f))
        assertFalse(supportsMedia3Progressive(false, false, 0f))
        assertFalse(supportsMedia3Progressive(true, true, 0f))
        assertFalse(supportsMedia3Progressive(true, false, 0.5f))
        assertFalse(supportsMedia3Progressive(true, false, Float.NaN))
    }
}
