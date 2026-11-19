package org.wiss.motor.prueba

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import java.io.IOException
import java.io.InterruptedIOException
import org.wiss.motor.bytes.PlaybackReader
import org.wiss.motor.bytes.ResultadoLectura

/** Los bytes pedidos no llegaron a tiempo (NO es fin de archivo). Reintentable por el LoadErrorHandlingPolicy. */
class WissFaltanException(esperadoMs: Long) : IOException("faltan bytes tras ${esperadoMs}ms")

/**
 * DataSource de Media3 sobre un [PlaybackReader] del motor limpio.
 *
 * - open(): crea un lector nuevo (un lector por apertura) y fija la posicion con DataSpec.position
 *   (el seek de ExoPlayer es solo reabrir con otra posicion; el nucleo pide ese hueco con prioridad).
 * - read(): Bytes(n) -> n parcial; Faltan -> sigue esperando en rebanadas de [sondeoMs] hasta
 *   [esperaMaximaMs] y despues lanza [WissFaltanException] (IOException reintentable);
 *   Eof -> END_OF_INPUT; Error/Cancelado -> IOException.
 */
@UnstableApi
class WissDataSource(
    private val abrirLector: (Uri) -> PlaybackReader,
    private val sondeoMs: Long = 500,
    private val esperaMaximaMs: Long = 20_000,
) : BaseDataSource(/* isNetwork = */ false) {
    private var lector: PlaybackReader? = null
    private var uriActual: Uri? = null
    private var pos = 0L
    private var restante = C.LENGTH_UNSET.toLong()
    private var abierto = false

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val r = abrirLector(dataSpec.uri)
        lector = r
        uriActual = dataSpec.uri
        val tam = r.tamano
        pos = dataSpec.position
        if (tam >= 0 && pos > tam) {
            cerrarLector()
            throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        }
        val hastaElFin = if (tam >= 0) tam - pos else C.LENGTH_UNSET.toLong()
        restante = when {
            dataSpec.length == C.LENGTH_UNSET.toLong() -> hastaElFin
            hastaElFin >= 0 -> minOf(dataSpec.length, hastaElFin)
            else -> dataSpec.length
        }
        abierto = true
        transferStarted(dataSpec)
        return restante
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (restante == 0L) return C.RESULT_END_OF_INPUT
        val r = lector ?: throw IOException("DataSource no abierto")
        val quiero = if (restante == C.LENGTH_UNSET.toLong()) length else minOf(length.toLong(), restante).toInt()
        var esperado = 0L
        while (true) {
            if (Thread.currentThread().isInterrupted) throw InterruptedIOException("interrumpido")
            when (val res = r.leer(pos, buffer, offset, quiero, sondeoMs)) {
                is ResultadoLectura.Bytes -> {
                    if (res.n == 0) return 0
                    pos += res.n
                    if (restante != C.LENGTH_UNSET.toLong()) restante -= res.n
                    bytesTransferred(res.n)
                    return res.n
                }
                ResultadoLectura.Faltan -> {
                    esperado += sondeoMs
                    if (esperado >= esperaMaximaMs) throw WissFaltanException(esperado)
                }
                ResultadoLectura.Eof -> return C.RESULT_END_OF_INPUT
                is ResultadoLectura.Error -> throw IOException("WissError:${res.tipo}")
                ResultadoLectura.Cancelado -> {
                    if (Thread.currentThread().isInterrupted) throw InterruptedIOException("interrumpido")
                    throw IOException("WissCancelado")
                }
            }
        }
    }

    override fun getUri(): Uri? = uriActual

    override fun close() {
        try {
            cerrarLector()
        } finally {
            if (abierto) {
                abierto = false
                transferEnded()
            }
        }
    }

    private fun cerrarLector() {
        lector?.close()
        lector = null
    }
}
