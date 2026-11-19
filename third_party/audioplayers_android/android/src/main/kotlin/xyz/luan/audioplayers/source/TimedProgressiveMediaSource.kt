package xyz.luan.audioplayers.source

import android.media.MediaPlayer
import java.util.concurrent.atomic.AtomicBoolean
import xyz.luan.audioplayers.player.SoundPoolPlayer

/** A native capability; closing it revokes the owning progressive lease once. */
class TimedProgressiveMediaSource(
    val lease: TimedProgressiveLease,
    private val revoke: () -> Unit,
) : Source, AutoCloseable {
    private val closed = AtomicBoolean(false)
    override fun setForMediaPlayer(mediaPlayer: MediaPlayer): Unit = error("Media3 progressive source requires Media3")
    override fun setForSoundPool(soundPoolPlayer: SoundPoolPlayer): Unit = error("Media3 progressive source requires Media3")
    override fun close() { if (closed.compareAndSet(false, true)) revoke() }
}
