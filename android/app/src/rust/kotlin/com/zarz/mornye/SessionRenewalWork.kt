package com.zarz.mornye

import android.content.Context
import androidx.work.Constraints
import androidx.work.Worker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import com.mornye.backend.RequestLease
import com.mornye.backend.renewExistingSessionStandalone
import java.io.File
import org.json.JSONObject

private const val PREF_FILE = "FlutterSharedPreferences"
private const val PREF_ENABLED = "flutter.foreground_session_renewal_enabled"
private const val KEY_ID = "extension_id"
private const val KEY_EXPIRY = "expiry_ms"
private const val KEY_ATTEMPTS = "attempts"
private const val KEY_GENERATION = "generation"
private const val KEY_PROVIDER_GENERATION = "provider_generation"
private const val WORK_TAG = "existing-session-renewal"

private fun Context.sessionRenewalEnabled(): Boolean = try {
    getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE).getBoolean(PREF_ENABLED, false)
} catch (_: Exception) { false }

/** This scheduler is not attached to UI until the Android build and worker are validated. */
internal object SessionRenewalScheduler {
    private val monitor = Any()
    private var gate: SessionGenerationGate? = null
    private val providerGates = mutableMapOf<String, SessionGenerationGate>()
    private fun createGeneration(context: Context, key: String): SessionGenerationGate {
        val prefs = context.applicationContext.getSharedPreferences("musa_session_work_generation", Context.MODE_PRIVATE)
        // Never reset a missing generation to a predictable value: the work
        // database can outlive this preference, including after restore.
        val initialWriteFailed = if (!prefs.contains(key)) {
            val generated = java.security.SecureRandom().nextLong() and Long.MAX_VALUE
            !prefs.edit().putLong(key, if (generated == Long.MAX_VALUE) 0L else generated).commit()
        } else false
        return SessionGenerationGate(
            { if (initialWriteFailed) null else try { prefs.getLong(key, -1L) } catch (_: Exception) { null } },
            { prefs.edit().putLong(key, it).commit() },
        )
    }
    private fun generation(context: Context) = gate ?: createGeneration(context, KEY_GENERATION).also { gate = it }
    private fun providerGeneration(context: Context, id: String) =
        providerGates.getOrPut(id) { createGeneration(context, "provider:$id") }
    private fun generationTag(value: Long) = "$WORK_TAG:g$value"
    private fun providerTag(id: String, value: Long, provider: Long) = "${generationTag(value)}:$id:p$provider"

    fun cancel(context: Context) = synchronized(monitor) {
        val previous = generation(context).invalidate()
        if (previous == null) {
            val cancel = WorkManager.getInstance(context).cancelAllWorkByTag(WORK_TAG)
            awaitSessionWorkOperation(cancel.result, 10_000)
            error("Could not persist session work invalidation")
        }
        val cancel = WorkManager.getInstance(context).cancelAllWorkByTag(generationTag(previous))
        check(awaitSessionWorkOperation(cancel.result, 10_000)) { "Could not confirm session work cancellation" }
    }

    fun isCurrent(context: Context, id: String, expected: Long, expectedProvider: Long): Boolean = synchronized(monitor) {
        validSessionWorkId(id) && generation(context).current() == expected &&
            providerGeneration(context, id).current() == expectedProvider && expected >= 0 && expectedProvider >= 0
    }

    fun schedule(context: Context, id: String, status: String, expiresAt: Long?): Boolean = synchronized(monitor) {
        val plan = initialSessionWork(status, expiresAt, System.currentTimeMillis()) ?: return@synchronized false
        if (!validSessionWorkId(id)) return@synchronized false
        val current = generation(context).current() ?: return@synchronized false
        val provider = providerGeneration(context, id).current() ?: return@synchronized false
        enqueue(context, id, plan, current, provider, false)
    }

    fun scheduleNext(context: Context, id: String, plan: SessionWorkPlan, expected: Long, expectedProvider: Long): Boolean = synchronized(monitor) {
        if (!isCurrent(context, id, expected, expectedProvider)) return@synchronized false
        enqueue(context, id, plan, expected, expectedProvider, true)
    }

