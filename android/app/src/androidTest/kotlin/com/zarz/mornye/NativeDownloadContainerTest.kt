package com.zarz.mornye

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CancellationException
import org.junit.After
import org.junit.Before
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeDownloadContainerTest {
    private lateinit var backend: CoreBackend
    private lateinit var backendRoot: File

    @Before
    fun initializeBackend() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        backendRoot = File(context.filesDir, "finalizer-test-${System.nanoTime()}").apply { mkdirs() }
        backend = createCoreBackend(context)
        backend.invokeApplication("initExtensionSystem", mapOf(
            "extensions_dir" to File(backendRoot, "sources").apply { mkdirs() }.path,
            "data_dir" to File(backendRoot, "data").apply { mkdirs() }.path,
            "master_key" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "allowed_directories" to listOf(context.cacheDir.path),
        ))
    }

    @After
    fun closeBackend() {
        backend.invokeApplication("cleanupExtensions", emptyMap<String, Any>())
        backendRoot.deleteRecursively()
    }

    @Test
    fun selectedLibraryFilesCanBeEditedReenrichedAndExportArtworkOutsideDownloadRoot() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.filesDir, "selected-library-${System.nanoTime()}").apply { mkdirs() }
        try {
            val input = File(directory, "selected.flac")
            val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
                "-t", "0.5", "-c:a", "flac", input.path,
            ))
            assertTrue(fixture.second, fixture.first)
            val artwork = File(directory, "selected.png")
            val bitmap = android.graphics.Bitmap.createBitmap(4, 4, android.graphics.Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(android.graphics.Color.BLUE)
            artwork.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            val edit = JSONObject(backend.editFileMetadata(input.path, JSONObject()
                .put("title", "Edited title").put("cover_path", artwork.path)
                .put("replaygain_track_gain", "-7.00 dB").put("replaygain_track_peak", "0.750000").toString()))
            assertTrue(edit.toString(), edit.getBoolean("success"))
            val request = JSONObject().put("file_path", input.path).put("search_online", false)
                .put("track_name", "Enriched title").put("artist_name", "Example artist")
                .put("update_fields", org.json.JSONArray(listOf("track_name")))
            val enriched = JSONObject(backend.reEnrichFile(request.toString()))
            assertTrue(enriched.toString(), enriched.getBoolean("success"))
            val metadata = JSONObject(backend.readFileMetadata(input.path, input.name))
            assertEquals("Enriched title", metadata.getString("title"))
            assertEquals("-7.00 dB", metadata.getString("replaygain_track_gain"))
            val output = File(directory, "export.png")
            backend.extractCoverToFile(input.path, output.path)
            assertTrue(output.readBytes().contentEquals(artwork.readBytes()))
            val library = JSONObject(backend.readAudioMetadata(input.path, input.name, ""))
            assertEquals("Enriched title", library.getString("trackName"))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun libraryMetadataReadsAnOpenDescriptorWithoutGrantingItsFilesystemPath() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val artwork = File(backendRoot, "selected-cover.png")
        val bitmap = android.graphics.Bitmap.createBitmap(4, 4, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.GREEN)
        artwork.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        val input = File(backendRoot, "selected-track.flac")
        val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
            "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
            "-i", artwork.path, "-t", "0.5", "-map", "0:a", "-map", "1:v",
            "-c:a", "flac", "-c:v", "copy", "-disposition:v", "attached_pic",
            "-metadata", "title=Document track", input.path,
        ))
        assertTrue(fixture.second, fixture.first)
        val covers = File(context.cacheDir, "descriptor-covers-${System.nanoTime()}").apply { mkdirs() }
        try {
            backend.setLibraryCoverCacheDirectory(covers.path)
            android.os.ParcelFileDescriptor.open(input, android.os.ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                val result = JSONObject(backend.readAudioMetadata(
                    "/proc/self/fd/${descriptor.fd}", input.name, "content://example/tree/music/selected-track.flac",
                ))
                assertEquals("Document track", result.getString("trackName"))
                assertEquals(48000, result.getInt("sampleRate"))
                assertFalse(result.optBoolean("metadataFromFilename"))
                val cachedCover = File(result.getString("coverPath"))
                assertEquals(covers.canonicalPath, cachedCover.parentFile!!.canonicalPath)
                assertTrue(cachedCover.readBytes().contentEquals(artwork.readBytes()))
                assertTrue(descriptor.statSize > 0)
            }
        } finally { covers.deleteRecursively() }
    }

    @Test
    fun descriptorArtworkExportPreservesOriginalResolutionAndBytes() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "original-artwork-${System.nanoTime()}").apply { mkdirs() }
        try {
            for ((width, height, format) in listOf(
                Triple(3000, 3000, android.graphics.Bitmap.CompressFormat.JPEG),
                Triple(4500, 4500, android.graphics.Bitmap.CompressFormat.PNG),
                Triple(3000, 1500, android.graphics.Bitmap.CompressFormat.PNG),
            )) {
                val artwork = File(directory, "cover-$width-$height.img")
                val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
                try {
                    bitmap.eraseColor(android.graphics.Color.GREEN)
                    artwork.outputStream().use { assertTrue(bitmap.compress(format, 95, it)) }
                } finally { bitmap.recycle() }
                val original = artwork.readBytes()
                val input = File(directory, "track-$width-$height.flac")
                val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
                    "-i", artwork.path, "-t", "0.1", "-map", "0:a", "-map", "1:v",
                    "-c:a", "flac", "-c:v", "copy", "-disposition:v", "attached_pic", input.path,
                ))
                assertTrue(fixture.second, fixture.first)
                val before = java.security.MessageDigest.getInstance("SHA-256").digest(input.readBytes())
                val exported = File(directory, "export-$width-$height.img")
                android.os.ParcelFileDescriptor.open(input, android.os.ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                    backend.extractCoverToFile("/proc/self/fd/${descriptor.fd}", exported.path, input.name)
                    assertTrue("$width x $height artwork must remain byte-identical", exported.readBytes().contentEquals(original))
                    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeFile(exported.path, bounds)
                    assertEquals(width, bounds.outWidth)
                    assertEquals(height, bounds.outHeight)
                    assertTrue(descriptor.statSize > 0)
                    if (width == 3000) {
                        val preview = com.mornye.backend.readLibraryMetadataFromDescriptor(
                            descriptor.fd, input.name, "2026-10-09T00:00:00Z", true, null,
                        ).coverBytes
                        android.graphics.BitmapFactory.decodeByteArray(preview, 0, preview.size, bounds)
                        assertEquals(800, bounds.outWidth)
                        assertEquals(if (height == 3000) 800 else 400, bounds.outHeight)
                    }
                }
                assertTrue(before.contentEquals(java.security.MessageDigest.getInstance("SHA-256").digest(input.readBytes())))
            }
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun nativeFormatsPreserveTagsLyricsAndReplayGain() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "finalizer-parity-${System.nanoTime()}").apply { mkdirs() }
        try {
            for ((extension, encoder) in listOf("mp3" to "libmp3lame", "opus" to "libopus", "flac" to "flac", "m4a" to "aac")) {
                val input = File(root, "track.$extension")
                val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
                    "-t", "1.5", "-c:a", encoder, input.path,
                ))
                assertTrue(fixture.second, fixture.first)
                val request = JSONObject()
                    .put("contract_version", 1).put("item_id", "example-$extension")
                    .put("service", "example-provider").put("track_name", "Parity test")
                    .put("artist_name", "Example artist").put("album_name", "Example album")
                    .put("album_artist", "Album Artist").put("track_number", 2).put("total_tracks", 10)
                    .put("quality", "LOSSLESS").put("storage_mode", "app")
                    .put("output_ext", ".$extension").put("embed_metadata", true)
                    .put("embed_lyrics", true).put("lyrics_mode", "both")
                    .put("embed_replaygain", true).put("duration_ms", 1500)
                val result = NativeDownloadFinalizer.finalize(
                    context, "example-$extension", request.toString(), "{}",
                    JSONObject().put("success", true).put("file_path", input.path)
                        .put("file_name", input.name).put("lyrics_lrc", "[00:00.00]Example line"),
                    "{\"save_download_history\":false}",
                )
                assertTrue(result.toString(), result.getBoolean("success"))
                assertFalse(result.toString(), result.has("replaygain_warning"))
                assertEquals(1.5, result.getJSONObject("replaygain").getDouble("duration_secs"), 0.001)
                val output = File(result.getString("file_path"))
                assertEquals(extension, output.extension)
                assertEquals("[00:00.00]Example line", File(root, "track.lrc").readText())
                File(root, "track.lrc").delete()
                val probe = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                    "-hide_banner", "-i", output.path, "-map", "0:a:0", "-f", "null", "-",
                ))
                assertTrue(probe.second, probe.first)
                val gainTag = if (extension == "opus") "r128_track_gain" else "replaygain_track_gain"
                for (tag in listOf("Parity test", "Album Artist", "Example line", gainTag)) {
                    assertTrue("$extension: missing $tag\n${probe.second}", probe.second.contains(tag, ignoreCase = true))
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun opusConversionPromotesPlayableOutputAfterTagging() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for ((format, encoder) in listOf("flac" to "flac", "m4a" to "aac")) {
            val source = createConversionFixture("source-$format.$format", encoder)
            val request = JSONObject()
                .put("quality", "LOSSLESS").put("storage_mode", "app")
                .put("track_name", "Synthetic Opus conversion").put("embed_metadata", true)
                .put("auto_convert_downloads", true).put("auto_convert_format", "opus")
                .put("auto_convert_bitrate", "160k")
            val result = NativeDownloadFinalizer.finalize(
                context, "opus-conversion-$format", request.toString(), "{}",
                JSONObject().put("success", true).put("file_path", source.path),
                "{\"save_download_history\":false}",
            )
            assertTrue(result.toString(), result.getBoolean("success"))
            assertFalse(result.toString(), result.has("auto_conversion_warning"))
            val output = File(result.getString("file_path"))
            assertEquals("opus", output.extension)
            assertEquals("opus", NativeDownloadFinalizer.probePrimaryAudioCodec(output.path))
            val metadata = JSONObject(backend.readFileMetadata(output.path, output.name))
            assertEquals("Synthetic Opus conversion", metadata.optString("title"))
        }
    }

    @Test
    fun defaultOpusConversionAcceptsLocalMonoAndStereoFlac() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for (channels in listOf(1, 2)) {
            val source = createConversionFixture("default-opus-$channels.flac", "flac", channels)
            val request = JSONObject()
                .put("contract_version", 1)
                .put("item_id", "default-opus-$channels").put("service", "example-provider")
                .put("track_name", "Default Opus conversion")
                .put("quality", "LOSSLESS").put("storage_mode", "app")
                .put("auto_convert_downloads", true).put("auto_convert_format", "opus")
            val result = NativeDownloadFinalizer.finalize(
                context, "default-opus-$channels", request.toString(), "{}",
                JSONObject().put("success", true).put("file_path", source.path),
                "{\"save_download_history\":false}",
            )
            assertTrue(result.toString(), result.getBoolean("success"))
            assertFalse(result.toString(), result.has("auto_conversion_warning"))
            val output = File(result.getString("file_path"))
            assertEquals("opus", output.extension)
            val encoded = output.readBytes()
            val opusHead = 27 + (encoded[26].toInt() and 0xFF)
            assertEquals("OpusHead", encoded.decodeToString(opusHead, opusHead + 8))
            assertEquals(channels, encoded[opusHead + 9].toInt())
            val decode = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                "-v", "error", "-xerror", "-i", output.path, "-map", "0:a", "-f", "null", "-",
            ))
            assertTrue(decode.second, decode.first)
            val measured = JSONObject(backend.readFileMetadata(output.path, output.name))
            assertEquals(measured.getInt("bitrate"), result.getInt("actual_bitrate"))

            val existing = NativeDownloadFinalizer.finalize(
                context, "default-opus-$channels", request.toString(), "{}",
                JSONObject().put("success", true).put("file_path", output.path)
                    .put("already_exists", true),
                "{\"save_download_history\":false}",
            )
            assertTrue(existing.toString(), existing.getBoolean("success"))
            assertFalse(existing.toString(), existing.has("auto_conversion_warning"))
            assertTrue(encoded.contentEquals(output.readBytes()))
        }
    }

    @Test
    fun defaultOpusKeepsFlacWhenFramesContradictMonoStreamInfo() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = createConversionFixture("contradictory.flac", "flac", channels = 2)
        val sourceBytes = source.readBytes()
        assertEquals("fLaC", sourceBytes.decodeToString(0, 4))
        sourceBytes[20] = (sourceBytes[20].toInt() and 0xF1).toByte()
        source.writeBytes(sourceBytes)
        assertEquals(256, nativeFlacOpusBitrateKbps(source.path, 320))

        val request = JSONObject()
            .put("contract_version", 1)
            .put("item_id", "contradictory").put("service", "example-provider")
            .put("track_name", "Contradictory FLAC")
            .put("quality", "LOSSLESS").put("storage_mode", "app")
            .put("auto_convert_downloads", true).put("auto_convert_format", "opus")
        val result = NativeDownloadFinalizer.finalize(
            context, "contradictory", request.toString(), "{}",
            JSONObject().put("success", true).put("file_path", source.path),
            "{\"save_download_history\":false}",
        )
        assertTrue(result.toString(), result.getBoolean("success"))
        assertTrue(result.toString(), result.has("auto_conversion_warning"))
        assertEquals(source.path, result.getString("file_path"))
        assertTrue(sourceBytes.contentEquals(source.readBytes()))
        assertFalse(File(source.parentFile, "contradictory.opus").exists())
    }

    @Test
    fun monoCapPromotionRejectsStereoAndMultipleMonoStreams() {
        val stereo = createConversionFixture("capped-stereo.opus", "libopus", channels = 2)
        val mono = createConversionFixture("capped-mono.opus", "libopus")
        val mixed = File(backendRoot, "capped-mixed.opus")
        val muxed = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
            "-v", "error", "-i", mono.path, "-i", mono.path,
            "-map", "0:a", "-map", "1:a", "-c", "copy", mixed.path,
        ))
        assertTrue(muxed.second, muxed.first)
        val output = File(backendRoot, "capped-committed.opus")
        for (staged in listOf(stereo, mixed)) {
            assertFalse(NativeDownloadFinalizer.promoteStagedOpus(
                staged.path, output.path, requireSingleMonoStream = true,
                decode = { _, _ -> error("Disallowed stream reached decoder") },
            ) { false })
            assertFalse(output.exists())
        }
        assertTrue(NativeDownloadFinalizer.promoteStagedOpus(
            mono.path, output.path, requireSingleMonoStream = true,
        ) { false })
    }

    @Test
    fun opusPromotionRejectsEmptyWrongCodecAndTruncatedOutputWithoutReplacingSource() {
        val original = createConversionFixture("original.opus", "libopus")
        val originalBytes = original.readBytes()
        val wrongCodec = createConversionFixture("wrong.ogg", "libvorbis")
        val invalidOutputs = listOf(
            File(backendRoot, "empty.opus").apply { createNewFile() },
            File(backendRoot, "wrong.opus").apply { wrongCodec.copyTo(this) },
            File(backendRoot, "truncated.opus").apply { writeBytes(originalBytes.copyOf(originalBytes.size - 1)) },
        )

        for (invalid in invalidOutputs) {
            assertFalse(invalid.name, NativeDownloadFinalizer.promoteStagedOpus(invalid.path, original.path) { false })
            assertTrue(invalid.name, originalBytes.contentEquals(original.readBytes()))
        }
    }

    @Test
    fun cancellingOpusValidationPreservesSource() {
        val original = createConversionFixture("existing.opus", "libopus")
        val staged = createConversionFixture("staged.opus", "libopus")
        val originalBytes = original.readBytes()
        var decoderChecks = 0
        var decoding = false
        var cancelled = false
        try {
            NativeDownloadFinalizer.promoteStagedOpus(
                staged.path, original.path,
                decode = { arguments, shouldCancel ->
                    decoding = true
                    val inputIndex = arguments.indexOf("-i")
                    val throttled = arguments.take(inputIndex) + "-re" + arguments.drop(inputIndex)
                    NativeDownloadFinalizer.runFFmpegArguments(throttled.toTypedArray(), shouldCancel)
                },
            ) { decoding && ++decoderChecks >= 2 }
        } catch (error: CancellationException) {
            assertFalse(error is FFmpegProducerUnconfirmed)
            cancelled = true
        }
        assertTrue(cancelled)
        assertEquals(2, decoderChecks)
        assertTrue(originalBytes.contentEquals(original.readBytes()))
    }

    @Test
    fun unconfirmedOpusDecoderLeavesStagingAndDestinationUntouched() {
        val staged = createConversionFixture("pending.partial.opus", "libopus")
        val output = File(backendRoot, "previous.opus").apply { writeText("previous download") }
        val stagedBytes = staged.readBytes()
        val failure = runCatching {
            NativeDownloadFinalizer.promoteStagedOpus(
                staged.path, output.path,
                decode = { _, _ -> throw FFmpegProducerUnconfirmed() },
            ) { false }
        }.exceptionOrNull()
        assertTrue(failure is FFmpegProducerUnconfirmed)
        assertTrue(stagedBytes.contentEquals(staged.readBytes()))
        assertEquals("previous download", output.readText())
    }

    @Test
    fun opusPromotionRejectsInvalidHeadersEvenWithCorrectChecksum() {
        val original = createConversionFixture("source.opus", "libopus")
        val bytes = original.readBytes()
        val tagsPage = nextOggPage(bytes, 0)
        val audioPage = nextOggPage(bytes, tagsPage)
        val invalidGranule = bytes.copyOf().apply { this[6] = 1; rewriteOggChecksum(this, 0) }
        val falseContinuation = bytes.copyOf().apply {
            this[audioPage + 5] = (this[audioPage + 5].toInt() or 1).toByte()
            rewriteOggChecksum(this, audioPage)
        }
        for ((name, invalid) in listOf("granule" to invalidGranule, "continuation" to falseContinuation)) {
            val staged = File(backendRoot, "$name.opus").apply { writeBytes(invalid) }
            assertFalse(name, NativeDownloadFinalizer.promoteStagedOpus(staged.path, original.path) { false })
            assertTrue(name, bytes.contentEquals(original.readBytes()))
        }
    }

    @Test
    fun opusPromotionAcceptsStereoAndChainedStreams() {
        val stereo = createConversionFixture("stereo.opus", "libopus", channels = 2)
        val second = createConversionFixture("second.opus", "libopus", channels = 2)
        val chain = File(backendRoot, "chain.opus").apply { writeBytes(stereo.readBytes() + second.readBytes()) }
        for (staged in listOf(stereo, chain)) {
            val output = File(backendRoot, "published-${staged.name}")
            val expected = staged.readBytes()
            assertTrue(staged.name, NativeDownloadFinalizer.promoteStagedOpus(staged.path, output.path) { false })
            assertTrue(expected.contentEquals(output.readBytes()))
        }
    }

    @Test
    fun opusPromotionAcceptsCommentPacketContinuedAcrossPages() {
        val staged = createConversionFixture("large-comment.opus", "libopus", extra = arrayOf(
            "-metadata", "comment=${"c".repeat(70_000)}",
        ))
        val bytes = staged.readBytes()
        val continuedPage = nextOggPage(bytes, nextOggPage(bytes, 0))
        assertEquals(1, bytes[continuedPage + 5].toInt() and 1)
        val output = File(backendRoot, "published-large-comment.opus")
        assertTrue(NativeDownloadFinalizer.promoteStagedOpus(staged.path, output.path) { false })
        assertTrue(bytes.contentEquals(output.readBytes()))
    }

    private fun nextOggPage(bytes: ByteArray, start: Int): Int {
        val segmentCount = bytes[start + 26].toInt() and 0xff
        val body = start + 27 + segmentCount
        return body + (start + 27 until body).sumOf { bytes[it].toInt() and 0xff }
    }

    private fun rewriteOggChecksum(bytes: ByteArray, start: Int) {
        bytes.fill(0, start + 22, start + 26)
        var checksum = 0
        for (index in start until nextOggPage(bytes, start)) {
            checksum = checksum xor ((bytes[index].toInt() and 0xff) shl 24)
            repeat(8) {
                checksum = if (checksum < 0) (checksum shl 1) xor 0x04c11db7 else checksum shl 1
            }
        }
        repeat(4) { bytes[start + 22 + it] = (checksum ushr (8 * it)).toByte() }
    }

    private fun createConversionFixture(name: String, encoder: String, channels: Int = 1, extra: Array<String> = emptyArray()): File {
        val fixture = File(backendRoot, name)
        val result = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
            "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
            "-t", "1.5", "-ac", channels.toString(), "-c:a", encoder, *extra, fixture.path,
        ))
        assertTrue(result.second, result.first)
        return fixture
    }

    @Test
    fun requestedFlacUsesTheActualStreamDespiteM4aProviderAndDecryptionHints() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "lossless-container-${System.nanoTime()}").apply { mkdirs() }
        try {
            for ((codec, requested, expected) in listOf(
                Triple("flac", ".flac", "flac"),
                Triple("flac", ".m4a", "m4a"),
                Triple("aac", ".flac", "m4a"),
            )) {
                val input = File(root, "track-$codec-$expected.m4a")
                val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
                    "-t", "0.3", "-c:a", codec, "-strict", "-2", "-f", "mp4", input.path,
                ))
                assertTrue(fixture.second, fixture.first)
                assertTrue(isMP4ContainerFile(input.path))
                fun decodedAudio(file: File, name: String): ByteArray {
                    val pcm = File(root, name)
                    val decoded = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                        "-v", "error", "-i", file.path, "-map", "0:a:0",
                        "-c:a", "pcm_s32le", "-f", "s32le", "-y", pcm.path,
                    ))
                    assertTrue(decoded.second, decoded.first)
                    return pcm.readBytes()
                }
                val before = decodedAudio(input, "before.pcm")
                val request = JSONObject()
                    .put("contract_version", 1).put("item_id", "example-track")
                    .put("service", "example-provider").put("track_name", "Lossless container test")
                    .put("artist_name", "Example artist").put("album_name", "Example album")
                    .put("quality", "LOSSLESS").put("storage_mode", "app")
                    .put("output_ext", requested).put("embed_metadata", true)
                val result = NativeDownloadFinalizer.finalize(
                    context, "example-track", request.toString(), "{}",
                    JSONObject().put("success", true).put("file_path", input.path)
                        .put("file_name", input.name).put("audio_codec", "m4a")
                        .put("output_extension", ".m4a")
                        .put("decryption", JSONObject().put("output_extension", ".m4a")),
                    "{\"save_download_history\":false}",
                )
                assertTrue(result.toString(), result.getBoolean("success"))
                assertTrue(result.toString(), result.getBoolean("native_finalized"))
                val output = File(result.getString("file_path"))
                assertEquals(expected, output.extension)
                assertEquals(".$expected", result.getString("actual_extension"))
                assertEquals(".$expected", result.getString("output_extension"))
                assertEquals(expected, result.getString("actual_container"))
                assertFalse(result.getBoolean("requires_container_conversion"))
                assertEquals(expected == "flac", NativeDownloadFinalizer.isNativeFlacFile(output.path))
                assertEquals(codec, NativeDownloadFinalizer.probePrimaryAudioCodec(output.path))
                assertTrue("$codec -> $expected changed decoded audio", before.contentEquals(decodedAudio(output, "after.pcm")))
                val tags = JSONObject(backend.readFileMetadata(output.path, output.name))
                assertEquals("Lossless container test", tags.getString("title"))
            }
        } finally { root.deleteRecursively() }
    }

    @Test
    fun misnamedMp4IsTaggedAndPublishedAsM4aWithoutOverwritingExistingAudio() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "container-test-${System.nanoTime()}").apply { mkdirs() }
        try {
            val input = File(root, "track.flac")
            val existing = File(root, "track.m4a").apply { writeText("existing download") }
            val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=44100",
                "-t", "0.2", "-c:a", "aac", "-f", "mp4", input.path,
            ))
            assertTrue(fixture.second, fixture.first)
            assertTrue(isMP4ContainerFile(input.path))
            val request = JSONObject()
                .put("contract_version", 1).put("item_id", "example-track")
                .put("service", "example-provider").put("track_name", "Container test")
                .put("artist_name", "Example artist").put("album_name", "Example album")
                .put("quality", "LOSSLESS").put("storage_mode", "app")
                .put("output_ext", ".flac").put("embed_metadata", true)
            val result = NativeDownloadFinalizer.finalize(
                context, "example-track", request.toString(), "{}",
                JSONObject().put("success", true).put("file_path", input.path)
                    .put("file_name", input.name),
                "{\"save_download_history\":false}",
            )
            assertTrue(result.toString(), result.getBoolean("success"))
            assertTrue(result.getBoolean("native_finalized"))
            val output = File(result.getString("file_path"))
            assertEquals("m4a", output.extension)
            assertTrue(output.length() > 0)
            assertTrue(isMP4ContainerFile(output.path))
            assertFalse(input.exists())
            assertEquals("existing download", existing.readText())
            val probe = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                "-hide_banner", "-i", output.path, "-map", "0:a:0", "-f", "null", "-",
            ))
            assertTrue(probe.second, probe.first)
            assertTrue(probe.second, probe.second.contains("Container test"))
            assertTrue(probe.second, probe.second.contains("Audio: aac"))
        } finally {
            root.deleteRecursively()
        }
    }
}
