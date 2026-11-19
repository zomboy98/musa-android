package xyz.luan.audioplayers

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.BytesSource
import xyz.luan.audioplayers.source.UrlSource
import xyz.luan.audioplayers.source.ProgressiveMediaSource
import xyz.luan.audioplayers.source.Source
import xyz.luan.audioplayers.source.TimedProgressiveLease
import xyz.luan.audioplayers.source.TimedProgressiveMediaSource
import android.media.MediaDataSource
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap

typealias FlutterHandler = (call: MethodCall, response: MethodChannel.Result) -> Unit

/** Per-request native admission never changes a plugin's pre-existing configuration. */
internal fun permitsExperimentalProgressive(configured: Boolean, nativeRequest: Boolean, debuggable: Boolean) =
    configured || (nativeRequest && debuggable)

/** Native constructor injection only; never accepted from a MethodChannel payload. */
internal fun permitsInstrumentedMedia3(
    runtimeReady: Boolean,
    experimentalEnabled: Boolean,
    instrumentationOptIn: Boolean,
    debuggable: Boolean,
): Boolean = experimentalEnabled && (runtimeReady || (instrumentationOptIn && debuggable))

/** Atomic registration; rejected claims never revoke the existing capability. */
internal fun <T : Any> registerProgressiveDeck(
    decks: ConcurrentHashMap<String, T>, playerId: String, capability: T,
    replaceExisting: Boolean, close: (T) -> Unit,
): Boolean {
    if (replaceExisting) {
        decks.put(playerId, capability)?.let(close)
        return true
    }
    if (decks.putIfAbsent(playerId, capability) == null) return true
    close(capability)
    return false
}

