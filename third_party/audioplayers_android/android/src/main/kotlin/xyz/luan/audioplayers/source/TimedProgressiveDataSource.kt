package xyz.luan.audioplayers.source

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import java.io.IOException

/** One per Media3 load. The owning attempt, not close(), owns the shared lease. */
class TimedProgressiveDataSource(private val lease: TimedProgressiveLease) : BaseDataSource(false) {
    private var cursor: TimedProgressiveCursor? = null
    private var uri: Uri? = null

    @Throws(IOException::class)
    override fun open(dataSpec: DataSpec): Long {
        check(cursor == null) { "DataSource already open" }
        if (dataSpec.uri.scheme != "musa-progressive" || dataSpec.uri.host != "lease")
            throw IOException("Invalid progressive capability")
        transferInitializing(dataSpec)
        val size = lease.knownSize()
        if (size != null && (size < 0 || dataSpec.position > size))
            throw DataSourceException(androidx.media3.common.PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        val knownRemaining = size?.minus(dataSpec.position)
        val requested = dataSpec.length.takeUnless { it == C.LENGTH_UNSET.toLong() }
        val effective = when { knownRemaining == null -> requested; requested == null -> knownRemaining; else -> minOf(knownRemaining, requested) }
        cursor = TimedProgressiveCursor(lease, dataSpec.position, effective)
        uri = dataSpec.uri
        transferStarted(dataSpec)
        return effective ?: C.LENGTH_UNSET.toLong()
    }

    @Throws(IOException::class)
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val read = (cursor ?: throw IOException("Progressive source is closed")).read(buffer, offset, length)
        if (read > 0) bytesTransferred(read)
        return read
    }

    override fun getUri(): Uri? = uri
    override fun close() {
        val old = cursor ?: return
        cursor = null
        uri = null
        old.close()
        transferEnded()
    }

    class Factory(private val lease: TimedProgressiveLease) : DataSource.Factory {
        override fun createDataSource(): DataSource = TimedProgressiveDataSource(lease)
    }
}

