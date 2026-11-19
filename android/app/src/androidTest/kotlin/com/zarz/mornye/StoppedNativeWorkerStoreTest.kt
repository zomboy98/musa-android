package com.zarz.mornye

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException

@RunWith(AndroidJUnit4::class)
class StoppedNativeWorkerStoreTest {
    private lateinit var directory: File
    private lateinit var state: File
    private lateinit var progress: File
    private lateinit var store: StoppedNativeWorkerStore

    @Before fun setup() {
        directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "discard-test-${System.nanoTime()}")
        check(directory.mkdirs())
        state = File(directory, "state.json")
        progress = File(directory, "progress.json")
        store = StoppedNativeWorkerStore(state, progress)
    }

    @After fun cleanup() { directory.deleteRecursively() }

    private fun seed(run: String = "run-a", running: Boolean = false) {
        StoppedNativeWorkerStore.writeDurably(state, JSONObject()
            .put("run_id", run).put("is_running", running).put("snapshot_serial", 7)
            .put("total", 3).put("completed", 1).put("failed", 1).put("skipped", 0)
            .put("items", JSONArray().put(item("a", "completed")).put(item("b", "queued")).put(item("c", "failed"))))
    }

    private fun item(id: String, status: String) = JSONObject().put("item_id", id).put("status", status).put("payload", "keep-$id")
    private fun ids(): List<String> {
        val items = store.read()!!.getJSONArray("items")
        return (0 until items.length()).map { items.getJSONObject(it).getString("item_id") }
    }

    @Test fun selectedDiscardPreservesOtherPayloadsAndOrder() {
        seed()
        assertTrue(store.discard("run-a", setOf("b"), false, false))
        assertEquals(listOf("a", "c"), ids())
        assertEquals("keep-c", store.read()!!.getJSONArray("items").getJSONObject(1).getString("payload"))
        assertEquals(2, store.read()!!.getInt("total"))
        assertTrue(StoppedNativeWorkerStore.isSealed(store.read(), "run-a"))
    }

    @Test fun allDiscardRequiresExplicitAllFlag() {
        seed()
        assertFalse(store.discard("run-a", emptySet(), false, false))
        assertTrue(store.discard("run-a", emptySet(), true, false))
        assertEquals(emptyList<String>(), ids())
        assertEquals(0, store.read()!!.getInt("total"))
    }

    @Test fun missingOrDifferentRunNeverConfirmsOrChangesState() {
        assertFalse(store.discard("run-a", setOf("b"), false, false))
        seed("run-b")
        val before = state.readText()
        assertFalse(store.discard("run-a", setOf("b"), false, false))
        assertEquals(before, state.readText())
    }

    @Test fun cancelledButNotCompletedWorkerCannotConfirmStoppedSnapshot() {
        seed()
        val before = state.readText()
        assertFalse(store.discard("run-a", setOf("b"), false, true))
        assertEquals(before, state.readText())
        assertTrue(store.discard("run-a", setOf("b"), false, false))
    }

    @Test fun runningSnapshotCannotConfirmEvenWithNoJob() {
        seed(running = true)
        assertFalse(store.discard("run-a", setOf("b"), false, false))
    }

    @Test fun lostResponseRetryAndRepeatedSelectionAreIdempotent() {
        seed()
        assertTrue(store.discard("run-a", setOf("b"), false, false))
        val committed = state.readText()
        val reopened = StoppedNativeWorkerStore(state, progress)
        assertTrue(reopened.discard("run-a", setOf("b"), false, false))
        assertEquals(committed, state.readText())
        assertTrue(reopened.discard("run-a", setOf("a"), false, false))
        assertEquals(listOf("c"), ids())
        assertTrue(reopened.discard("run-a", setOf("a", "b"), false, false))
        assertFalse(reopened.discard("run-a", emptySet(), true, true))
    }

    @Test fun receiptFromOldRunDoesNotMutateNewRun() {
        seed()
        assertTrue(store.discard("run-a", setOf("b"), false, false))
        val receipts = store.read()!!.getJSONObject(StoppedNativeWorkerStore.RECEIPTS)
        seed("run-b", running = true)
        val replacement = store.read()!!.put(StoppedNativeWorkerStore.RECEIPTS, receipts)
        StoppedNativeWorkerStore.writeDurably(state, replacement)
        val before = state.readText()
        assertTrue(store.discard("run-a", setOf("b"), false, true))
        assertFalse(store.discard("run-a", setOf("c"), false, true))
        assertFalse(store.discard("run-a", emptySet(), true, true))
        assertEquals(before, state.readText())
    }

    @Test fun failedWriteCannotConfirmAndRetryWorks() {
        seed()
        val before = state.readText()
        val failing = StoppedNativeWorkerStore(state, progress) { throw IOException("injected disk failure") }
        try { failing.discard("run-a", setOf("b"), false, false); fail("Expected I/O error") } catch (_: IOException) { }
        assertEquals(before, state.readText())
        assertTrue(store.discard("run-a", setOf("b"), false, false))
    }

    @Test fun errorAfterDurableCommitCanBeRetried() {
        seed()
        val interrupted = StoppedNativeWorkerStore(state, progress) {
            StoppedNativeWorkerStore.writeDurably(state, it)
            throw IOException("lost response")
        }
        try { interrupted.discard("run-a", setOf("b"), false, false); fail("Expected lost response") } catch (_: IOException) { }
        assertTrue(store.discard("run-a", setOf("b"), false, false))
        assertEquals(listOf("a", "c"), ids())
    }

    @Test fun commitSerialSupersedesDelayedProgress() {
        seed()
        StoppedNativeWorkerStore.writeDurably(progress, JSONObject().put("run_id", "run-a").put("snapshot_serial", 90).put("is_running", true))
        assertTrue(store.discard("run-a", setOf("b"), false, false))
        assertEquals(91L, store.read()!!.getLong("snapshot_serial"))
    }
}