    private fun enqueue(context: Context, id: String, plan: SessionWorkPlan, expected: Long, expectedProvider: Long, fromWorker: Boolean): Boolean {
        if (!validSessionWorkId(id) || !context.sessionRenewalEnabled()) return false
        val request = OneTimeWorkRequestBuilder<SessionRenewalWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInitialDelay(plan.delay, TimeUnit.MILLISECONDS)
            .setInputData(workDataOf(KEY_ID to id, KEY_EXPIRY to plan.expiry, KEY_ATTEMPTS to plan.attempts, KEY_GENERATION to expected, KEY_PROVIDER_GENERATION to expectedProvider))
            .addTag(WORK_TAG)
            .addTag(generationTag(expected))
            .addTag(providerTag(id, expected, expectedProvider))
            .build()
        val confirmed = try {
            val enqueue = WorkManager.getInstance(context).enqueueUniqueWork(
                providerTag(id, expected, expectedProvider), if (fromWorker) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.REPLACE, request,
            )
            awaitSessionWorkOperation(enqueue.result, 10_000)
        } catch (_: Exception) { false }
        if (confirmed) return true
        // The operation may still finish after a timeout. Invalidate before
        // returning failure so a late worker cannot become current.
        providerGeneration(context, id).invalidate()
        try {
            val cancel = WorkManager.getInstance(context).cancelAllWorkByTag(
                providerTag(id, expected, expectedProvider),
            )
            awaitSessionWorkOperation(cancel.result, 10_000)
        } catch (_: Exception) { /* Provider generation invalidated or failed closed. */ }
        return false
    }
}

/** The input contains only provider ID, expiry, retry count and generation. */
class SessionRenewalWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    private val stopGate = SessionStopGate()

    override fun onStopped() {
        stopGate.stop()
        super.onStopped()
    }

    override fun doWork(): Result {
        // Also makes previously persisted work inert after a rollback/build
        // with the experiment disabled.
        if (!BackgroundKeyProvider.ENABLED) return Result.success()
        val id = inputData.getString(KEY_ID) ?: return Result.success()
        val previousExpiry = inputData.getLong(KEY_EXPIRY, 0L)
        val attempts = inputData.getInt(KEY_ATTEMPTS, 0)
        val generation = inputData.getLong(KEY_GENERATION, -1L)
        val providerGeneration = inputData.getLong(KEY_PROVIDER_GENERATION, -1L)
        fun current() = !isStopped && applicationContext.sessionRenewalEnabled() &&
            SessionRenewalScheduler.isCurrent(applicationContext, id, generation, providerGeneration)
        if (!validSessionWorkId(id) || !current()) return Result.success()
        val requestId = UUID.randomUUID().toString()
        val lease = try { NativeDataJobs.acquire(requestId) } catch (_: Exception) { return Result.success() }
        val response = try {
            if (!stopGate.register { NativeDataJobs.cancel(requestId) }) return Result.success()
            if (isStopped) { stopGate.stop(); return Result.success() }
            try { renewExistingSessionForWork(applicationContext, id, lease, ::current) }
            catch (_: Exception) { "{\"status\":\"unavailable\"}" }
        } finally {
            stopGate.clear()
            NativeDataJobs.release(requestId, lease)
        }
        if (!current()) return Result.success()
        try {
            val result = JSONObject(response)
            val expiry = result.optString("expires_at", "").takeIf { it.isNotEmpty() }?.let { Instant.parse(it).toEpochMilli() }
            val plan = nextSessionWork(result.optString("status"), expiry, previousExpiry, attempts, System.currentTimeMillis())
            if (plan != null && current()) {
                val scheduled = SessionRenewalScheduler.scheduleNext(applicationContext, id, plan, generation, providerGeneration)
                if (reportSessionRescheduleFailure(scheduled, isStopped || !applicationContext.sessionRenewalEnabled())) return Result.failure()
            }
        } catch (_: Exception) { return Result.failure() }
        return Result.success()
    }
}

private fun renewExistingSessionForWork(context: Context, id: String, lease: RequestLease, active: () -> Boolean): String = RustCoreBackend.ownerLifecycle.exclusive {
    if (!active() || !context.sessionRenewalEnabled()) return@exclusive "{}"
    RustCoreBackend.ensureOwnerLifecycleHealthy()
    val current = synchronized(RustCoreBackend) { RustCoreBackend.manager }
    if (current != null) {
        if (!active() || !context.sessionRenewalEnabled()) return@exclusive "{}"
        current.renewExistingSessionWithLease(id, true, lease)
    } else {
        val key = BackgroundKeyProvider.current().read({ active() && context.sessionRenewalEnabled() }, 10_000)
            ?: return@exclusive "{\"status\":\"unavailable\"}"
        if (!active() || !context.sessionRenewalEnabled()) return@exclusive "{}"
        val root = context.filesDir
        val sources = File(root, "extensions")
        val data = File(root, "extension_data")
        if (!sources.isDirectory || !data.isDirectory) return@exclusive "{\"status\":\"unavailable\"}"
        renewExistingSessionStandalone(sources.canonicalPath, data.canonicalPath, key, BuildConfig.VERSION_NAME, id, lease)
    }
}
