package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test

class FinalizerMeasuredAudioTest {
    @Test
    fun filenameFallbackCannotSupplyMeasurements() {
        assertNull(FinalizerMeasuredAudio.fromProbe(true, "flac", 24, 96000, 320))
    }

    @Test
    fun partialProbeDoesNotInventRequestedQualityOrFields() {
        val audio = FinalizerMeasuredAudio.fromProbe(false, null, null, null, null)!!
        assertNull(audio.historyQuality())
        assertNull(audio.codec)
        assertNull(audio.bitrateKbps)
        val invalid = FinalizerMeasuredAudio.fromProbe(false, " ", -1, 0, 15)!!
        assertNull(invalid.historyQuality())
        assertNull(invalid.bitDepth)
        assertNull(invalid.sampleRate)
        assertNull(invalid.bitrateKbps)
    }

    @Test
    fun historyUsesOnlyMeasurementsPresentInFinalProbe() {
        val flac = FinalizerMeasuredAudio.fromProbe(false, "flac", 16, 44100, null)!!
        assertEquals("16-bit/44.1kHz", flac.historyQuality())
        val aac = FinalizerMeasuredAudio.fromProbe(false, "aac", null, null, 256)!!
        assertEquals("AAC 256kbps", aac.historyQuality())
        val codecOnly = FinalizerMeasuredAudio.fromProbe(false, "aac", null, null, null)!!
        assertEquals("AAC", codecOnly.historyQuality())
        assertNull(codecOnly.bitrateKbps)
    }

    @Test
    fun samePathReprobeDoesNotReusePreviousMeasurements() {
        val rows = mutableMapOf("/music/track.flac" to FinalizerMeasuredAudio.fromProbe(false, "flac", 24, 96000, null))
        // A path may have been replaced and older rows do not record provenance.
        rows["/music/track.flac"] = FinalizerMeasuredAudio.fromProbe(false, null, null, null, null)
        assertNull(rows.getValue("/music/track.flac")?.historyQuality())
        assertNull(rows.getValue("/music/track.flac")?.codec)
    }

    @Test
    fun differentPathPartialProbeDoesNotReusePreviousMeasurements() {
        val previous = FinalizerMeasuredAudio.fromProbe(false, "flac", 24, 96000, null)!!
        val current = FinalizerMeasuredAudio.fromProbe(false, "aac", null, null, null)!!
        val rows = mapOf("/music/old.flac" to previous, "/music/new.m4a" to current)
        assertEquals("AAC", rows.getValue("/music/new.m4a").historyQuality())
        assertNull(rows.getValue("/music/new.m4a").bitDepth)
        assertNull(rows.getValue("/music/new.m4a").sampleRate)
        assertNull(rows.getValue("/music/new.m4a").bitrateKbps)
    }

    @Test
    fun resultFieldsContainOnlyFinalMeasurements() {
        assertTrue(finalAudioResultFields(null).isEmpty())
        assertTrue(finalAudioResultFields(FinalizerMeasuredAudio.fromProbe(true, "flac", 24, 96000, 320)).isEmpty())
        val partial = finalAudioResultFields(FinalizerMeasuredAudio.fromProbe(false, "aac", null, null, null))
        assertEquals(mapOf("quality" to "AAC", "audio_codec" to "aac", "format" to "aac"), partial)
        assertTrue("actual_audio_codec" in finalAudioResultKeys)
        assertTrue("bit_depth" in finalAudioResultKeys)
        assertTrue("actual_bitrate" in finalAudioResultKeys)
        val full = finalAudioResultFields(FinalizerMeasuredAudio.fromProbe(false, "aac", null, 48000, 256))
        assertEquals(256, full["bitrate"])
        assertEquals(256, full["actual_bitrate"])
        assertEquals(48000, full["actual_sample_rate"])
        assertEquals("AAC 256kbps", full["quality"])
    }

    @Test
    fun variantLabelRequiresFinalProbeAndCompleteRelevantMeasurements() {
        val filenameOnly = FinalizerMeasuredAudio.fromProbe(true, "flac", 24, 96000, 320)
        assertNull(filenameOnly?.qualityVariantLabel())
        assertNull(FinalizerMeasuredAudio.fromProbe(false, null, null, null, null)?.qualityVariantLabel())
        assertNull(FinalizerMeasuredAudio.fromProbe(false, "flac", 24, null, null)?.qualityVariantLabel())
        assertNull(FinalizerMeasuredAudio.fromProbe(false, "aac", 24, 96000, null)?.qualityVariantLabel())
        assertNull(FinalizerMeasuredAudio.fromProbe(false, null, 24, 96000, 320)?.qualityVariantLabel())
        assertNull(FinalizerMeasuredAudio.fromProbe(false, "m4a", 24, 96000, 320)?.qualityVariantLabel())
        assertEquals("256kbps", FinalizerMeasuredAudio.fromProbe(false, "aac", 24, 96000, 256)?.qualityVariantLabel())
        assertEquals("16bit-44.1kHz", FinalizerMeasuredAudio.fromProbe(false, "flac", 16, 44100, null)?.qualityVariantLabel())
    }
}
