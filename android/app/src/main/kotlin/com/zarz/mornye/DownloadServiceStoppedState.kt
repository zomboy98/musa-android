package com.zarz.mornye

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File

/** All callers (including snapshot writers) hold the service's state-file lock. */
internal class StoppedNativeWorkerStore(
    private val stateFile: File,
    private val progressFile: File,
    private val commit: (JSONObject) -> Unit = { writeDurably(stateFile, it, previouslyPersisted = true) },
) {
    fun read(): JSONObject? = if (stateFile.exists() || File("${stateFile.path}.bak").exists()) {
        readWorkerSnapshot(stateFile, "Unreadable native worker state", ::validateState)
    } else null

    fun discard(runId: String, itemIds: Set<String>, allRequests: Boolean, busy: Boolean): Boolean {
        if (runId.isBlank() || itemIds.any { it.isBlank() } || (!allRequests && itemIds.isEmpty())) return false
        val state = read() ?: return false // Absence is never an acknowledgement.
        val receipts = state.optJSONObject(RECEIPTS) ?: JSONObject()
        val receipt = receipts.optJSONObject(runId)
        if (covers(receipt, itemIds, allRequests)) return true
        if (busy || state.optString("run_id") != runId ||
            !state.has("is_running") || state.optBoolean("is_running", true)) return false
        val items = state.optJSONArray("items") ?: return false
        val remaining = JSONArray()
        val remainingIds = JSONArray()
        var removed = 0
        val removedCounts = mutableMapOf<String, Int>()
        for (index in 0 until items.length()) {
            val item = items.getJSONObject(index)
            val id = item.getString("item_id")
            if (allRequests || id in itemIds) {
                removed++
                val status = item.optString("status")
                removedCounts[status] = (removedCounts[status] ?: 0) + 1
            } else {
                remaining.put(item)
                remainingIds.put(id)
            }
        }
        val discarded = stringSet(receipt?.optJSONArray("item_ids")).apply { addAll(itemIds) }
        receipts.put(runId, JSONObject().put("all", allRequests).put("item_ids", JSONArray(discarded.toList())))
        state.put(RECEIPTS, receipts)
            .put("items", remaining).put("item_ids", remainingIds)
            .put("is_running", false).put("is_paused", false)
            .put("total", if (allRequests) 0 else (state.optInt("total") - removed).coerceAtLeast(remaining.length()))
        for (status in listOf("completed", "failed", "skipped")) {
            state.put(status, if (allRequests) 0 else (state.optInt(status) - (removedCounts[status] ?: 0)).coerceAtLeast(0))
        }
        if (allRequests || state.optString("current_item_id") in itemIds) {
            state.put("current_item_id", "")
            state.remove("last_result")
        }
        // A receipt seals this stopped run. Its progress file is no longer merged.
        state.remove("item_delta")
        state.remove("item_deltas")
        val progressSerial = if (progressFile.exists()) {
            readWorkerSnapshot(progressFile, "Unreadable native worker progress").optLong("snapshot_serial")
        } else 0L
        val serial = maxOf(state.optLong("snapshot_serial"), progressSerial) + 1
        state.put("snapshot_serial", serial).put("state_serial", serial)
        commit(state)
        val verified = read() ?: return false
        return verified.toString() == state.toString() &&
            covers(verified.optJSONObject(RECEIPTS)?.optJSONObject(runId), itemIds, allRequests)
    }

    companion object {
        const val RECEIPTS = "stopped_discard_receipts"

        private fun validateState(state: JSONObject) {
            if (state.opt("run_id") !is String || state.opt("is_running") !is Boolean ||
                state.opt("items") !is JSONArray) {
                throw JSONException("Invalid native worker state shape")
            }
            val items = state.getJSONArray("items")
            for (index in 0 until items.length()) {
                val item = items.getJSONObject(index)
                if (item.opt("item_id") !is String || item.getString("item_id").isBlank()) {
                    throw JSONException("Invalid native worker item identity")
                }
            }
            if (state.has(RECEIPTS)) {
                val receipts = state.getJSONObject(RECEIPTS)
                for (runId in receipts.keys()) {
                    val receipt = receipts.getJSONObject(runId)
                    if (receipt.opt("all") !is Boolean || receipt.opt("item_ids") !is JSONArray) {
                        throw JSONException("Invalid native worker discard receipt")
                    }
                    val ids = receipt.getJSONArray("item_ids")
                    for (index in 0 until ids.length()) {
                        if (ids.get(index) !is String) throw JSONException("Invalid discarded item identity")
                    }
                }
            }
        }

        fun isSealed(state: JSONObject?, runId: String): Boolean =
            state?.optJSONObject(RECEIPTS)?.has(runId) == true

        private fun covers(receipt: JSONObject?, ids: Set<String>, all: Boolean): Boolean =
            receipt != null && (receipt.optBoolean("all") || (!all && stringSet(receipt.optJSONArray("item_ids")).containsAll(ids)))

        private fun stringSet(array: JSONArray?): MutableSet<String> = mutableSetOf<String>().apply {
            if (array != null) for (index in 0 until array.length()) add(array.getString(index))
        }

        fun writeDurably(
            file: File,
            state: JSONObject,
            previouslyPersisted: Boolean = false,
            installedServiceIds: () -> Set<String> = { emptySet() },
        ) {
            NativeWorkerSnapshotDiagnostics.prepareForWrite(state, previouslyPersisted, installedServiceIds)
            val atomic = AtomicFile(file)
            val stream = atomic.startWrite()
            try {
                stream.write(state.toString().toByteArray(Charsets.UTF_8))
                // AtomicFile.finishWrite logs some sync failures; never ACK one.
                stream.fd.sync()
                atomic.finishWrite(stream)
            } catch (error: Exception) {
                atomic.failWrite(stream)
                throw error
            }
        }
    }
}

internal fun readWorkerSnapshot(
    file: File,
    errorMessage: String,
    validate: (JSONObject) -> Unit = {},
): JSONObject = try {
    AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use {
        JSONObject(it.readText()).also(validate)
    }
} catch (_: Exception) {
    // JSON parser errors can echo private input. Do not attach the cause.
    throw IllegalStateException(errorMessage)
}
