package com.zarz.mornye

import android.media.MediaDataSource

/** Experimental injection point; no production player registers an implementation. */
internal interface ProgressiveMediaDeck {
    fun open(source: MediaDataSource)
    fun discard()
}

internal class ProgressiveMediaDeckAdapter(private val deck: ProgressiveMediaDeck) : ProgressiveControllerDeck {
    override fun open(lease: ProgressiveAudioLease) {
        val source = ProgressiveLeaseMediaDataSource(lease)
        try { deck.open(source) } catch (error: Exception) { source.close(); throw error }
    }
    override fun discard() = deck.discard()
}
