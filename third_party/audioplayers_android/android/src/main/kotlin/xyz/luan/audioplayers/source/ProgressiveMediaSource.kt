package xyz.luan.audioplayers.source

import android.media.MediaDataSource
import android.media.MediaPlayer
import xyz.luan.audioplayers.player.SoundPoolPlayer

/** Native capability only. It is never addressable by path or method-channel token. */
class ProgressiveMediaSource(private val data: MediaDataSource) : Source, AutoCloseable {
    override fun setForMediaPlayer(mediaPlayer: MediaPlayer) = mediaPlayer.setDataSource(data)
    override fun setForSoundPool(soundPoolPlayer: SoundPoolPlayer): Unit =
        error("Progressive sources require MediaPlayer")
    override fun close() = data.close()
}
