package xyz.luan.audioplayers.player

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Test

class Media3ProgressiveLiveContractTest {
    @Test fun leaseIsNeverLiveEvenWhenMedia3FlagsItLive() {
        assertFalse(leaseIsLive(true))
        assertFalse(leaseIsLive(false))
    }
}
