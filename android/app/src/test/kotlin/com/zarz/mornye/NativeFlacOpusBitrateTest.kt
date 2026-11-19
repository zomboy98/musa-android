package com.zarz.mornye

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NativeFlacOpusBitrateTest {
    @get:Rule val files = TemporaryFolder()

    private fun streamInfo(channels: Int): ByteArray = ByteArray(42).apply {
        "fLaC".encodeToByteArray().copyInto(this)
        this[4] = 0x80.toByte() // Final metadata block, type STREAMINFO.
        this[7] = 34
        this[8] = 0x10
        this[10] = 0x10
        this[18] = 0x0B
        this[19] = 0xB8.toByte()
        this[20] = (((channels - 1) shl 1) or 1).toByte()
        this[21] = 0xF0.toByte() // 48 kHz, 32-bit samples.
    }

    @Test fun capsOnlyThe320KbpsTargetForNativeMono() {
        val mono = files.newFile("mono.flac").apply { writeBytes(streamInfo(1)) }
        val stereo = files.newFile("stereo.flac").apply { writeBytes(streamInfo(2)) }
        assertEquals(256, nativeFlacOpusBitrateKbps(mono.path, 320))
        assertEquals(256, nativeFlacOpusBitrateKbps(mono.path, 256))
        assertEquals(160, nativeFlacOpusBitrateKbps(mono.path, 160))
        assertEquals(320, nativeFlacOpusBitrateKbps(stereo.path, 320))
    }

    @Test fun keepsRequestedRateWhenStreamInfoCannotBeEstablished() {
        val source = files.newFile("suspect.flac")
        for (header in listOf(
            "OggS".encodeToByteArray(),
            streamInfo(1).copyOf(41),
            streamInfo(1).apply { this[4] = 1 },
            streamInfo(1).apply { this[7] = 33 },
            streamInfo(1).apply { this[8] = 0 },
            streamInfo(1).apply { this[18] = 0; this[19] = 0 },
        )) {
            source.writeBytes(header)
            assertEquals(320, nativeFlacOpusBitrateKbps(source.path, 320))
        }
        assertEquals(320, nativeFlacOpusBitrateKbps("content://provider/mono.flac", 320))
        assertEquals(320, nativeFlacOpusBitrateKbps(File(files.root, "missing.flac").path, 320))
    }
}
