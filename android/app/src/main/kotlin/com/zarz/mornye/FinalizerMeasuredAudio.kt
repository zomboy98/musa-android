package com.zarz.mornye

/** Values from the final-file probe only; provider and request metadata do not belong here. */
internal data class FinalizerMeasuredAudio(
    val codec: String?,
    val bitDepth: Int?,
    val sampleRate: Int?,
    val bitrateKbps: Int?,
) {
    fun historyQuality(): String? = NativeFinalizationPolicy.displayAudioQuality(
        filePath = "", fileName = "", bitDepth = bitDepth,
        sampleRate = sampleRate, bitrateKbps = bitrateKbps,
        audioCodec = codec, storedQuality = null,
    )

    fun qualityVariantLabel(): String? {
        val normalized = NativeFinalizationPolicy.normalizeAudioCodec(codec)
        if (normalized == "m4a" ||
            (!NativeFinalizationPolicy.isLossyAudioCodec(normalized) &&
                !NativeFinalizationPolicy.isLosslessAudioCodec(normalized))
        ) return null
        return NativeFinalizationPolicy.qualityVariantFilenameLabel(
            measuredQuality = "", bitDepth = bitDepth, sampleRate = sampleRate,
            bitrateKbps = bitrateKbps, audioCodec = normalized,
        )
    }

    companion object {
        fun fromProbe(
            fromFilename: Boolean,
            codec: String?,
            bitDepth: Int?,
            sampleRate: Int?,
            bitrateKbps: Int?,
        ): FinalizerMeasuredAudio? {
            if (fromFilename) return null
            return FinalizerMeasuredAudio(
                codec = codec?.trim()?.takeIf { it.isNotEmpty() },
                bitDepth = bitDepth?.takeIf { it > 0 },
                sampleRate = sampleRate?.takeIf { it > 0 },
                bitrateKbps = bitrateKbps?.takeIf { it >= 16 },
            )
        }
    }
}

/** Replace all final-audio claims together so stale aliases cannot survive a partial probe. */
internal fun finalAudioResultFields(measured: FinalizerMeasuredAudio?): Map<String, Any> = buildMap {
    measured?.historyQuality()?.let { put("quality", it) }
    measured?.codec?.let { put("audio_codec", it); put("format", it) }
    measured?.bitDepth?.let { put("actual_bit_depth", it) }
    measured?.sampleRate?.let { put("actual_sample_rate", it) }
    measured?.bitrateKbps?.let { put("bitrate", it); put("actual_bitrate", it) }
}

internal val finalAudioResultKeys = listOf(
    "quality", "audio_codec", "actual_audio_codec", "format",
    "bit_depth", "sample_rate", "actual_bit_depth", "actual_sample_rate",
    "bitrate", "actual_bitrate",
)
