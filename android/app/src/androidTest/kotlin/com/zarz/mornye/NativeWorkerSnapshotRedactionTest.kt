package com.zarz.mornye

import android.content.ContextWrapper
import android.content.Intent
import android.os.Process
import android.os.SystemClock
import android.util.AtomicFile
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeWorkerSnapshotRedactionTest {
    @Test
    fun serviceWriterUsesRealRustCatalogAndRestoresFallbackWithoutIt() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // This fixture owns the extension catalog and worker snapshots of the
        // disposable integration package for the duration of this test.
        check(context.packageName == "org.musa.music.catalogintegration")
        assertEquals(context.applicationInfo.uid, Process.myUid())
        val directory = File.createTempFile("rust-worker-snapshot-", "", context.cacheDir)
        check(directory.delete() && directory.mkdir())
        val sources = File(directory, "sources").apply { check(mkdir()) }
        val data = File(directory, "data").apply { check(mkdir()) }
        val output = File(directory, "output").apply { check(mkdir()) }
        val primary = "fixture.snapshot-primary"
        val alternate = "fixture.snapshot-fallback"
        val itemId = "fixture-download"
        for (id in listOf(primary, alternate)) {
            val source = File(sources, id).apply { check(mkdir()) }
            File(source, "manifest.json").writeText(
                """{"name":"$id","version":"1","description":"Snapshot test fixture","type":["download_provider"],"permissions":{"storage":true}}""",
            )
            val availabilityFailure = if (id == primary) "provider unavailable"
            else "verification_required: verification required"
            File(source, "index.js").writeText(
                "registerExtension({checkAvailability(){log.info('snapshot-fixture-attempt:$id');" +
                    "throw new Error('$availabilityFailure');}," +
                    "download(){throw new Error('Unexpected download after failed availability');}});",
            )
        }

        val backend = createCoreBackend(context)
        var catalogInitialized = false
        var started = false
        val intent = Intent(context, DownloadService::class.java)
        try {
            assertFalse(DownloadService.isServiceRunning())
            backend.invokeApplication(
                "initExtensionSystem",
                mapOf(
                    "extensions_dir" to sources.path,
                    "data_dir" to data.path,
                    "master_key" to Base64.encodeToString(ByteArray(32), Base64.NO_WRAP),
                    "allowed_directories" to listOf(output.path),
                ),
            )
            catalogInitialized = true
            backend.invokeApplication("loadExtensionsFromDir", mapOf("dir_path" to sources.path))
            for (id in listOf(primary, alternate)) {
                backend.invokeApplication("setExtensionEnabled", mapOf("extension_id" to id, "enabled" to true))
            }
            assertEquals(setOf(primary, alternate), DownloadService.installedNativeWorkerServices(context))
            val providerOrder = JSONArray().put(primary).put(alternate).toString()
            backend.invokeApplication("setProviderPriority", mapOf("priority" to providerOrder))
            backend.invokeApplication("setDownloadFallbackExtensionIds", mapOf("extension_ids" to providerOrder))
            backend.invokeApplication("setLoggingEnabled", mapOf("enabled" to true))
            backend.invokeApplication("clearLogs", null)

            val request = JSONObject().put("service", primary).put("provider_track_id", "track")
                .put("use_extensions", true).put("use_fallback", true).put("allow_quality_fallback", true)
                .put("output_dir", output.path).put("track_name", "Fixture track").put("quality", "best")
                .put("artist_name", "Fixture artist").put("embed_metadata", false).put("embed_lyrics", false)
            val result = JSONObject(backend.downloadByStrategy(request.toString()))
            assertEquals("verification_required", result.getString("error_type"))
            assertEquals(alternate, result.getString("service"))
            val logs = JSONObject(backend.invokeApplication("getLogsSince", mapOf("index" to 0)) as String)
                .getJSONArray("logs")
            val attempts = (0 until logs.length()).mapNotNull { index ->
                val entry = logs.getJSONObject(index)
                val message = entry.getString("message")
                if (!message.startsWith("snapshot-fixture-attempt:")) return@mapNotNull null
                val id = message.removePrefix("snapshot-fixture-attempt:")
                assertEquals("Extension:$id:INFO", entry.getString("tag"))
                id
            }
            // The backend can query the alternate again for its fallback
            // policy. The ordered native buffer must show primary first and
            // every subsequent fixture handler entry from the alternate.
            assertEquals(primary, attempts.firstOrNull())
            assertTrue(attempts.size >= 2)
            assertTrue(attempts.drop(1).all { it == alternate })
            backend.invokeApplication("setLoggingEnabled", mapOf("enabled" to false))
            result.put("error", "Verification required $CANARY").put("provider", CANARY).put("source", CANARY)

            instrumentation.uiAutomation.adoptShellPermissionIdentity(
                "android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND",
            )
            try {
                DownloadService.start(context, "Snapshot integration fixture")
                started = true
                awaitCondition("Download service did not enter foreground") { DownloadService.isServiceRunning() }
                val service = checkNotNull(DownloadService.snapshotOwner)
                synchronized(service.snapshotWriteLock) {
                    service.nativeWorkerRunId = "fixture-snapshot-run"
                    service.nativeWorkerItems.add(
                        DownloadService.NativeWorkerItem(
                            itemId = itemId, trackName = "Fixture", artistName = "Fixture",
                            status = "failed", error = result.getString("error"), resultJson = result,
                        ),
                    )
                    service.writeNativeWorkerSnapshot(true, true, itemId, "Verification required", result, includeItems = true)
                    service.writeNativeWorkerSnapshot(true, true, itemId, "Verification required")
                }
                val stateFile = File(context.filesDir, DownloadService.NATIVE_WORKER_STATE_FILE)
                val progressFile = File(context.filesDir, DownloadService.NATIVE_WORKER_PROGRESS_FILE)
                val compact = readCleanFixtureSnapshot(stateFile)
                val delta = readCleanFixtureSnapshot(progressFile)
                assertEquals(alternate, compact.getJSONObject("last_result").getString("service"))
                assertEquals(alternate, delta.getJSONObject("item_delta").getJSONObject("result").getString("service"))

                val stateSerial = compact.getLong("state_serial")
                assertEquals(stateSerial, DownloadService.lastStateHeaderSerial)
                // Point the reader at a disposable directory with a broken
                // compact file. The real header cached by the writer must be
                // sufficient for the serial query; disk parsing must fail.
                val cacheProbeDir = File(directory, "cached-header").apply { check(mkdir()) }
                File(cacheProbeDir, stateFile.name).writeText("{")
                progressFile.copyTo(File(cacheProbeDir, progressFile.name))
                val cacheProbe = object : ContextWrapper(context) {
                    override fun getFilesDir(): File = cacheProbeDir
                }
                val diskError = runCatching { DownloadService.getNativeWorkerSnapshot(cacheProbe) }.exceptionOrNull()
                assertEquals("Unreadable native worker state", diskError?.message)
                val cached = JSONObject(DownloadService.getNativeWorkerSnapshot(cacheProbe, stateSerial))
                assertFalse(cached.has("items"))
                assertEquals(stateSerial, cached.getLong("state_serial"))
                assertEquals(alternate, cached.getJSONObject("item_delta").getJSONObject("result").getString("service"))

                context.stopService(intent)
                awaitCondition("Download service did not stop") { !DownloadService.isServiceRunning() }
                started = false
                backend.invokeApplication("cleanupExtensions", null)
                catalogInitialized = false
                assertTrue(DownloadService.installedNativeWorkerServices(context).isEmpty())
                val restored = JSONObject(DownloadService.getNativeWorkerSnapshot(context))
                val restoredProvider = restored.getJSONArray("items").getJSONObject(0)
                    .getJSONObject("result").optString("service").ifBlank { primary }
                assertEquals(alternate, restoredProvider)
            } finally {
                if (started) {
                    context.stopService(intent)
                    awaitCondition("Download service did not stop") { !DownloadService.isServiceRunning() }
                }
                instrumentation.uiAutomation.dropShellPermissionIdentity()
            }
        } finally {
            if (catalogInitialized) {
                backend.invokeApplication("setLoggingEnabled", mapOf("enabled" to false))
                backend.invokeApplication("cleanupExtensions", null)
            }
            directory.deleteRecursively()
        }
    }

    private fun awaitCondition(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(25)
        assertTrue(message, predicate())
    }

    private fun readCleanFixtureSnapshot(file: File): JSONObject {
        val raw = AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use { it.readText() }
        assertFalse("Raw fixture reached the atomic file", raw.contains(CANARY))
        return JSONObject(raw)
    }

    @Test
    fun compactAndDeltaWritesKeepOnlySafeFailureDiagnostics() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File.createTempFile("worker-snapshot-", "", context.cacheDir)
        check(directory.delete() && directory.mkdir())
        try {
            verifyWorkerSnapshotFiles(directory)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun legacyCompactAndDeltaAreProjectedBeforeReadback() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File.createTempFile("legacy-worker-snapshot-", "", context.cacheDir)
        check(directory.delete() && directory.mkdir())
        try {
            val isolatedContext = object : ContextWrapper(context) {
                override fun getFilesDir(): File = directory
            }
            val failure = JSONObject().put("status", "failed").put("item_id", "item")
                .put("error", "Needs verification $CANARY")
            val state = JSONObject().put("run_id", "fixture").put("snapshot_serial", 1)
                .put("items", JSONArray().put(failure))
            val progress = JSONObject().put("run_id", "fixture").put("snapshot_serial", 2)
                .put("message", "Native download failed during downloading: $CANARY")
                .put("item_delta", failure)
                .put("item_deltas", JSONArray().put(CANARY))
            File(directory, DownloadService.NATIVE_WORKER_STATE_FILE).writeText(state.toString())
            File(directory, DownloadService.NATIVE_WORKER_PROGRESS_FILE).writeText(progress.toString())

            val readback = DownloadService.getNativeWorkerSnapshot(isolatedContext)
            assertFalse("Raw legacy diagnostics reached the consumer", readback.contains(CANARY))
            val merged = JSONObject(readback)
            assertEquals("compact_with_delta", merged.getString("snapshot_mode"))
            assertEquals("Verification required", merged.getJSONObject("item_delta").getString("error"))
            assertEquals("Verification required", merged.getJSONArray("items").getJSONObject(0).getString("error"))
            assertEquals(0, merged.getJSONArray("item_deltas").length())

            val deltaOnly = synchronized(DownloadService.NATIVE_WORKER_STATE_FILE_LOCK) {
                val cachedHeader = DownloadService.lastStateHeaderJson
                val cachedSerial = DownloadService.lastStateHeaderSerial
                try {
                    DownloadService.lastStateHeaderJson = null
                    DownloadService.lastStateHeaderSerial = 0L
                    DownloadService.getNativeWorkerSnapshot(isolatedContext, sinceStateSerial = 1)
                } finally {
                    DownloadService.lastStateHeaderJson = cachedHeader
                    DownloadService.lastStateHeaderSerial = cachedSerial
                }
            }
            assertFalse(deltaOnly.contains(CANARY))
            val unchangedState = JSONObject(deltaOnly)
            assertFalse(unchangedState.has("items"))
            assertEquals(1L, unchangedState.getLong("state_serial"))
            assertEquals(2L, unchangedState.getLong("snapshot_serial"))
            assertEquals("Verification required", unchangedState.getJSONObject("item_delta").getString("error"))

            val cached = synchronized(DownloadService.NATIVE_WORKER_STATE_FILE_LOCK) {
                val cachedHeader = DownloadService.lastStateHeaderJson
                val cachedSerial = DownloadService.lastStateHeaderSerial
                try {
                    DownloadService.lastStateHeaderJson = JSONObject().put("run_id", "fixture")
                        .put("snapshot_serial", 1).put("state_serial", 1).toString()
                    DownloadService.lastStateHeaderSerial = 1L
                    DownloadService.getNativeWorkerSnapshot(isolatedContext, sinceStateSerial = 1)
                } finally {
                    DownloadService.lastStateHeaderJson = cachedHeader
                    DownloadService.lastStateHeaderSerial = cachedSerial
                }
            }
            assertFalse(cached.contains(CANARY))
            assertEquals(2L, JSONObject(cached).getLong("snapshot_serial"))
            assertFalse(JSONObject(cached).has("items"))

            val truncated = """{"message":"$CANARY","items":["""
            val stateFile = File(directory, DownloadService.NATIVE_WORKER_STATE_FILE)
            stateFile.writeText(truncated)
            val error = runCatching { DownloadService.getNativeWorkerSnapshot(isolatedContext) }.exceptionOrNull()
            assertEquals("Unreadable native worker state", error?.message)
            assertEquals(null, error?.cause)
            assertEquals(truncated, stateFile.readText())

            val fallback = JSONObject().put("success", false).put("error_type", "verification_required")
                .put("service", "fixture.fallback")
            failure.put("result", fallback)
            StoppedNativeWorkerStore.writeDurably(stateFile, state) { setOf("fixture.fallback") }
            val legacyDelta = JSONObject().put("status", "failed").put("item_id", "item")
                .put("result", JSONObject().put("success", false).put("error_type", "verification_required")
                    .put("service", CANARY))
            File(directory, DownloadService.NATIVE_WORKER_PROGRESS_FILE)
                .writeText(progress.put("item_delta", legacyDelta).toString())
            val cold = DownloadService.getNativeWorkerSnapshot(isolatedContext)
            assertFalse(cold.contains(CANARY))
            val mixed = JSONObject(cold)
            assertEquals("fixture.fallback", mixed.getJSONArray("items").getJSONObject(0)
                .getJSONObject("result").getString("service"))
            assertFalse(mixed.getJSONObject("item_delta").getJSONObject("result").has("service"))
        } finally {
            directory.deleteRecursively()
        }
    }
}

