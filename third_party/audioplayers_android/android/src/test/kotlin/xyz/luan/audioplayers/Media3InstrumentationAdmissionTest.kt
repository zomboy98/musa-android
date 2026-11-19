package xyz.luan.audioplayers

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class Media3InstrumentationAdmissionTest {
    @Test fun runtimeGateRemainsClosed() {
        val field = AudioplayersPlugin::class.java.getDeclaredField("MEDIA3_PROGRESSIVE_RUNTIME_READY")
        field.isAccessible = true
        assertFalse(field.getBoolean(null), "This test must not silently enable the normal runtime path")
    }

    @Test fun debugAndExperimentalChannelDoNotImplicitlyOptIn() {
        assertFalse(permitsInstrumentedMedia3(false, true, false, true))
        assertFalse(permitsInstrumentedMedia3(false, false, false, true))
    }

    @Test fun instrumentationOptInCannotAdmitNonDebugApplication() {
        assertFalse(permitsInstrumentedMedia3(false, true, true, false))
    }

    @Test fun optInDoesNotReplaceExperimentalCapability() {
        assertFalse(permitsInstrumentedMedia3(false, false, true, true))
    }

    @Test fun explicitDebugInstrumentationCanUseRealDeckWhileRuntimeGateStaysClosed() {
        assertTrue(permitsInstrumentedMedia3(false, true, true, true))
    }

    @Test fun admissionIsEvaluatedPerInstanceWithoutStickyEnablement() {
        assertTrue(permitsInstrumentedMedia3(false, true, true, true))
        assertFalse(permitsInstrumentedMedia3(false, true, false, true))
        assertFalse(permitsInstrumentedMedia3(false, true, true, false))
    }
}
