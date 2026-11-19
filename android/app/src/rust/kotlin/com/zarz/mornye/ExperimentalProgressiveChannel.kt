package com.zarz.mornye

import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import xyz.luan.audioplayers.AudioplayersPlugin

/**
 * Owns resources published by a startup that can race cancellation.
 * No factory, closer or notification runs under its monitor. If startup has not
 * returned, cancellation is explicitly unconfirmed (false), never an endless
 * wait or a premature success. Late publication still disposes its resources.
 */
internal class ProgressiveStartupHandoff<T : Any>(
    private val dispose: (T, (Boolean) -> Unit) -> Unit,
) {
    private val lock = Any()
    private var startupFinished = false
    private var closing = false
    private var resource: T? = null
    private var outcome: Boolean? = null
    private val waiters = mutableListOf<(Boolean) -> Unit>()

    fun complete(value: T) {
        val disposeNow = synchronized(lock) {
            check(!startupFinished) { "Startup already completed" }
            startupFinished = true
            if (closing) true else { resource = value; false }
        }
        if (disposeNow) disposeOutsideLock(value)
    }

    fun close(notify: (Boolean) -> Unit = {}) {
        var value: T? = null
        var known: Boolean? = null
        var unconfirmed = emptyList<(Boolean) -> Unit>()
        synchronized(lock) {
            if (outcome != null) known = outcome
            else {
                waiters.add(notify)
                if (!closing) {
                    closing = true
                    if (startupFinished) { value = resource; resource = null }
                    else {
                        outcome = false
                        unconfirmed = waiters.toList()
                        waiters.clear()
                    }
                }
            }
        }
        known?.let { ok -> runCatching { notify(ok) } }
        unconfirmed.forEach { runCatching { it(false) } }
        value?.let(::disposeOutsideLock)
    }

    val isClosing: Boolean get() = synchronized(lock) { closing }

    private fun disposeOutsideLock(value: T) {
        try { dispose(value, ::settle) }
        catch (_: Exception) { settle(false) }
    }

    private fun settle(ok: Boolean) {
        val callbacks = synchronized(lock) {
            if (outcome != null) return
            outcome = ok
            waiters.toList().also { waiters.clear() }
        }
        callbacks.forEach { runCatching { it(ok) } }
    }
}

/** Test producer injection. It supplies data only: channels, controller and deck stay real. */
internal class ProgressiveChannelInstrumentation(
    val sessionFactory: (String, (String) -> Unit) -> ProgressiveControllerSession,
) {
    fun requireDebuggable(debuggable: Boolean): ProgressiveChannelInstrumentation {
        check(debuggable) { "Progressive instrumentation requires a debuggable application" }
        return this
    }
}

/**
 * Debug-only experimental channel; default debug starts use the real Rust backend.
 * Only explicit native constructor injection supplies a synthetic test producer.
 * It does not log request or result payloads.
 */