class AudioplayersPlugin(
    private var experimentalProgressiveForTesting: Boolean = false,
    private val allowUnreadyMedia3ForInstrumentation: Boolean = false,
) : FlutterPlugin {
    private lateinit var methods: MethodChannel
    private lateinit var globalMethods: MethodChannel
    private lateinit var globalEvents: EventHandler
    private lateinit var context: Context
    private lateinit var binaryMessenger: BinaryMessenger
    private lateinit var soundPoolManager: SoundPoolManager

    private var players = ConcurrentHashMap<String, WrappedPlayer>()
    private val experimentalDecks = ConcurrentHashMap<String, ExperimentalProgressiveDeck>()
    private companion object { const val MEDIA3_PROGRESSIVE_RUNTIME_READY = true }
    private var defaultAudioContext = AudioContextAndroid()
    private var playbackThread: HandlerThread? = null
    private var playbackHandler: Handler? = null
    @Volatile private var generation = 0

    /** Native capability; request-scoped admission is debug-only and never read from Dart. */
    fun experimentalProgressiveDeck(playerId: String, useMedia3: Boolean = false, replaceExisting: Boolean = true, experimentalRequest: Boolean = false): ExperimentalProgressiveDeck? {
        val debuggable = this::context.isInitialized &&
            context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        val admitted = permitsExperimentalProgressive(experimentalProgressiveForTesting, experimentalRequest, debuggable)
        if (!admitted) return null
        // Fail closed until live EQ/balance changes preserve position and pause.
        if (useMedia3 && !permitsInstrumentedMedia3(
                MEDIA3_PROGRESSIVE_RUNTIME_READY,
                admitted,
                allowUnreadyMedia3ForInstrumentation,
                debuggable,
            )) return null
        val target = players[playerId] ?: return null
        val capability = ExperimentalProgressiveDeck(target, playerId, generation, useMedia3)
        return if (registerProgressiveDeck(experimentalDecks, playerId, capability, replaceExisting) { it.close() })
            capability else null
    }

    /** Native test configuration only; no method-channel entry exposes this switch. */
    fun setExperimentalProgressiveForTesting(enabled: Boolean) {
        experimentalProgressiveForTesting = enabled
        if (!enabled) { experimentalDecks.values.forEach { it.close() }; experimentalDecks.clear() }
    }

    inner class ExperimentalProgressiveDeck internal constructor(
        private val player: WrappedPlayer,
        private val playerId: String,
        private val epoch: Int,
        val useMedia3: Boolean,
    ) {
        internal fun owns(candidate: WrappedPlayer): Boolean = player === candidate
        private val identity = ExperimentalDeckIdentity(player, epoch)
        @Volatile private var source: Source? = null
        private val closeCallbacks = ProgressiveDeckCloseCallbacks()
        @Volatile var onRetireRequested: (() -> Unit)? = null
        private val retireCallback: () -> Unit = { onRetireRequested?.invoke() }

        /** Native instrumentation-only opt-in; never exposed through a method channel. */
        fun enableSessionEqForInstrumentation() {
            check(allowUnreadyMedia3ForInstrumentation && this@AudioplayersPlugin::context.isInitialized &&
                context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) { "Instrumentation-only capability" }
            check(useMedia3 && experimentalDecks[playerId] === this && identity.valid(players[playerId], generation)) { "Progressive deck unavailable" }
            player.enableMedia3SessionEqForInstrumentation(this)
            if (experimentalDecks[playerId] !== this || !identity.valid(players[playerId], generation)) {
                player.disableMedia3SessionEqForInstrumentation(this)
                error("Progressive deck unavailable")
            }
        }

        /** Callback means the source was accepted for preparation, not that audio played. */
        fun attach(data: MediaDataSource, callback: (Boolean) -> Unit) {
            val accepted = playbackHandler?.post {
                if (!identity.valid(players[playerId], generation)) {
                    data.close(); callback(false); return@post
                }
                val value = ProgressiveMediaSource(data)
                try {
                    player.source = value
                    source = value
                    callback(true)
                } catch (_: Exception) {
                    value.close()
                    callback(false)
                }
            } == true
            if (!accepted) { data.close(); callback(false) }
        }

        fun attachTimed(lease: TimedProgressiveLease, revoke: () -> Unit, callback: (Boolean) -> Unit) {
            val accepted = playbackHandler?.post {
                if (!identity.valid(players[playerId], generation) || !useMedia3 || !player.supportsExperimentalMedia3()) {
                    revoke(); callback(false); return@post
                }
                val value = TimedProgressiveMediaSource(lease, revoke)
                try { player.setMedia3SourceOwner(this); player.onMedia3RetireRequested = retireCallback; player.source = value; source = value; callback(true) }
                catch (_: Exception) { if (player.onMedia3RetireRequested === retireCallback) player.onMedia3RetireRequested = null; value.close(); callback(false) }
            } == true
            if (!accepted) { revoke(); callback(false) }
        }

        fun close(onClosed: (Int?) -> Unit = {}) {
            closeWithStatus { position, _ -> onClosed(position) }
        }

        /** Confirmation means the player-thread detach ran; null is a valid position. */
        fun closeWithStatus(onClosed: (Int?, Boolean) -> Unit) {
            if (!closeCallbacks.register(onClosed)) return
            identity.close()
            player.disableMedia3SessionEqForInstrumentation(this)
            fun finish(position: Int?, confirmed: Boolean) {
                experimentalDecks.remove(playerId, this)
                closeCallbacks.finish(position, confirmed)
            }
            dispatchProgressiveDeckClose({ task -> playbackHandler?.post(task) == true }, {
                val value = source
                detachProgressiveSource({
                    if (player.onMedia3RetireRequested === retireCallback) player.onMedia3RetireRequested = null
                    val position = if (value != null && epoch == generation && players[playerId] === player && player.source === value)
                        runCatching { player.getCurrentPosition() }.getOrNull() else null
                    if (value != null && epoch == generation && players[playerId] === player && player.source === value) {
                        player.source = null
                    }
                    position
                }, { try { (value as? AutoCloseable)?.close() } finally { source = null } })
            }, {
                // Engine detach disposes players; close the data source even if its looper is gone.
                (source as? AutoCloseable)?.close(); source = null
            }, ::finish)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        binaryMessenger = binding.binaryMessenger
        generation++
        players = ConcurrentHashMap()
        playbackThread = HandlerThread("mornye-audioplayers").apply { start() }
        playbackHandler = Handler(requireNotNull(playbackThread).looper)
        soundPoolManager = SoundPoolManager(this)
        methods = MethodChannel(binding.binaryMessenger, "xyz.luan/audioplayers")
        methods.setMethodCallHandler { call, response -> enqueue(call, response, ::methodHandler) }
        globalMethods = MethodChannel(binding.binaryMessenger, "xyz.luan/audioplayers.global")
        globalMethods.setMethodCallHandler { call, response -> enqueue(call, response, ::globalMethodHandler) }
        globalEvents = EventHandler(EventChannel(binding.binaryMessenger, "xyz.luan/audioplayers.global/events"))
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        generation++
        experimentalDecks.values.forEach { it.close() }
        experimentalDecks.clear()
        methods.setMethodCallHandler(null)
        globalMethods.setMethodCallHandler(null)
        val retiringPlayers = players
        val retiringPool = soundPoolManager
        val thread = playbackThread
        playbackHandler?.post {
            try {
                retiringPlayers.values.forEach { player ->
                    runCatching { player.dispose() }.onFailure {
                        Log.w("Audioplayers", "Could not release a retired player", it)
                    }
                }
                retiringPlayers.clear()
                runCatching { retiringPool.dispose() }.onFailure {
                    Log.w("Audioplayers", "Could not release a retired sound pool", it)
                }
            } finally {
                thread?.quitSafely()
            }
        }
        playbackHandler = null
        playbackThread = null
        globalEvents.dispose()
    }

    private fun enqueue(call: MethodCall, response: MethodChannel.Result, handler: FlutterHandler) {
        val epoch = generation
        val accepted = playbackHandler?.post {
            if (epoch == generation) safeCall(call, response, handler)
            else response.error("AndroidAudioError", "Audio engine was detached", null)
        } == true
        if (!accepted) response.error("AndroidAudioError", "Audio engine is not attached", null)
    }

    /** Capture the owner so late focus/load callbacks cannot enter a new engine. */
    fun playbackDispatcher(): (() -> Unit) -> Unit {
        val handler = playbackHandler ?: return { action -> action() }
        val epoch = generation
        return { action ->
            if (epoch == generation) {
                if (Looper.myLooper() == handler.looper) action()
                else handler.post { if (epoch == generation) action() }
            }
        }
    }

    private fun safeCall(
        call: MethodCall,
        response: MethodChannel.Result,
        handler: FlutterHandler,
    ) {
        try {
            handler(call, response)
        } catch (e: Throwable) {
            response.error("Unexpected AndroidAudioError", e.message, e.toString())
        }
    }

    private fun globalMethodHandler(call: MethodCall, response: MethodChannel.Result) {
        val currentPlayers = players
        when (call.method) {
            "init" -> {
                experimentalDecks.values.forEach { it.close() }
                experimentalDecks.clear()
                currentPlayers.values.forEach { it.dispose() }
                currentPlayers.clear()
            }

            "setAudioContext" -> {
                val audioContext = call.audioContext()
                val audioManager = getAudioManager()
                if (audioContext.audioMode != defaultAudioContext.audioMode) {
                    audioManager.mode = audioContext.audioMode
                }
                if (audioContext.isSpeakerphoneOn != defaultAudioContext.isSpeakerphoneOn) {
                    audioManager.isSpeakerphoneOn = audioContext.isSpeakerphoneOn
                }

                defaultAudioContext = audioContext
            }

            "emitLog" -> {
                val message = call.argument<String>("message") ?: error("message is required")
                handleGlobalLog(message)
            }

            "emitError" -> {
                val code = call.argument<String>("code") ?: error("code is required")
                val message = call.argument<String>("message") ?: error("message is required")
                handleGlobalError(code, message, null)
            }

            else -> {
                response.notImplemented()
                return
            }
        }

        response.success(1)
    }

    private fun methodHandler(call: MethodCall, response: MethodChannel.Result) {
        val currentPlayers = players
        val playerId = call.argument<String>("playerId") ?: return
        if (call.method == "create") {
            experimentalDecks.remove(playerId)?.close()
            val eventHandler = EventHandler(EventChannel(binaryMessenger, "xyz.luan/audioplayers/events/$playerId"))
            currentPlayers[playerId] = WrappedPlayer(this, eventHandler, defaultAudioContext.copy(), soundPoolManager)
            // Dart listens as soon as this reply lands. Replying earlier leaves
            // the stream without a listener, and the prepared event never arrives.
            eventHandler.afterRegistration { response.success(1) }
            return
        }
        val player = getPlayer(playerId, currentPlayers)
        try {
            when (call.method) {
                "setEqualizer" -> {
                    val configuration = call.argument<Map<String, Any?>>("configuration")
                        ?: error("Equalizer configuration is required")
                    player.setEqualizer(configuration)
                }
                "setSourceUrl" -> {
                    experimentalDecks.remove(playerId)?.close()
                    val url = call.argument<String>("url") ?: error("url is required")
                    val isLocal = call.argument<Boolean>("isLocal") ?: false
                    try {
                        player.source = UrlSource(url, isLocal)
                    } catch (e: FileNotFoundException) {
                        response.error(
                            "AndroidAudioError",
                            "Failed to set source. For troubleshooting, see: " +
                                "https://github.com/bluefireteam/audioplayers/blob/main/troubleshooting.md",
                            e.toString(),
                        )
                        return
                    }
                }

                "setSourceBytes" -> {
                    experimentalDecks.remove(playerId)?.close()
                    val bytes = call.argument<ByteArray>("bytes") ?: error("bytes are required")
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                        error("BytesSource is not supported on Android <= M")
                    }
                    player.source = BytesSource(bytes)
                }

                "setNextPlayer" -> {
                    val nextId = call.argument<String>("nextPlayerId")
                    player.setNext(nextId?.let { getPlayer(it, currentPlayers) })
                }

                "resume" -> player.play()
                "pause" -> player.pause()
                "stop" -> player.stop()
                "release" -> { experimentalDecks.remove(playerId)?.close(); player.release() }
                "seek" -> {
                    val position = call.argument<Int>("position") ?: error("position is required")
                    player.seek(position)
                }

                "setVolume" -> {
                    val volume = call.argument<Double>("volume") ?: error("volume is required")
                    player.volume = volume.toFloat()
                }

                "setBalance" -> {
                    val balance = call.argument<Double>("balance") ?: error("balance is required")
                    player.balance = balance.toFloat()
                }

                "setPlaybackRate" -> {
                    val rate = call.argument<Double>("playbackRate") ?: error("playbackRate is required")
                    player.rate = rate.toFloat()
                }

                "getDuration" -> {
                    response.success(player.getDuration())
                    return
                }

                "getCurrentPosition" -> {
                    response.success(player.getCurrentPosition())
                    return
                }

                "setReleaseMode" -> {
                    val releaseMode = call.enumArgument<ReleaseMode>("releaseMode") ?: error("releaseMode is required")
                    player.releaseMode = releaseMode
                }

                "setPlayerMode" -> {
                    val playerMode = call.enumArgument<PlayerMode>("playerMode") ?: error("playerMode is required")
                    player.playerMode = playerMode
                }

                "setAudioContext" -> {
                    val audioContext = call.audioContext()
                    player.updateAudioContext(audioContext)
                }

                "emitLog" -> {
                    val message = call.argument<String>("message") ?: error("message is required")
                    player.handleLog(message)
                }

                "emitError" -> {
                    val code = call.argument<String>("code") ?: error("code is required")
                    val message = call.argument<String>("message") ?: error("message is required")
                    player.handleError(code, message, null)
                }

                "dispose" -> {
                    experimentalDecks.remove(playerId)?.close()
                    player.dispose()
                    currentPlayers.remove(playerId)
                }

                else -> {
                    response.notImplemented()
                    return
                }
            }
            response.success(1)
        } catch (e: Exception) {
            response.error("AndroidAudioError", e.message, e.toString())
        }
    }

    private fun getPlayer(playerId: String, currentPlayers: Map<String, WrappedPlayer>): WrappedPlayer {
        return currentPlayers[playerId] ?: error("Player has not yet been created or has already been disposed.")
    }

    fun getApplicationContext(): Context {
        return context.applicationContext
    }

    fun getAudioManager(): AudioManager {
        return context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    fun handleDuration(player: WrappedPlayer) {
        player.eventHandler.success(
            "audio.onDuration",
            hashMapOf("value" to (player.getDuration() ?: 0)),
        )
    }

    fun handleComplete(player: WrappedPlayer) {
        player.eventHandler.success("audio.onComplete")
    }

    fun handlePrepared(player: WrappedPlayer, isPrepared: Boolean) {
        player.eventHandler.success("audio.onPrepared", hashMapOf("value" to isPrepared))
    }

    fun handleLog(player: WrappedPlayer, message: String) {
        player.eventHandler.success("audio.onLog", hashMapOf("value" to message))
    }

    fun handleGlobalLog(message: String) {
        globalEvents.success("audio.onLog", hashMapOf("value" to message))
    }

    fun handleError(player: WrappedPlayer, errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        experimentalDecks.entries.filter { it.value.owns(player) }.forEach {
            if (experimentalDecks.remove(it.key, it.value)) it.value.close()
        }
        player.eventHandler.error(errorCode, errorMessage, errorDetails)
    }

    fun handleGlobalError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        globalEvents.error(errorCode, errorMessage, errorDetails)
    }

    fun handleSeekComplete(player: WrappedPlayer) {
        player.eventHandler.success("audio.onSeekComplete")
    }
}

