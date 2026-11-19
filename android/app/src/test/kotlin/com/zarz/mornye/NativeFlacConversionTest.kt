package com.zarz.mornye

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class NativeFlacConversionTest {
    private fun withFiles(block: (File, File) -> Unit) {
        val directory = Files.createTempDirectory("native-flac-conversion-").toFile()
        try {
            val input = File(directory, "input.m4a").apply { writeText("original audio") }
            block(input, File(directory, "output.partial.flac"))
            assertEquals("original audio", input.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun writeFlacHeader(file: File) {
        file.writeBytes(byteArrayOf(0x66, 0x4c, 0x61, 0x43) + ByteArray(64))
    }

    @Test
    fun validRemuxSkipsEncoderAndLeavesSourceUntouched() = withFiles { input, output ->
        val commands = mutableListOf<List<String>>()
        convertToStagedFlac(input.path, output.path, "flac", { arguments ->
            commands.add(arguments.toList())
            if ("copy" in arguments) writeFlacHeader(output)
            true to ""
        }, {})
        assertEquals(2, commands.size)
        assertTrue("copy" in commands.first())
        assertFalse("-map" in commands.first())
        assertTrue("null" in commands.last())
        assertFalse("-frames:a" in commands.last())
        assertFalse(commands.any { "-compression_level" in it })
        assertTrue(output.exists())
    }

    @Test
    fun failedRemuxOrValidationNeverRetriesWithEncoder() {
        for (failure in listOf("command", "header", "decode")) {
            withFiles { input, output ->
                val commands = mutableListOf<List<String>>()
                assertThrows(IllegalStateException::class.java) {
                    convertToStagedFlac(input.path, output.path, "flac", { arguments ->
                        commands.add(arguments.toList())
                        if ("copy" in arguments) {
                            if (failure == "header") output.writeText("invalid") else writeFlacHeader(output)
                            (failure != "command") to "remux diagnostic"
                        } else {
                            (failure != "decode") to "decode diagnostic"
                        }
                    }, {})
                }
                assertTrue(commands.none { "-compression_level" in it })
                assertEquals(if (failure == "decode") 2 else 1, commands.size)
                assertFalse(output.exists())
            }
        }
    }

    @Test
    fun nonFlacIsRejectedWithoutRunningFfmpeg() = withFiles { input, output ->
        var calls = 0
        assertThrows(IllegalArgumentException::class.java) {
            convertToStagedFlac(input.path, output.path, "alac", {
                calls++
                true to ""
            }, {})
        }
        assertEquals(0, calls)
        assertFalse(output.exists())
    }

    @Test
    fun cancellationAfterRemuxDoesNotFallbackAndRemovesPartialOutput() = withFiles { input, output ->
        var cancelled = false
        var calls = 0
        assertThrows(CancellationException::class.java) {
            convertToStagedFlac(input.path, output.path, "flac", {
                calls++
                writeFlacHeader(output)
                cancelled = true
                false to "cancelled"
            }, {
                if (cancelled) throw CancellationException()
            })
        }
        assertEquals(1, calls)
        assertFalse(output.exists())
    }

}
