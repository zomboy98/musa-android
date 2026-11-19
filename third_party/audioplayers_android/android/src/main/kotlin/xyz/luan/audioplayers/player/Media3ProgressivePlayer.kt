package xyz.luan.audioplayers.player

import android.media.MediaPlayer
import android.net.Uri
import android.os.Looper
import android.os.Build
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.source.Source
import xyz.luan.audioplayers.source.TimedProgressiveMediaSource
import xyz.luan.audioplayers.source.WissStreamEngine

/** Native progressive playback through the byte engine (lease -> cache -> Media3). The old cursor path is retired. The caller owns focus and the source capability. */
internal class Media3ProgressivePlayer(private val wrapped: WrappedPlayer) : PlayerWrapper, ExperimentalMedia3Output {
    private var retired = false
    private var reportedReady = false
    private var engine: WissStreamEngine? = null
    private val effectGeneration = 1L
    private val effects = Media3EffectSessionController { session ->
        check(Build.VERSION.SDK_INT >= 28) { "Equalizer requires Android 9 or later" }
        val equalizer = PlaybackEqualizer(session)
        object : Media3SessionEffect {
            override fun configure(config: Map<String, Any?>) = equalizer.configure(config)
            override fun close() = equalizer.close()
        }
    }
    private val player: ExoPlayer = ExoPlayer.Builder(
        wrapped.applicationContext,
        DefaultRenderersFactory(wrapped.applicationContext).setEnableDecoderFallback(true),
    )
        .setLooper(checkNotNull(Looper.myLooper()))
        .setAudioAttributes(attributes(wrapped.context), false)
        .build()
    init {
        player.addListener(object : Player.Listener {
            override fun onAudioSessionIdChanged(audioSessionId: Int) {
                if (!retired) {
                    try {
                        if (!effects.onSessionConfirmed(audioSessionId, effectGeneration)) wrapped.retireUnconfirmedMedia3Effect()
                    } catch (_: Exception) { wrapped.retireUnconfirmedMedia3Effect() }
                }
            }
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (retired) return
                when (playbackState) {
                    Player.STATE_READY -> if (!reportedReady) { reportedReady = true; wrapped.onPrepared() }
                    Player.STATE_ENDED -> wrapped.onCompletion()
                }
            }
            override fun onPlayerError(error: PlaybackException) {
                if (!retired) wrapped.onError(MediaPlayer.MEDIA_ERROR_UNKNOWN, MediaPlayer.MEDIA_ERROR_IO)
            }
            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
                if (!retired && reason == Player.DISCONTINUITY_REASON_SEEK) wrapped.onSeekComplete()
            }
        })
        effects.onSession(player.audioSessionId, effectGeneration)
    }
    /** Returns true only after the effect configuration completed on a valid session. */
    internal fun configureSessionEffect(configuration: Map<String, Any?>): Boolean = effects.configureConfirmed(configuration)
    override fun setSource(source: Source) {
        require(source is TimedProgressiveMediaSource)
        reportedReady = false
        engine?.close()
        val nuevo = WissStreamEngine(wrapped.applicationContext.cacheDir, source.lease)
        engine = nuevo
        val factory = ProgressiveMediaSource.Factory(nuevo.factory)
        player.setMediaSource(factory.createMediaSource(MediaItem.fromUri(Uri.parse("wiss://stream/audio"))))
    }
    override fun prepare() { player.prepare() }
    override fun start() { player.play() }
    override fun pause() { player.pause() }
    override fun stop() { player.stop() }
    override fun seekTo(position: Int) { player.seekTo(position.toLong()) }
    override fun setVolume(leftVolume: Float, rightVolume: Float) {
        require(leftVolume == rightVolume) { "Media3 progressive balance unsupported" }
        player.volume = leftVolume
    }
    override fun setRate(rate: Float) { player.setPlaybackSpeed(rate) }
    override fun setLooping(looping: Boolean) { player.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF }
    override fun updateContext(context: AudioContextAndroid) { player.setAudioAttributes(attributes(context), false) }
    override fun getDuration(): Int? = player.duration.takeUnless { it == C.TIME_UNSET || it < 0 || it > Int.MAX_VALUE }?.toInt()
    override fun getCurrentPosition(): Int? = player.currentPosition.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.toInt()
    // A finite lease is never radio: LENGTH_UNSET before commit makes Media3 flag the item live, which would defer seeks forever.
    override fun isLiveStream(): Boolean = leaseIsLive(player.isCurrentMediaItemLive)
    override fun reset() { reportedReady = false; player.stop(); player.clearMediaItems(); engine?.close(); engine = null }
    override fun release() { if (!retired) { retired = true; try { effects.release() } finally { try { player.release() } finally { engine?.close(); engine = null } } } }

    private companion object {
        fun attributes(context: AudioContextAndroid): AudioAttributes = AudioAttributes.Builder()
            .setUsage(context.usageType).setContentType(context.contentType).build()
    }
}

/** Progressive leases have finite transfer; "size unknown yet" reported by Media3 as live is not live. */
internal fun leaseIsLive(@Suppress("UNUSED_PARAMETER") media3ReportsLive: Boolean): Boolean = false