private const val CANARY = "synthetic-canary-8ca2"

internal fun verifyWorkerSnapshotFiles(directory: File) {
    fun failedItem(result: JSONObject) = JSONObject()
        .put("status", "failed")
        .put("item_id", "failed-item")
        .put("error", result.getString("error"))
        .put("result", result)

    fun writeAndRead(name: String, snapshot: JSONObject): JSONObject {
        val file = File(directory, name)
        StoppedNativeWorkerStore.writeDurably(file, snapshot) { setOf("fixture.test-extension") }
        val raw = AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use { it.readText() }
        assertFalse("Raw failure diagnostics reached the atomic file", raw.contains(CANARY))
        return JSONObject(raw)
    }

    val storage = JSONObject()
        .put("success", false)
        .put("error", "Failed to publish deferred SAF content://fixture/$CANARY")
        .put("failure_stage", "android_finalizing")
        .put("debug", JSONObject().put("authorization", CANARY))
    val completedResult = JSONObject()
        .put("success", true)
        .put("file_path", "content://fixture/completed")
        .put("history", JSONObject().put("track", "Test track"))
        .put("metadata", JSONObject().put("album", "Test album"))
        .put("finalization", JSONObject().put("published", true))
    val compact = writeAndRead(
        "native_download_worker_state.json",
        JSONObject().put("message", "Invalid native queue payload: $CANARY")
            .put("last_result", storage)
            .put(
                "items",
                JSONArray().put(failedItem(storage).put("error", JSONObject.NULL)).put(
                    JSONObject().put("status", "failed").put("result", completedResult)
                        .put("error", "residual $CANARY"),
                ),
            ),
    )
    assertEquals("Invalid native queue payload", compact.getString("message"))
    val storedFailure = compact.getJSONArray("items").getJSONObject(0)
    assertEquals("Failed to create file", storedFailure.getString("error"))
    assertEquals("android_finalizing", compact.getJSONObject("last_result").getString("failure_stage"))
    assertEquals(
        completedResult.toString(),
        compact.getJSONArray("items").getJSONObject(1).getJSONObject("result").toString(),
    )
    assertEquals(true, storage.getString("error").contains(CANARY))

    val verification = JSONObject().put("success", false)
        .put("error", "Signed session expired: https://fixture.invalid/?token=$CANARY")
        .put("verification_url", "https://fixture.invalid/?token=$CANARY")
        .put("service", CANARY)
        .put("verification_service", CANARY)
        .put("provider", "fixture.test-extension")
        .put("source", CANARY)
    val delta = writeAndRead(
        "native_download_worker_progress.json",
        JSONObject().put("verified_service_version", 1)
            .put("message", "Native download failed during downloading: $CANARY")
            .put("item_delta", failedItem(verification))
            .put("item_deltas", JSONArray().put(failedItem(storage))),
    )
    val safeVerification = delta.getJSONObject("item_delta").getJSONObject("result")
    assertEquals("Download failed", delta.getString("message"))
    assertEquals("verification_required", safeVerification.getString("error_type"))
    assertEquals("fixture.test-extension", safeVerification.getString("service"))
    assertEquals("Verification required", safeVerification.getString("error"))
    assertEquals("Failed to create file", delta.getJSONArray("item_deltas").getJSONObject(0).getString("error"))

    val coldRead = JSONObject(delta.toString())
    NativeWorkerSnapshotDiagnostics.restore(coldRead) { error("Catalog unavailable on cold start") }
    val primary = "fixture.primary"
    val restoredService = coldRead.getJSONObject("item_delta").getJSONObject("result").optString("service")
        .ifBlank { primary }
    assertEquals("fixture.test-extension", restoredService)
    assertFalse(coldRead.toString().contains(CANARY))

    val stoppedState = File(directory, "stopped-state.json")
    val stoppedProgress = File(directory, "stopped-progress.json")
    StoppedNativeWorkerStore.writeDurably(
        stoppedState,
        JSONObject().put("run_id", "fixture").put("is_running", false).put("snapshot_serial", 2)
            .put("items", JSONArray().put(failedItem(verification)).put(JSONObject()
                .put("item_id", "discarded-item").put("status", "queued"))),
    ) { setOf("fixture.test-extension") }
    val stopped = StoppedNativeWorkerStore(stoppedState, stoppedProgress)
    assertEquals(true, stopped.discard("fixture", setOf("discarded-item"), false, false))
    val afterDiscard = checkNotNull(stopped.read())
    NativeWorkerSnapshotDiagnostics.restore(afterDiscard) { error("Catalog unavailable on cold start") }
    assertEquals("fixture.test-extension", afterDiscard.getJSONArray("items").getJSONObject(0)
        .getJSONObject("result").getString("service"))
    assertEquals(3L, afterDiscard.getLong("snapshot_serial"))

    val rawState = File(directory, "corrupt-state.json")
    val rawProgress = File(directory, "corrupt-progress.json")
    val store = StoppedNativeWorkerStore(rawState, rawProgress)
    for (malformed in listOf(
        """{"message":"$CANARY","items":[""",
        JSONObject().put("run_id", "fixture").put("is_running", false)
            .put("items", JSONArray().put(CANARY)).toString(),
    )) {
        rawState.writeText(malformed)
        val readFailure = runCatching { store.read() }.exceptionOrNull()
        val discardFailure = runCatching { store.discard("fixture", emptySet(), true, false) }.exceptionOrNull()
        assertEquals("Unreadable native worker state", readFailure?.message)
        assertEquals("Unreadable native worker state", discardFailure?.message)
        assertEquals(null, readFailure?.cause)
        assertEquals(null, discardFailure?.cause)
        assertEquals(malformed, rawState.readText())
    }
    val validState = JSONObject().put("run_id", "fixture").put("is_running", false)
        .put("items", JSONArray()).toString()
    rawState.writeText(validState)
    rawProgress.writeText("""{"message":"$CANARY","items":[""")
    val progressFailure = runCatching { store.discard("fixture", emptySet(), true, false) }.exceptionOrNull()
    assertEquals("Unreadable native worker progress", progressFailure?.message)
    assertEquals(null, progressFailure?.cause)
    assertEquals(validState, rawState.readText())
}
