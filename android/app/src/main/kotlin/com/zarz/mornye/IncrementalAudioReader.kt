package com.zarz.mornye

import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.nio.ByteBuffer

/** Experimental reader for one owned, immutable download generation. Not wired to playback. */
internal class IncrementalAudioReader(file: File, private val generation: Long) : Closeable {
    private val monitor = java.lang.Object()
    // This is a fresh read-only open; positional reads never move a writer's cursor.
    private val input = FileInputStream(file)
    private val channel = input.channel
    private var published = 0L
    private var state = State.OPEN

    private enum class State { OPEN, COMMITTED, INVALID, CLOSED }

    @Throws(IOException::class)
    fun available(eventGeneration: Long, bytes: Long) = synchronized(monitor) {
        requireOpenGeneration(eventGeneration)
        checkPrefix(bytes)
        published = bytes
        monitor.notifyAll()
    }

    @Throws(IOException::class)
    fun commit(eventGeneration: Long, bytes: Long) = synchronized(monitor) {
        requireOpenGeneration(eventGeneration)
        checkPrefix(bytes)
        published = bytes
        state = State.COMMITTED
        monitor.notifyAll()
    }

    /** Synchronously revokes this generation before its owner may truncate it. */
    @Throws(IOException::class)
    fun invalidate(eventGeneration: Long) = synchronized(monitor) {
        requireOpenGeneration(eventGeneration)
        state = State.INVALID
        monitor.notifyAll()
    }

    @Throws(IOException::class)
    fun abort(eventGeneration: Long) = synchronized(monitor) {
        if (eventGeneration != generation) throw IOException("Wrong generation")
        if (state != State.CLOSED) state = State.INVALID
        monitor.notifyAll()
    }

    @Throws(IOException::class)
    fun size(): Long = synchronized(monitor) {
        checkReadable()
        if (state == State.COMMITTED) published else -1L
    }

    @Throws(IOException::class)
    fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position < 0 || offset < 0 || size < 0 || offset > buffer.size || size > buffer.size - offset) {
            throw IOException("Invalid read range")
        }
        return synchronized(monitor) {
            checkReadable()
            if (size == 0) return@synchronized 0
            while (position >= published && state == State.OPEN) {
                try { monitor.wait() } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw IOException("Read interrupted", error)
                }
                checkReadable()
            }
            checkReadable()
            if (position >= published) return@synchronized -1
            val count = minOf(size.toLong(), published - position).toInt()
            val result = channel.read(ByteBuffer.wrap(buffer, offset, count), position)
            if (result <= 0) throw IOException("Published prefix is no longer readable")
            result
        }
    }

    override fun close() = synchronized(monitor) {
        if (state != State.CLOSED) {
            state = State.CLOSED
            try { input.close() } finally { monitor.notifyAll() }
        }
    }

    private fun requireOpenGeneration(eventGeneration: Long) {
        if (eventGeneration != generation || state != State.OPEN) throw IOException("Inactive generation")
    }

    private fun checkReadable() {
        if (state == State.INVALID || state == State.CLOSED) throw IOException("Reader revoked")
    }

    private fun checkPrefix(bytes: Long) {
        if (bytes < published || bytes > channel.size()) throw IOException("Invalid published prefix")
    }
}
