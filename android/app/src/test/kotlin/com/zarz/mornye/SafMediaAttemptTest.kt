package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SafMediaAttemptTest {
    @Test fun rejectsSuffixThatWouldEscapeAttempt() {
        val base = Files.createTempDirectory("saf-suffix-test").toFile()
        try {
            try {
                SafMediaAttempt.create(base, "/../../escape")
                fail("A suffix cannot contain path components")
            } catch (_: java.io.IOException) {}
            assertFalse(File(base, "native-saf-attempts").exists())
        } finally { base.deleteRecursively() }
    }
    @Test fun rejectsLinksAtWorkspaceAttemptAndOutput() {
        val base = Files.createTempDirectory("saf-link-test").toFile()
        try {
            val privateDir = File(base, "private").apply { mkdir() }
            val other = File(base, "other").apply { mkdir() }
            val workspace = File(privateDir, "native-saf-attempts")
            val siblingRoot = File(privateDir, "sibling").apply { mkdir() }
            for (target in listOf(other, siblingRoot)) {
                try { Files.createSymbolicLink(workspace.toPath(), target.toPath()) }
                catch (_: Exception) { org.junit.Assume.assumeTrue("Symbolic links unavailable", false) }
                try {
                    SafMediaAttempt.create(privateDir, ".mp3")
                    fail("Linked workspace must be rejected")
                } catch (_: java.io.IOException) {}
                assertTrue(Files.isSymbolicLink(workspace.toPath()))
                assertTrue(workspace.delete())
            }
            val attempt = SafMediaAttempt.create(privateDir, ".mp3")
            val external = File(other, "audio").apply { writeText("keep") }
            Files.createSymbolicLink(attempt.output.toPath(), external.toPath())
            assertNull(attempt.publishedOutput(attempt.output.path, false))
            assertFalse(SafMediaAttempt.deleteTransferredOutput(privateDir, attempt.directory.path, attempt.output.path))
            attempt.release(attempt.output.path)
            assertTrue(Files.isSymbolicLink(attempt.output.toPath()))
            assertEquals("keep", external.readText())
            assertTrue(attempt.output.delete())
            assertTrue(attempt.directory.delete())
            val sibling = SafMediaAttempt.create(privateDir, ".mp3")
            sibling.output.writeText("sibling")
            for (target in listOf(sibling.directory, other)) {
                Files.createSymbolicLink(attempt.directory.toPath(), target.toPath())
                assertFalse(SafMediaAttempt.cleanupTransferredEmptyDirectory(privateDir, attempt.directory.path))
                val linkedOutput = File(attempt.directory, if (target == sibling.directory) sibling.output.name else external.name)
                assertTrue(linkedOutput.isFile)
                assertFalse(SafMediaAttempt.isTransferredOutput(privateDir, attempt.directory.path, linkedOutput.path))
                attempt.release()
                assertTrue(Files.isSymbolicLink(attempt.directory.toPath()))
                assertTrue(attempt.directory.delete())
            }
            assertEquals("sibling", sibling.output.readText())
        } finally { base.deleteRecursively() }
    }
    @Test fun canonicalizesTrustedAnchorAndAcceptsLegacyMarkers() {
        val base = Files.createTempDirectory("saf-anchor-test").toFile()
        try {
            val real = File(base, "real").apply { mkdir() }
            val alias = File(base, "alias")
            try { Files.createSymbolicLink(alias.toPath(), real.toPath()) }
            catch (_: Exception) { org.junit.Assume.assumeTrue("Symbolic links unavailable", false) }
            val attempt = SafMediaAttempt.create(alias, ".mp3")
            attempt.output.writeText("audio")
            val legacyDir = File(alias, "native-saf-attempts/${attempt.directory.name}")
            val legacyOutput = File(legacyDir, attempt.output.name)
            assertEquals(attempt.output, attempt.publishedOutput(attempt.output.path, false))
            assertTrue(SafMediaAttempt.isTransferredOutput(alias, legacyDir.path, legacyOutput.path))
            assertTrue(SafMediaAttempt.deleteTransferredOutput(alias, legacyDir.path, legacyOutput.path))
            assertTrue(SafMediaAttempt.cleanupTransferredEmptyDirectory(alias, legacyDir.path))
        } finally { base.deleteRecursively() }
    }
    @Test fun reservesDistinctDirectoriesAndAbsentOutput() {
        val root = Files.createTempDirectory("saf-attempt-test").toFile()
        try {
            val first = SafMediaAttempt.create(root, ".mp3")
            val second = SafMediaAttempt.create(root, ".mp3")
            assertNotEquals(first.directory, second.directory)
            assertFalse(first.output.exists())
            assertFalse(second.output.exists())
            first.output.writeText("complete")
            first.release(first.output.absolutePath)
            assertFalse(first.directory.exists())
            assertTrue(second.directory.exists())
            second.release()
        } finally { root.deleteRecursively() }
    }

    @Test fun failureOrCancellationDoesNotDeleteCollidingFile() {
        val root = Files.createTempDirectory("saf-attempt-test").toFile()
        try {
            val attempt = SafMediaAttempt.create(root, ".mp3")
            attempt.output.writeText("other producer")
            attempt.release()
            assertEquals("other producer", attempt.output.readText())
            assertTrue(attempt.directory.isDirectory)
        } finally { root.deleteRecursively() }
    }

    @Test fun neverDeletesReportedExternalFile() {
        val root = Files.createTempDirectory("saf-attempt-test").toFile()
        try {
            val external = File(root, "user.mp3").apply { writeText("user") }
            val attempt = SafMediaAttempt.create(root, ".mp3")
            attempt.release(external.absolutePath)
            assertEquals("user", external.readText())
            assertFalse(attempt.directory.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun transferredCleanupOnlyRemovesEmptyOwnedDirectory() {
        val root = Files.createTempDirectory("saf-attempt-test").toFile()
        try {
            val attempt = SafMediaAttempt.create(root, ".mp3")
            val external = File(root, "external").apply { mkdir() }
            assertFalse(SafMediaAttempt.cleanupTransferredEmptyDirectory(root, external.path))
            attempt.output.writeText("active")
            assertFalse(SafMediaAttempt.cleanupTransferredEmptyDirectory(root, attempt.directory.path))
            assertEquals("active", attempt.output.readText())
            assertTrue(attempt.output.delete())
            assertTrue(SafMediaAttempt.cleanupTransferredEmptyDirectory(root, attempt.directory.path))
            assertTrue(external.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun releaseWithoutArgumentRemovesOnlyEmptyAttemptDirectory() {
        val root = Files.createTempDirectory("saf-release-empty-test").toFile()
        try {
            val empty = SafMediaAttempt.create(root, ".mp3")
            assertTrue(empty.directory.isDirectory)
            empty.release()
            assertFalse(empty.directory.exists())
            assertTrue(File(root, "native-saf-attempts").isDirectory)
        } finally { root.deleteRecursively() }
    }

    @Test fun releaseWithoutArgumentKeepsFileAndNonEmptyDirectoryIntact() {
        val root = Files.createTempDirectory("saf-release-keep-test").toFile()
        try {
            val withFile = SafMediaAttempt.create(root, ".mp3")
            withFile.output.writeText("producer data")
            withFile.release()
            assertTrue(withFile.directory.isDirectory)
            assertEquals("producer data", withFile.output.readText())

            val withDir = SafMediaAttempt.create(root, ".mp3")
            val nested = File(withDir.directory, "nested").apply { mkdir() }
            val nestedFile = File(nested, "inner.bin").apply { writeText("inner") }
            withDir.release()
            assertTrue(withDir.directory.isDirectory)
            assertTrue(nested.isDirectory)
            assertEquals("inner", nestedFile.readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun releaseWithPathDeletesOwnSuccessFileAndDirectoryButNotExternalFile() {
        val root = Files.createTempDirectory("saf-release-path-test").toFile()
        try {
            val external = File(root, "external.mp3").apply { writeText("external") }
            val attempt = SafMediaAttempt.create(root, ".mp3")
            attempt.output.writeText("success")
            attempt.release(attempt.output.path)
            assertFalse(attempt.output.exists())
            assertFalse(attempt.directory.exists())
            assertTrue(external.isFile)
            assertEquals("external", external.readText())

            val other = SafMediaAttempt.create(root, ".mp3")
            other.output.writeText("success")
            other.release(external.path)
            assertEquals("external", external.readText())
            assertEquals("success", other.output.readText())
            assertTrue(other.directory.isDirectory)
        } finally { root.deleteRecursively() }
    }

    @Test fun rejectsExternalAndAlreadyExistingProviderOutputWithoutDeletingIt() {
        val root = Files.createTempDirectory("saf-attempt-test").toFile()
        try {
            val external = File(root, "user.mp3").apply { writeText("user data") }
            val attempt = SafMediaAttempt.create(root, ".mp3")
            assertNull(attempt.publishedOutput(external.absolutePath, false))
            assertNull(attempt.publishedOutput(external.absolutePath, true))
            attempt.output.writeText("collision")
            assertNull(attempt.publishedOutput(attempt.output.absolutePath, true))
            assertFalse(SafMediaAttempt.deleteTransferredOutput(root, attempt.directory.path, external.path))
            assertEquals("user data", external.readText())
            assertEquals("collision", attempt.output.readText())
            assertEquals(attempt.output, attempt.publishedOutput(attempt.output.path, false))
            assertTrue(SafMediaAttempt.deleteTransferredOutput(root, attempt.directory.path, attempt.output.path))
        } finally { root.deleteRecursively() }
    }
}