internal class ExperimentalProgressiveChannel(
    private val activity: MainActivity,
    engine: FlutterEngine,
    instrumentation: ProgressiveChannelInstrumentation? = null,
) : AutoCloseable {
    // Validate before allocating executors or registering a channel owner.
    private val instrumentation = instrumentation?.requireDebuggable(
        activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
    private val messenger = engine.dartExecutor.binaryMessenger
    private val channel = MethodChannel(messenger, "com.zarz.mornye/experimental_progressive")
    private val player = engine.plugins.get(AudioplayersPlugin::class.java) as? AudioplayersPlugin
    private val io = Executors.newFixedThreadPool(3)
    // Cancellation must not queue behind blocked download/observer workers.
    private val cleanup = Executors.newFixedThreadPool(2)
    private val completion = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val attempts = ConcurrentHashMap<String, Attempt>()
    private val lifecycle = Any()
    @Volatile private var closed = false
    private companion object { val owners = ConcurrentHashMap<BinaryMessenger, ExperimentalProgressiveChannel>() }
    private class Resources(
        val deck: AudioplayersPlugin.ExperimentalProgressiveDeck?,
        val controller: ProgressiveDeckController?,
    )
    private class Attempt(val gate: ProgressiveAttemptGate, val playerId: String) {
        val startup = ProgressiveStartupHandoff<Resources> { value, done ->
            fun closeDeck(ok: Boolean) {
                try {
                    val deck = value.deck
                    if (deck == null) done(ok) else deck.close { done(ok) }
                } catch (_: Exception) { done(false) }
            }
            val controller = value.controller
            if (controller == null) closeDeck(true)
            else {
                try { controller.closeAndNotify(::closeDeck) }
                catch (_: Exception) { closeDeck(false) }
            }
        }
        fun close(done: (Boolean) -> Unit = {}) {
            gate.cancel()
            startup.close(done)
        }
    }

    init {
        owners.put(messenger, this)?.close()
        channel.setMethodCallHandler { call, reply ->
            when (call.method) {
                "start" -> start(call, reply)
                "cancel" -> {
                    val attempt = call.argument<String>("attemptId")?.let { id ->
                        synchronized(lifecycle) { attempts.remove(id) }
                    }
                    if (attempt == null) reply.success(true)
                    else {
                        attempt.close { ok -> main.post { reply.success(ok) } }
                    }
                }
                else -> reply.notImplemented()
            }
        }
    }

    private fun start(call: io.flutter.plugin.common.MethodCall, reply: MethodChannel.Result) {
        if (closed || activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 || call.argument<Boolean>("enabled") != true) {
            reply.success(false); return
        }
        val id = call.argument<String>("attemptId") ?: ""
        val playerId = call.argument<String>("playerId") ?: ""
        val request = call.argument<String>("requestJson") ?: ""
        val requestObject = runCatching { JSONObject(request) }.getOrNull()
        if (id.isBlank() || playerId.isBlank() || requestObject?.opt("temporary_playback") != true || requestObject.optString("storage_mode") != "app" || attempts.containsKey(id)) {
            reply.success(false); return
        }
        val plugin = player ?: run { reply.success(false); return }
        // Read and validate Dart arguments before acquiring native configuration.
        val useMedia3 = call.argument<Boolean>("media3") == true
        lateinit var attempt: Attempt
        val finalPosition = AtomicReference<Long?>(null)
        fun emit(kind: String, value: String? = null) {
            main.post {
                if (!closed && attempts[id] === attempt) {
                    val args = mutableMapOf<String, Any>("attemptId" to id, "kind" to kind)
                    if (value != null) args["resultJson"] = value
                    if (kind == "fallback" || kind == "invalidated" || kind == "failed" || kind == "retired") finalPosition.get()?.let { args["positionMs"] = it }
                    channel.invokeMethod("event", args)
                }
            }
        }
        val gate = ProgressiveAttemptGate({ emit("attached") }, { emit("result", it) }, { emit("fallback") }, { emit("failed") }, { emit("invalidated") })
        attempt = Attempt(gate, playerId)
        val admitted = synchronized(lifecycle) {
            if (closed || attempts.containsKey(id) || attempts.values.any { it.playerId == playerId }) false
            else { attempts[id] = attempt; true }
        }
        if (!admitted) { reply.success(false); return }
        var deck: AudioplayersPlugin.ExperimentalProgressiveDeck? = null
        var controller: ProgressiveDeckController? = null
        var published = false
        try {
            // Reservation precedes all acquisition; close sees the in-flight startup.
            deck = plugin.experimentalProgressiveDeck(
                playerId, useMedia3, replaceExisting = false, experimentalRequest = true)
            if (deck == null || closed || attempt.startup.isClosing) {
                attempts.remove(id, attempt)
                attempt.close()
                reply.success(false)
                return
            }
            controller = ExperimentalProgressiveBridge(
                io, true, cleanup, completion, instrumentation?.sessionFactory,
            ).start(
                if (instrumentation == null) RustCoreBackend.owner() else null, request, deck,
                fallback = { position -> finalPosition.set(position); gate.unavailable() },
                onSourceAttached = gate::sourceAttached,
                onDownloadResult = gate::result,
                onCancellationFailure = gate::failed,
                onTerminalFailure = { position -> finalPosition.set(position); gate.failed() },
                onSourceCommitted = gate::sourceCommitted,
                onSourceRetired = { position -> finalPosition.set(position); emit("retired") },
                onSourceRetiring = { emit("retiring") },
            )
            if (controller == null) {
                attempts.remove(id, attempt)
                attempt.close()
            }
            // Publish before replying: a reentrant cancel can then close the actual
            // controller instead of seeing a partially initialized attempt.
            published = true
            attempt.startup.complete(Resources(deck, controller))
            val stillCurrent = synchronized(lifecycle) { !closed && attempts[id] === attempt }
            reply.success(stillCurrent && controller != null)
        } catch (_: Exception) {
            attempts.remove(id, attempt); attempt.close(); reply.success(false)
        } finally {
            // If close won before publication, the handoff immediately disposes both
            // late resources outside every channel monitor.
            if (!published) attempt.startup.complete(Resources(deck, controller))
        }
    }


    override fun close() {
        val retiring = synchronized(lifecycle) {
            if (closed) return
            closed = true
            attempts.values.toList().also { attempts.clear() }
        }
        val isCurrentOwner = owners.remove(messenger, this)
        if (isCurrentOwner) channel.setMethodCallHandler(null)
        retiring.forEach { it.close() }
        // Pending startups are revoked; their late publications self-dispose.
        // A never-returning startup cannot block shutdown or yield a false success.
        io.shutdown()
        cleanup.shutdown()
        completion.shutdown()
    }
}
