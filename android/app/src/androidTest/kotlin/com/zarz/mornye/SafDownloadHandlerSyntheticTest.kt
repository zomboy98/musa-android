package com.zarz.mornye

import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.lang.reflect.Proxy
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Drives the real SafDownloadHandler.handle against the existing fake SAF provider
 * (LookupTestDocumentsProvider) with a synthetic CoreBackend. No provider, network,
 * conversion or audio is involved: the backend only writes deterministic bytes.
 */
@RunWith(AndroidJUnit4::class)
class SafDownloadHandlerSyntheticTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "com.mornye.test.documents.lookup"
    private val controlUri = Uri.parse("content://$authority.control")
    private val treeUri = DocumentsContract.buildTreeDocumentUri(authority, "root")

    private enum class Output { BYTES, EMPTY, ABSENT }

    private class Recorder {
        val requests = mutableListOf<JSONObject>()
        val grantedDirectories = mutableListOf<String>()
        var closedDirectories = 0
    }

    private fun reset(): DocumentFile {
        context.contentResolver.call(controlUri, "lookup.reset", null, Bundle().apply {
            putString("targetPackage", context.packageName)
            putString("mode", "normal")
        })
        return requireNotNull(DocumentFile.fromTreeUri(context, treeUri))
    }

    private fun syntheticBytes() = ByteArray(300_001) { ((it * 31 + 7) % 251).toByte() }

    /** Only the two CoreBackend members SafDownloadHandler.handle uses on the non-deferred SAF path. */
    private fun backend(
        recorder: Recorder,
        output: Output,
        bytes: ByteArray,
        success: Boolean = true,
        leaveFileOnFailure: Boolean = false,
    ): CoreBackend = Proxy.newProxyInstance(
        CoreBackend::class.java.classLoader, arrayOf(CoreBackend::class.java),
    ) { _, method, args ->
        when (method.name) {
            "openDownloadDirectory" -> {
                recorder.grantedDirectories += args[0] as String
                AutoCloseable { recorder.closedDirectories++ }
            }
            "downloadByStrategy" -> {
                val request = JSONObject(args[0] as String)
                recorder.requests += request
                val path = request.getString("output_path")
                if (!success) {
                    // Simulates a producer that may still own a partial file.
                    if (leaveFileOnFailure) File(path).writeBytes(bytes)
                    JSONObject().put("success", false).put("error", "synthetic failure").toString()
                } else {
                    when (output) {
                        Output.BYTES -> File(path).writeBytes(bytes)
                        Output.EMPTY -> File(path).writeBytes(ByteArray(0))
                        Output.ABSENT -> Unit
                    }
                    JSONObject().put("success", true).put("file_path", path).toString()
                }
            }
            else -> error("Unexpected backend call ${method.name}")
        }
    } as CoreBackend

    private fun request(fileName: String) = JSONObject()
        .put("storage_mode", "saf")
        .put("saf_tree_uri", treeUri.toString())
        .put("saf_relative_dir", "")
        .put("saf_output_ext", ".flac")
        .put("saf_file_name", fileName)
        .put("track_name", "Synthetic")
        .toString()

    private fun names(parent: DocumentFile) = parent.listFiles().map { it.name }.toSet()

    /** Private attempt directories (same root SafMediaAttempt.create uses). */
    private fun attemptDirs(): Set<String> =
        File(context.filesDir.canonicalFile, "native-saf-attempts")
            .list()?.toSet() ?: emptySet()

    private fun deferredRequest(fileName: String) =
        JSONObject(request(fileName)).put("defer_saf_publish", true).toString()

    @Test
    fun publishedContentUriHoldsTheBackendBytesExactly() {
        val parent = reset()
        val before = names(parent)
        val dirsBefore = attemptDirs()
        val bytes = syntheticBytes()
        val recorder = Recorder()

        val response = JSONObject(
            SafDownloadHandler.handle(context, request("Synthetic.flac"), backend(recorder, Output.BYTES, bytes)),
        )
        assertEquals("attempt dirs ${attemptDirs()}", dirsBefore, attemptDirs())

        assertTrue(response.toString(), response.getBoolean("success"))
        val filePath = response.getString("file_path")
        assertEquals("content", Uri.parse(filePath).scheme)
        assertEquals("Synthetic.flac", response.getString("file_name"))
        assertArrayEquals(bytes, context.contentResolver.openInputStream(Uri.parse(filePath))?.use { it.readBytes() })
        assertEquals("audio/flac", context.contentResolver.getType(Uri.parse(filePath)))

        // The real handler requested a private output inside a granted staging directory.
        val seen = recorder.requests.single()
        assertFalse(seen.has("output_fd"))
        assertEquals(".flac", seen.getString("output_ext"))
        assertEquals(1, recorder.grantedDirectories.size)
        assertEquals(recorder.grantedDirectories.single(), File(seen.getString("output_path")).parent)
        assertEquals(1, recorder.closedDirectories)

        // Exactly one new document, under the final name; no staged leftovers.
        assertEquals(before + "Synthetic.flac", names(parent))
        val published = requireNotNull(parent.listFiles().firstOrNull { it.name == "Synthetic.flac" })
        assertEquals(Uri.parse(filePath), published.uri)
        assertEquals(bytes.size.toLong(), published.length())
    }

    @Test
    fun emptyAbsentOrFailedBackendOutputLeavesNoDestination() {
        for ((label, output, success) in listOf(
            Triple("empty", Output.EMPTY, true),
            Triple("absent", Output.ABSENT, true),
            Triple("backend-failure", Output.ABSENT, false),
        )) {
            val parent = reset()
            val before = names(parent)
            val dirsBefore = attemptDirs()
            val recorder = Recorder()

            val response = JSONObject(
                SafDownloadHandler.handle(
                    context, request("Synthetic.flac"), backend(recorder, output, ByteArray(0), success),
                ),
            )
            // Neither empty nor absent output may leak an attempt directory.
            assertEquals("$label: attempt dirs ${attemptDirs()}", dirsBefore, attemptDirs())

            assertFalse("$label: $response", response.optBoolean("success", false))
            assertEquals("$label: backend was called once", 1, recorder.requests.size)
            assertEquals("$label: directory grant closed", 1, recorder.closedDirectories)
            // No final or staged document, empty or otherwise, survives in the tree.
            assertEquals("$label: ${names(parent)}", before, names(parent))
            assertTrue(parent.listFiles().none { it.name != "Song.flac" && it.isFile })
            // The pre-existing fixture is untouched.
            val original = requireNotNull(parent.listFiles().firstOrNull { it.name == "Song.flac" })
            assertNotNull(original)
            assertEquals(
                "original",
                context.contentResolver.openInputStream(original.uri)?.bufferedReader()?.use { it.readText() },
            )
        }
    }

    @Test
    fun failedBackendThatLeavesAFileKeepsItAndDoesNotRecurse() {
        val parent = reset()
        val before = names(parent)
        val dirsBefore = attemptDirs()
        val bytes = syntheticBytes()
        val recorder = Recorder()

        val response = JSONObject(
            SafDownloadHandler.handle(
                context, request("Synthetic.flac"),
                backend(recorder, Output.ABSENT, bytes, success = false, leaveFileOnFailure = true),
            ),
        )

        assertFalse(response.toString(), response.optBoolean("success", false))
        assertEquals(before, names(parent))
        val leaked = attemptDirs() - dirsBefore
        try {
            // Non-empty directory: release() without a path must keep the possibly-in-use file.
            assertEquals(leaked.toString(), 1, leaked.size)
            val dir = File(File(context.filesDir.canonicalFile, "native-saf-attempts"), leaked.single())
            assertArrayEquals(bytes, File(dir, "output.flac").readBytes())
        } finally {
            leaked.forEach {
                File(File(context.filesDir.canonicalFile, "native-saf-attempts"), it).deleteRecursively()
            }
        }
    }

    @Test
    fun deferredFailureWithoutOutputLeavesNoAttemptDirectory() {
        reset()
        val dirsBefore = attemptDirs()
        val recorder = Recorder()

        val response = JSONObject(
            SafDownloadHandler.handle(
                context, deferredRequest("Synthetic.flac"),
                backend(recorder, Output.ABSENT, ByteArray(0), success = false),
            ),
        )

        assertFalse(response.toString(), response.optBoolean("success", false))
        assertEquals(1, recorder.requests.size)
        assertEquals(dirsBefore, attemptDirs())
    }

    @Test
    fun deferredTransferredSuccessKeepsOwnedAttemptDirectoryAndOutput() {
        reset()
        val dirsBefore = attemptDirs()
        val bytes = syntheticBytes()
        val recorder = Recorder()

        val response = JSONObject(
            SafDownloadHandler.handle(
                context, deferredRequest("Synthetic.flac"), backend(recorder, Output.BYTES, bytes),
            ),
        )

        val owned = response.optString("saf_owned_attempt_dir")
        try {
            assertTrue(response.toString(), response.getBoolean("success"))
            assertTrue(response.getBoolean("saf_deferred_publish"))
            val dir = File(owned)
            assertTrue("owned dir kept: $owned", dir.isDirectory)
            assertEquals(1, (attemptDirs() - dirsBefore).size)
            assertArrayEquals(bytes, File(response.getString("file_path")).readBytes())
        } finally {
            if (owned.isNotBlank()) File(owned).deleteRecursively()
        }
    }
}