private inline fun <reified T : Enum<T>> MethodCall.enumArgument(name: String): T? {
    val enumName = argument<String>(name) ?: return null
    return enumValueOf<T>(enumName.split('.').last().toConstantCase())
}

fun String.toConstantCase(): String {
    return replace(Regex("(.)(\\p{Upper})"), "$1_$2").replace(Regex("(.) (.)"), "$1_$2").uppercase()
}

private fun MethodCall.audioContext(): AudioContextAndroid {
    return AudioContextAndroid(
        isSpeakerphoneOn = argument<Boolean>("isSpeakerphoneOn") ?: error("isSpeakerphoneOn is required"),
        stayAwake = argument<Boolean>("stayAwake") ?: error("stayAwake is required"),
        contentType = argument<Int>("contentType") ?: error("contentType is required"),
        usageType = argument<Int>("usageType") ?: error("usageType is required"),
        audioFocus = argument<Int>("audioFocus") ?: error("audioFocus is required"),
        audioMode = argument<Int>("audioMode") ?: error("audioMode is required"),
    )
}

class EventHandler(private val eventChannel: EventChannel) : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == main.looper) action() else main.post { action() }
    }

    init {
        onMain { eventChannel.setStreamHandler(this) }
    }

    /** Runs [action] on the main thread, after the registration queued above. */
    fun afterRegistration(action: () -> Unit) = onMain(action)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun success(method: String, arguments: Map<String, Any> = HashMap()) {
        onMain { eventSink?.success(arguments + Pair("event", method)) }
    }

    fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        onMain { eventSink?.error(errorCode, errorMessage, errorDetails) }
    }

    fun dispose() {
        onMain {
            eventSink?.let {
                it.endOfStream()
                onCancel(null)
            }
            eventChannel.setStreamHandler(null)
        }
    }
}
