package com.zarz.mornye

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream

/** One workspace per process; in-flight media must survive cache eviction. */
internal class NativeMediaWorkspace(privateDirectory: File) {
    val directory = File(privateDirectory, "native-media-work")

    init {
        // These app-owned scratch files cannot resume after process death.
        // Reclaim them once at startup, before any download or scan can begin.
        ensureDirectory().listFiles()?.forEach { it.delete() }
    }

    fun ensureDirectory(): File {
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Could not prepare native media workspace: ${directory.path}")
        }
        return directory
    }

    fun createTemporaryFile(prefix: String, suffix: String): File =
        File.createTempFile(prefix, suffix, ensureDirectory())
}

/** Only the caller's newly created input belongs to this operation, not a hook's replacement. */
internal inline fun <T> withOwnedTemporaryMediaFile(file: File, block: (File) -> T): T {
    try {
        return block(file)
    } finally {
        try { file.delete() } catch (_: Exception) {}
    }
}

/** Transfers ownership only after a complete copy; failed reads retire the partial input. */
internal fun copyToTemporaryMediaFile(file: File, openInput: () -> InputStream?): File? {
    var complete = false
    try {
        openInput()?.use { input ->
            FileOutputStream(file).use { output ->
                input.copyTo(output, bufferSize = 256 * 1024)
            }
        } ?: return null
        complete = true
        return file
    } finally {
        if (!complete) {
            try { file.delete() } catch (_: Exception) {}
        }
    }
}

/** Reserves an exclusive namespace without creating the backend destination. */
internal class SafMediaAttempt private constructor(val directory: File, val output: File) {
    companion object {
        private fun root(privateDirectory: File): File =
            File(privateDirectory.canonicalFile, "native-saf-attempts")

        // Older persisted markers can contain the platform's alias for the trusted anchor.
        // Translate only that prefix; descendants must still pass canonical checks.
        private fun markerPath(privateDirectory: File, path: String): File {
            val anchor = privateDirectory.absoluteFile.path
            val absolute = File(path).absoluteFile.path
            return if (absolute.startsWith(anchor + File.separator)) {
                File(privateDirectory.canonicalFile, absolute.substring(anchor.length + 1))
            } else File(absolute)
        }

        fun create(privateDirectory: File, suffix: String): SafMediaAttempt {
            if (File("output" + suffix).name != "output" + suffix) throw IOException("Invalid SAF attempt path")
            val root = root(privateDirectory)
            if (root.canonicalFile != root) throw IOException("Invalid SAF workspace path")
            if (!root.mkdirs() && !root.isDirectory) throw IOException("Could not prepare SAF workspace")
            if (root.canonicalFile != root) throw IOException("Invalid SAF workspace path")
            repeat(100) {
                val directory = File(root, java.util.UUID.randomUUID().toString())
                if (directory.mkdir()) {
                    val output = File(directory, "output" + suffix)
                    if (directory.canonicalFile != directory || output.parentFile != directory ||
                        output.canonicalFile != output) throw IOException("Invalid SAF attempt path")
                    return SafMediaAttempt(directory, output)
                }
            }
            throw IOException("Could not reserve SAF attempt")
        }

        /** A persisted marker permits removal of an empty directory only. */
        fun cleanupTransferredEmptyDirectory(privateDirectory: File, marker: String): Boolean {
            return try {
                val root = root(privateDirectory)
                val dir = markerPath(privateDirectory, marker)
                if (root.canonicalFile != root || dir.canonicalFile != dir || dir.parentFile != root) return false
                if (java.util.UUID.fromString(dir.name).toString() != dir.name) return false
                dir.isDirectory && dir.delete()
            } catch (_: Exception) {
                false
            }
        }

        fun isTransferredOutput(privateDirectory: File, marker: String, sourcePath: String): Boolean {
            return try {
                val root = root(privateDirectory)
                val dir = markerPath(privateDirectory, marker)
                val source = markerPath(privateDirectory, sourcePath)
                if (root.canonicalFile != root || dir.canonicalFile != dir || dir.parentFile != root ||
                    java.util.UUID.fromString(dir.name).toString() != dir.name ||
                    source.parentFile != dir || source.canonicalFile != source || !source.isFile) return false
                true
            } catch (_: Exception) {
                false
            }
        }

        fun deleteTransferredOutput(privateDirectory: File, marker: String, sourcePath: String): Boolean =
            isTransferredOutput(privateDirectory, marker, sourcePath) && markerPath(privateDirectory, sourcePath).delete()
    }

    /** Delete only an output reported successful inside our exclusive directory. */
    fun release(successfulPath: String? = null) {
        if (successfulPath != null) {
            val candidate = File(successfulPath)
            try {
                if (directory.canonicalFile == directory.absoluteFile &&
                    candidate.canonicalFile == candidate.absoluteFile &&
                    candidate.absoluteFile.parentFile == directory.absoluteFile && candidate.isFile) {
                    candidate.delete()
                }
            } catch (_: Exception) {}
        }
        // Do not recursively delete: a collision or active producer may own a file.
        try { if (directory.canonicalFile == directory.absoluteFile) directory.delete() } catch (_: Exception) {}
    }

    /** Only host-published files in this attempt can become deferred input. */
    fun publishedOutput(reportedPath: String, alreadyExists: Boolean): File? {
        if (alreadyExists) return null
        val candidate = if (reportedPath.isBlank() || reportedPath.startsWith("/proc/self/fd/")) {
            output.absoluteFile
        } else {
            File(reportedPath).absoluteFile
        }
        return try {
            if (directory.canonicalFile != directory.absoluteFile ||
                candidate.parentFile != directory.absoluteFile ||
                candidate.canonicalFile != candidate || !candidate.isFile) null else candidate
        } catch (_: Exception) {
            null
        }
    }
}
