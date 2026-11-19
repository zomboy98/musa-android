package xyz.luan.audioplayers.source

import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import java.io.File
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.UUID
import org.wiss.motor.bytes.ByteSource
import org.wiss.motor.bytes.CancelacionException
import org.wiss.motor.bytes.EstadoOrigen
import org.wiss.motor.bytes.ItemCache
import org.wiss.motor.bytes.Retencion
import org.wiss.motor.bytes.SegmentStore
import org.wiss.motor.bytes.Transferencia
import org.wiss.motor.prueba.WissDataSource

/**
 * Lease de prefijo (sin Range) como origen de bytes del motor. Lectura secuencial desde 0:
 * un hueco se espera, no se pide. El estado terminal lo decide el propietario del lease.
 */
internal class TimedLeaseByteSource(
    private val lease: TimedProgressiveLease,
    private val estancamientoMs: Long = 30_000,
) : ByteSource {
    @Volatile private var cancelado = false
    @Volatile private var fijo = EstadoOrigen.EN_CURSO
    override val admiteRangos: Boolean = false
    override val tamano: Long get() = lease.knownSize() ?: -1L
    override val estado: EstadoOrigen get() = fijo

    override fun leer(offset: Long, destino: ByteArray, desde: Int, len: Int): Int {
        if (len == 0) return 0
        val pedir = minOf(len, 65536)
        val inicio = System.nanoTime()
        while (true) {
            if (cancelado) throw CancelacionException()
            when (val r = try { lease.readChunk(offset, pedir, 250) } catch (e: IOException) {
                fijo = if (cancelado) EstadoOrigen.CANCELADO else EstadoOrigen.ERROR
                if (cancelado) throw CancelacionException() else throw e
            }) {
                is TimedProgressiveRead.Bytes -> {
                    if (r.value.isEmpty() || r.value.size > pedir) throw IOException("LongitudInvalida")
                    r.value.copyInto(destino, desde)
                    return r.value.size
                }
                TimedProgressiveRead.Pending -> if ((System.nanoTime() - inicio) / 1_000_000 >= estancamientoMs) {
                    fijo = EstadoOrigen.ERROR
                    throw SocketTimeoutException("Estancado")
                }
                TimedProgressiveRead.End -> { fijo = EstadoOrigen.COMPLETO; return -1 }
            }
        }
    }

    override fun cancelar() { cancelado = true }
}

/**
 * Motor de reproduccion de un lease: lease -> ItemCache (EFIMERO, sin archivo final) -> WissDataSource.
 * Una instancia por fuente; [close] cancela la transferencia y borra el cache efimero.
 */
@UnstableApi
internal class WissStreamEngine(baseDir: File, lease: TimedProgressiveLease) : AutoCloseable {
    private val dir = File(baseDir, "wiss-stream-" + UUID.randomUUID()).apply { mkdirs() }
    private val store = SegmentStore(dir.toPath(), 64L * 1024 * 1024)
    private val item: ItemCache = store.abrir("fuente", Retencion.EFIMERO, null, lease.knownSize() ?: -1L)
    private val transfer: Transferencia = checkNotNull(item.asegurarTransferencia(64 * 1024) { TimedLeaseByteSource(lease) }) { "sin transferencia" }
    @Volatile private var closed = false

    val factory: DataSource.Factory = DataSource.Factory { WissDataSource({ _: Uri -> item.lector(1_000) }) }

    override fun close() {
        if (closed) return
        closed = true
        try { transfer.cancelar(); transfer.esperar(3_000) } catch (_: Throwable) {}
        try { item.close() } catch (_: Throwable) {}
        try { store.close() } catch (_: Throwable) {}
        dir.deleteRecursively()
    }
}
