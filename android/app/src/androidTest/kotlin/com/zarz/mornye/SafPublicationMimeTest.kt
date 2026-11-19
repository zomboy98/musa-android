package com.zarz.mornye

import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SafPublicationMimeTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "com.mornye.test.documents.lookup"
    private val treeUri = DocumentsContract.buildTreeDocumentUri(authority, "root")

    private fun reset(fail: Boolean = false, collision: Boolean = false, restoreFailure: Boolean = false, reuse: Boolean = false, mode: String = "normal"): DocumentFile {
        context.contentResolver.call(Uri.parse("content://$authority.control"), "lookup.reset", null, Bundle().apply {
            putString("targetPackage", context.packageName)
            putBoolean("failFinalRename", fail)
            putBoolean("collideOnFailure", collision)
            putBoolean("failRestore", restoreFailure)
            putBoolean("reuseExistingOnCreate", reuse)
            putString("mode", mode)
        })
        return requireNotNull(DocumentFile.fromTreeUri(context, treeUri))
    }

    @Test
    fun rejectedSnapshotProjectionFallsBackToCompleteUnprojectedListing() {
        reset(mode = "snapshot-reject")
        val source = File(context.cacheDir, "saf-fallback-${System.nanoTime()}").apply { writeText("new") }
        try {
            val uri = requireNotNull(SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path))
            assertEquals("new", context.contentResolver.openInputStream(Uri.parse(uri))?.bufferedReader()?.use { it.readText() })
        } finally { source.delete() }
    }

    @Test
    fun partialListingWithProviderErrorDoesNotCreateWriteOrDelete() {
        for (mode in listOf("partial-error", "snapshot-reject-partial")) {
        val parent = reset(mode = mode)
        val source = File(context.cacheDir, "saf-partial-${System.nanoTime()}").apply { writeText("new") }
        try {
            assertNull(SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path))
            val stats = requireNotNull(context.contentResolver.call(Uri.parse("content://$authority.control"), "lookup.stats", null, null))
            assertTrue(requireNotNull(stats.getStringArrayList("createdNames")).isEmpty())
            assertEquals(0, stats.getInt("writeOpens"))
            assertEquals(0, stats.getInt("deletes"))
            val original = requireNotNull(findSafChild(context, parent, "Song.flac"))
            assertEquals("original", context.contentResolver.openInputStream(original.uri)?.bufferedReader()?.use { it.readText() })
        } finally { source.delete() }
        }
    }

    @Test
    fun providerReturningExistingIdIsNeverOpenedForWriteOrDeleted() {
        val parent = reset(reuse = true)
        val source = File(context.cacheDir, "saf-foreign-${System.nanoTime()}").apply { writeText("new") }
        try {
            assertNull(SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path))
            val stats = requireNotNull(context.contentResolver.call(Uri.parse("content://$authority.control"), "lookup.stats", null, null))
            assertEquals(0, stats.getInt("originalWriteOpens"))
            assertEquals(0, stats.getInt("originalDeletes"))
            val original = requireNotNull(findSafChild(context, parent, "Song.flac"))
            assertEquals("original", context.contentResolver.openInputStream(original.uri)?.bufferedReader()?.use { it.readText() })
        } finally { source.delete() }
    }

    @Test
    fun everyPublicationPathRetainsAudioMimeAndBytesAfterOpaqueRename() {
        val bytes = ByteArray(16384) { (it % 251).toByte() }
        val source = File(context.cacheDir, "publish-mime-${System.nanoTime()}.tmp").apply { writeBytes(bytes) }
        try {
            for ((extension, mime) in listOf("flac" to "audio/flac", "mp3" to "audio/mpeg", "m4a" to "audio/mp4", "opus" to "audio/opus")) {
                for (mode in 0..3) {
                    val parent = reset()
                    val name = "EjAj - Lej Mi Pół.$extension"
                    val uri = requireNotNull(when (mode) {
                        0 -> SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", name, mime, source.path)
                        1 -> SafDownloadHandler.writeFileToSafUnique(context, treeUri.toString(), "", name, mime, source.path)?.uri
                        2 -> SafDownloadHandler.writeFileToSafCollisionAware(context, treeUri.toString(), "", name, "Variant.$extension", mime, source.path)?.uri
                        else -> SafDownloadHandler.writeFileToSafIfAbsent(context, treeUri.toString(), "", name, mime, source.path)?.uri
                    })
                    val published = Uri.parse(uri)
                    assertEquals("$extension/$mode", mime, context.contentResolver.getType(published))
                    assertEquals(name, findSafChild(context, parent, name)?.name)
                    assertArrayEquals(bytes, context.contentResolver.openInputStream(published)?.use { it.readBytes() })
                    assertNull(findSafChild(context, parent, "$name.partial"))
                    assertNull(findSafChild(context, parent, name.removeSuffix(".$extension") + ".partial.$extension"))
                    assertNull(findSafChild(context, parent, SafDownloadHandler.buildStagedSafFileName(name)))
                    val stats = requireNotNull(context.contentResolver.call(
                        Uri.parse("content://$authority.control"), "lookup.stats", null, null,
                    ))
                    val created = requireNotNull(stats.getStringArrayList("createdNames"))
                    assertTrue(
                        "$extension/$mode: $created",
                        created.isNotEmpty() && created.all { it.startsWith(".") },
                    )
                    assertNotNull(source.takeIf { it.exists() })
                }
            }
        } finally { source.delete() }
    }

    @Test
    fun replacementPreservesForeignTemporaryFilesAndBackup() {
        val parent = reset()
        val legacy = listOf("Song.partial.flac", "Song.flac.partial", "Song.flac.replaced", ".Song.partial.flac")
        for (name in legacy) requireNotNull(parent.createFile("audio/flac", name))
        context.contentResolver.call(
            Uri.parse("content://$authority.control"), "lookup.clearCounters", null, null,
        )
        val bytes = ByteArray(16384) { (it % 251).toByte() }
        val source = File(context.cacheDir, "publish-replacement-${System.nanoTime()}.tmp")
            .apply { writeBytes(bytes) }
        try {
            val uri = requireNotNull(SafDownloadHandler.writeFileToSaf(
                context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path,
            ))
            assertArrayEquals(bytes, context.contentResolver.openInputStream(Uri.parse(uri))?.use { it.readBytes() })
            assertEquals("audio/flac", context.contentResolver.getType(Uri.parse(uri)))
            for (name in legacy) {
                assertNotNull(name, findSafChild(context, parent, name))
            }
            val stats = requireNotNull(context.contentResolver.call(
                Uri.parse("content://$authority.control"), "lookup.stats", null, null,
            ))
            assertTrue(requireNotNull(stats.getStringArrayList("createdNames")).single().contains(".partial.flac"))
            val renamed = requireNotNull(stats.getStringArrayList("renamedNames"))
            assertTrue(renamed[0].endsWith(".replaced"))
            assertEquals("Song.flac", renamed[1])
            val backup = requireNotNull(findSafChild(context, parent, renamed[0]))
            assertEquals("original", context.contentResolver.openInputStream(backup.uri)?.bufferedReader()?.use { it.readText() })
        } finally { source.delete() }
    }

    @Test
    fun failedPublicationRestoresUsingRenamedDocumentIdOrPreservesBackup() {
        for ((collision, restoreFailure) in listOf(false to false, true to false, false to true)) {
            val parent = reset(fail = true, collision = collision, restoreFailure = restoreFailure)
            val source = File(context.cacheDir, "saf-failed-${System.nanoTime()}").apply { writeText("new") }
            try {
                assertNull(SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path))
                val stats = requireNotNull(context.contentResolver.call(Uri.parse("content://$authority.control"), "lookup.stats", null, null))
                val aside = requireNotNull(stats.getStringArrayList("renamedNames")).first()
                val stagedIds = requireNotNull(stats.getStringArrayList("createdIds"))
                assertEquals(1, stagedIds.size)
                val remainingIds = parent.listFiles().map { DocumentsContract.getDocumentId(it.uri) }.toSet()
                assertTrue(stagedIds.none { it in remainingIds })
                val final = findSafChild(context, parent, "Song.flac")
                if (!collision && !restoreFailure) {
                    assertEquals("original", context.contentResolver.openInputStream(requireNotNull(final).uri)?.bufferedReader()?.use { it.readText() })
                    assertNull(findSafChild(context, parent, aside))
                } else {
                    val backup = requireNotNull(findSafChild(context, parent, aside))
                    assertEquals("original", context.contentResolver.openInputStream(backup.uri)?.bufferedReader()?.use { it.readText() })
                    if (collision) assertEquals("other", context.contentResolver.openInputStream(requireNotNull(final).uri)?.bufferedReader()?.use { it.readText() })
                    else assertNull(final)
                }
            } finally { source.delete() }
        }
    }
}
