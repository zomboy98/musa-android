package xyz.luan.audioplayers.player

import android.content.Context
import android.media.AudioManager
import android.media.MediaPlayer
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.PlayerMode
import xyz.luan.audioplayers.PlayerMode.LOW_LATENCY
import xyz.luan.audioplayers.PlayerMode.MEDIA_PLAYER
import xyz.luan.audioplayers.ReleaseMode
import xyz.luan.audioplayers.source.Source
import xyz.luan.audioplayers.source.TimedProgressiveMediaSource
import kotlin.math.min

// For some reason this cannot be accessed from MediaPlayer.MEDIA_ERROR_SYSTEM
private const val MEDIA_ERROR_SYSTEM = -2147483648

class WrappedPlayer internal constructor(
    private val ref: AudioplayersPlugin,
    val eventHandler: EventHandler,
    var context: AudioContextAndroid,
    private val soundPoolManager: SoundPoolManager,
) {
    private var player: PlayerWrapper? = null
    private val dispatch = ref.playbackDispatcher()

    fun onPlaybackThread(action: () -> Unit) = dispatch(action)

    /** The player MediaPlayer starts the moment this one completes. */
    private var next: WrappedPlayer? = null

    private var equalizerEnabled = false
    private var pendingMedia3Equalizer: Map<String, Any?>? = null
    private var media3RetirementPending = false
    private val media3SessionEqForInstrumentation = Media3EqOptInOwner()
    private var media3SourceOwner: Any? = null
    internal fun enableMedia3SessionEqForInstrumentation(owner: Any) { check(media3SessionEqForInstrumentation.enable(owner)) { "Another deck owns instrumentation opt-in" } }
    internal fun disableMedia3SessionEqForInstrumentation(owner: Any) { media3SessionEqForInstrumentation.revoke(owner) }
    internal fun setMedia3SourceOwner(owner: Any) { media3SourceOwner = owner }
    internal fun retireUnconfirmedMedia3Effect() {
        if (!media3SessionEqForInstrumentation.enabledFor(media3SourceOwner) || !equalizerEnabled || media3RetirementPending) return
        media3RetirementPending = true
        onMedia3RetireRequested?.invoke() ?: onError(MediaPlayer.MEDIA_ERROR_UNKNOWN, MediaPlayer.MEDIA_ERROR_IO)
    }
    var onMedia3RetireRequested: (() -> Unit)? = null
    fun supportsExperimentalMedia3(): Boolean = supportsMedia3Progressive(playerMode == MEDIA_PLAYER, equalizerEnabled, balance)

    fun setEqualizer(configuration: Map<String, Any?>) {
        val enabled = configuration["enabled"] == true
        if (player is ExperimentalMedia3Output) {
            val media3 = player as? Media3ProgressivePlayer
            if (media3SessionEqForInstrumentation.enabledFor(media3SourceOwner) && media3 != null) {
                val applied = try { media3.configureSessionEffect(configuration) } catch (_: Exception) { false }
                if (applied) {
                    equalizerEnabled = enabled
                    pendingMedia3Equalizer = configuration.toMap()
                    return
                }
                val retire = checkNotNull(onMedia3RetireRequested) { "Experimental retirement unavailable" }
                equalizerEnabled = enabled
                pendingMedia3Equalizer = configuration.toMap()
                media3RetirementPending = true
                retire.invoke()
                return
            }
            val retire = if (enabled) checkNotNull(onMedia3RetireRequested) { "Experimental retirement unavailable" } else null
            equalizerEnabled = enabled
            pendingMedia3Equalizer = configuration.toMap()
            if (enabled) media3RetirementPending = true
            retire?.invoke()
            return
        }
        equalizerEnabled = enabled
        if (media3RetirementPending && player == null) pendingMedia3Equalizer = configuration.toMap()
        val output = player as? MediaPlayerWrapper
        if (output != null) output.setEqualizer(configuration)
    }

    /**
     * Chains [player], prepared and paused, to start as this source ends,
     * without a gap. Null unlinks it.
     */
    fun setNext(player: WrappedPlayer?) {
        val current = this.player as? MediaPlayerWrapper
        if (player == null) {
            next = null
            if (!released && current != null) current.setNext(null)
            return
        }
        check(!released && prepared && current != null) { "This player has no prepared source" }
        val following = player.player as? MediaPlayerWrapper
        check(!player.released && player.prepared && following != null) {
            "The next player has no prepared source"
        }
        current.setNext(following)
        next = player
    }

    /** MediaPlayer started this player as the previous one completed. */
    private fun continueAfterPrevious() {
        if (released || !prepared || playing) return
        playing = true
        requestFocusAndStart()
    }

    var source: Source? = null
        set(value) {
            if (field != value) {
                // Resetting MediaPlayer drops its link to the next player.
                next = null
                if (value != null) {
                    val media3 = value is TimedProgressiveMediaSource
                    if (media3) check(supportsExperimentalMedia3()) { "Experimental progressive settings unsupported" }
                    if ((player is ExperimentalMedia3Output) != media3) {
                        player?.release(); player = null; released = true; prepared = false
                    }
                    val player = if (media3 && (released || player == null)) {
                        Media3ProgressivePlayer(this).also { this.player = it; released = false }
                    } else getOrCreatePlayer()
                    player.setSource(value)
                    if (player is MediaPlayerWrapper) {
                        pendingMedia3Equalizer?.let { player.setEqualizer(it); pendingMedia3Equalizer = null }
                        media3RetirementPending = false
                    }
                    player.configAndPrepare()
                } else {
                    released = true
                    prepared = false
                    playing = false
                    player?.release()
                    player = null
                }
                field = value
            } else {
                ref.handlePrepared(this, true)
            }
        }

    var volume = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(value, balance)
                }
            }
        }

    var balance = 0.0f
        set(value) {
            if (field != value) {
                if (value != 0f && player is ExperimentalMedia3Output) {
                    val retire = checkNotNull(onMedia3RetireRequested) { "Experimental retirement unavailable" }
                    field = value
                    media3RetirementPending = true
                    retire()
                    return
                }
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(volume, value)
                }
            }
        }

    var rate = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (playing) {
                    player?.setRate(value)
                }
            }
        }

    var releaseMode = ReleaseMode.RELEASE
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setLooping(isLooping)
                }
            }
        }

    val isLooping: Boolean
        get() = releaseMode == ReleaseMode.LOOP

    var playerMode: PlayerMode = MEDIA_PLAYER
        set(value) {
            if (field != value) {
                field = value

                // if the player exists, we need to re-create it from scratch;
                // this will probably cause music to pause for a second
                player?.let {
                    shouldSeekTo = maybeGetCurrentPosition()
                    prepared = false
                    it.release()
                }
                initPlayer()
            }
        }

    var released = true

    var prepared: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                ref.handlePrepared(this, value)
            }
        }

    var playing = false
    var shouldSeekTo = -1

    private val focusManager = FocusManager.create(
        this,
        onGranted = {
            // Check if in playing state, as the focus can also be gained e.g. after a phone call, even if not playing.
            if (playing) {
                player?.start()
            }
        },
        onLoss = { isTransient ->
            if (isTransient) {
                // Do not check or set playing state, as the state should be recovered after granting focus again.
                player?.pause()
            } else {
                // Audio focus won't be recovered
                pause()
            }
        },
    )

    private fun maybeGetCurrentPosition(): Int {
        // for Sound Pool, we can't get current position, so we just start over
        return runCatching { player?.getCurrentPosition().takeUnless { it == 0 } }.getOrNull() ?: -1
    }

    private fun getOrCreatePlayer(): PlayerWrapper {
        val currentPlayer = player
        return if (released || currentPlayer == null) {
            createPlayer().also {
                player = it
                released = false
            }
        } else if (prepared) {
            currentPlayer.also {
                it.reset()
                prepared = false
            }
        } else {
            currentPlayer
        }
    }

    fun updateAudioContext(audioContext: AudioContextAndroid) {
        if (context == audioContext) {
            return
        }
        if (context.audioFocus != AudioManager.AUDIOFOCUS_NONE &&
            audioContext.audioFocus == AudioManager.AUDIOFOCUS_NONE
        ) {
            focusManager.handleStop()
        }
        // Changing player-only settings must not reset the system's audio route.
        if (context.audioMode != audioContext.audioMode) {
            audioManager.mode = audioContext.audioMode
        }
        if (context.isSpeakerphoneOn != audioContext.isSpeakerphoneOn) {
            audioManager.isSpeakerphoneOn = audioContext.isSpeakerphoneOn
        }
        this.context = audioContext.copy()

        player?.let { p ->
            p.stop()
            prepared = false
            // Context is only applied, once the player.reset() was called
            p.updateContext(context)
            source?.let {
                p.setSource(it)
                p.configAndPrepare()
            }
        }
    }

    // Getters

    /**
     * Returns the duration of the media in milliseconds, if available.
     */
    fun getDuration(): Int? {
        return if (prepared) player?.getDuration() else null
    }

    /**
     * Returns the current position of the playback in milliseconds, if available.
     */
    fun getCurrentPosition(): Int? {
        return if (prepared) player?.getCurrentPosition() else null
    }

    val applicationContext: Context
        get() = ref.getApplicationContext()

    val audioManager: AudioManager
        get() = ref.getAudioManager()

    /**
     * Playback handling methods
     */
    fun play() {
        if (!playing && !released) {
            playing = true
            if (player == null) {
                initPlayer()
            } else if (prepared) {
                requestFocusAndStart()
            }
        }
    }

    // Try to get audio focus and then start.
    private fun requestFocusAndStart() {
        focusManager.maybeRequestAudioFocus()
    }

    fun stop() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (releaseMode != ReleaseMode.RELEASE) {
            pause()
            if (prepared) {
                if (player?.isLiveStream() == true) {
                    player?.stop()
                    prepared = false
                    player?.prepare()
                } else {
                    // MediaPlayer does not allow to call player.seekTo after calling player.stop
                    seek(0)
                }
            }
        } else {
            release()
        }
    }

    fun release() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (playing) {
            player?.stop()
        }

        // Setting source to null will reset released, prepared and playing
        // and also calls player.release()
        source = null
        player = null
    }

    fun pause() {
        if (playing) {
            playing = false
            if (prepared) {
                player?.pause()
            }
        }
    }

    // seek operations cannot be called until after
    // the player is ready.
    fun seek(position: Int) {
        shouldSeekTo = if (prepared && player?.isLiveStream() != true) {
            player?.seekTo(position)
            -1
        } else {
            position
        }
    }

    /**
     * Player callbacks
     */
    fun onPrepared() {
        prepared = true
        ref.handleDuration(this)
        if (playing) {
            requestFocusAndStart()
        }
        if (shouldSeekTo >= 0 && player?.isLiveStream() != true) {
            player?.seekTo(shouldSeekTo)
        }
    }

    fun onCompletion() {
        val following = next
        next = null
        following?.continueAfterPrevious()
        if (releaseMode != ReleaseMode.LOOP) {
            stop()
        }
        ref.handleComplete(this)
    }

    @Suppress("UNUSED_PARAMETER")
    fun onBuffering(percent: Int) {
        // TODO(luan): expose this as a stream
    }

    fun onSeekComplete() {
        ref.handleSeekComplete(this)
    }

    fun handleLog(message: String) {
        ref.handleLog(this, message)
    }

    fun handleError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        ref.handleError(this, errorCode, errorMessage, errorDetails)
    }

    fun onError(what: Int, extra: Int): Boolean {
        val wasPrepared = prepared
        prepared = false
        playing = false
        focusManager.handleStop()
        val whatMsg = if (what == MediaPlayer.MEDIA_ERROR_SERVER_DIED) {
            "MEDIA_ERROR_SERVER_DIED"
        } else {
            "MEDIA_ERROR_UNKNOWN {what:$what}"
        }
        val extraMsg = when (extra) {
            MEDIA_ERROR_SYSTEM -> "MEDIA_ERROR_SYSTEM"
            MediaPlayer.MEDIA_ERROR_IO -> "MEDIA_ERROR_IO"
            MediaPlayer.MEDIA_ERROR_MALFORMED -> "MEDIA_ERROR_MALFORMED"
            MediaPlayer.MEDIA_ERROR_UNSUPPORTED -> "MEDIA_ERROR_UNSUPPORTED"
            MediaPlayer.MEDIA_ERROR_TIMED_OUT -> "MEDIA_ERROR_TIMED_OUT"
            else -> "MEDIA_ERROR_UNKNOWN {extra:$extra}"
        }
        handleError(
            "AndroidAudioError",
            if (wasPrepared) {
                "Android could not play this audio."
            } else {
                "Android could not open this audio source."
            },
            "$whatMsg, $extraMsg",
        )
        // An unhandled error also invokes OnCompletionListener, which would
        // incorrectly advance the application's queue after a playback failure.
        return true
    }

    /**
     * Internal logic. Private methods
     */

    /**
     * Create new player
     */
    private fun createPlayer(): PlayerWrapper {
        return when (playerMode) {
            MEDIA_PLAYER -> MediaPlayerWrapper(this)
            LOW_LATENCY -> SoundPoolPlayer(this, soundPoolManager)
        }
    }

    /**
     * Create new player, assign and configure source
     */
    private fun initPlayer() {
        val player = createPlayer()
        // Need to set player before calling prepare, as onPrepared may is called before player is assigned
        this.player = player
        source?.let {
            player.setSource(it)
            player.configAndPrepare()
        }
    }

    private fun PlayerWrapper.configAndPrepare() {
        setVolumeAndBalance(volume, balance)
        setLooping(isLooping)
        prepare()
    }

    private fun PlayerWrapper.setVolumeAndBalance(volume: Float, balance: Float) {
        val leftVolume = min(1f, 1f - balance) * volume
        val rightVolume = min(1f, 1f + balance) * volume
        setVolume(leftVolume, rightVolume)
    }

    fun dispose() {
        release()
        eventHandler.dispose()
    }
}


