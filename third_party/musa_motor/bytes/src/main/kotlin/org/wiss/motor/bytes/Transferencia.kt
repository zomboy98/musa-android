package org.wiss.motor.bytes

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Bombea un [ByteSource] hacia un [ItemCache]. Es el UNICO camino de datos: sirve igual para
 * streaming (item EFIMERO con lectores) que para descarga (item PERSISTENTE, sin lectores).
 * Solo pide al origen los HUECOS: tras una promocion o una reanudacion no repite lo recibido.
 * Atiende los seeks: [priorizar] hace saltar el cursor a ese offset (si el origen admite rangos).
 */
class Transferencia internal constructor(
    private val item: ItemCache,
    private val origen: ByteSource,
    private val chunk: Int,
    private val inicio: Long = 0,
    private val ventana: Long = 0,
    private val soloAdelante: Boolean = false,
) {
    private val cancelado = AtomicBoolean(false)
    private val salto = AtomicLong(-1)
    private val hecha = CountDownLatch(1)

    @Volatile
    var estadoFinal: EstadoOrigen = EstadoOrigen.EN_CURSO
        private set

    val activa: Boolean get() = hecha.count > 0

    init {
        require(chunk > 0) { "chunk" }
    }

    /** Pide que el siguiente trozo sea el primer hueco desde [offset] (seek). Barato y no bloqueante. */
    fun priorizar(offset: Long) {
        if (origen.admiteRangos) {
            salto.set(offset)
            item.despertar()
        }
    }

    fun cancelar() {
        cancelado.set(true)
        origen.cancelar()
        item.despertar()
    }

    /** Espera (por latch) a que termine. true si termino antes del timeout. */
    fun esperar(timeoutMs: Long): Boolean = hecha.await(timeoutMs, TimeUnit.MILLISECONDS)

    internal fun arrancar() {
        item.priorizador = { priorizar(it) }
        Thread({ ejecutar() }, "transferencia-bytes").also { it.isDaemon = true }.start()
    }

    private fun ejecutar() {
        var estado = EstadoOrigen.ERROR
        var causa: String? = null
        try {
            val t = origen.tamano
            if (t >= 0) item.fijarTamano(t)
            val buf = ByteArray(chunk)
            var cursor = if (origen.admiteRangos) maxOf(0L, huecoDesde(inicio)) else 0L
            var fin = false
            while (!fin) {
                if (cancelado.get() || item.descartado) throw CancelacionException()
                val total = item.tamano
                val pos: Long
                val len: Int
                if (origen.admiteRangos) {
                    val s = salto.getAndSet(-1)
                    val desde = if (s >= 0 && (total < 0 || s < total)) s else cursor
                    pos = huecoDesde(desde)
                    if (pos < 0) {
                        fin = true
                        continue
                    }
                    cursor = pos
                    if (esperarVentana(pos)) continue
                    len = minOf(chunk.toLong(), item.limiteDesde(pos) - pos).toInt()
                } else {
                    // Secuencial puro: una reanudacion vuelve a leer desde 0 (limitacion del origen).
                    if (total >= 0 && cursor >= total) {
                        fin = true
                        continue
                    }
                    pos = cursor
                    if (esperarVentana(pos)) continue
                    len = if (total >= 0) minOf(chunk.toLong(), total - pos).toInt() else chunk
                }
                val n = origen.leer(pos, buf, 0, len)
                if (n < 0) {
                    when (origen.estado) {
                        EstadoOrigen.ERROR -> throw IOException("origen en error")
                        EstadoOrigen.CANCELADO -> throw CancelacionException()
                        else -> Unit
                    }
                    if (item.tamano < 0) {
                        item.fijarTamano(pos)
                        cursor = pos
                    } else {
                        throw IOException("fin prematuro del origen")
                    }
                } else if (n > 0) {
                    item.escribir(pos, buf, 0, n)
                    cursor = pos + n
                }
            }
            estado = EstadoOrigen.COMPLETO
        } catch (_: CancelacionException) {
            estado = EstadoOrigen.CANCELADO
        } catch (e: Exception) {
            // Solo el tipo: el mensaje podria contener URLs o rutas.
            causa = e.javaClass.simpleName
            estado = if (cancelado.get()) EstadoOrigen.CANCELADO else EstadoOrigen.ERROR
        } finally {
            try {
                origen.close()
            } catch (_: Exception) {
            }
        }
        item.terminar(estado, causa)
        estadoFinal = item.estado
        item.transferenciaTerminada(this)
        hecha.countDown()
    }

    private fun huecoDesde(referencia: Long): Long =
        if (soloAdelante) item.primerHuecoAdelante(referencia) else item.primerHuecoDesde(referencia)

    private fun esperarVentana(pos: Long): Boolean {
        if (ventana <= 0) return false
        item.esperarVentana(pos, ventana) { cancelado.get() || salto.get() >= 0 }
        if (cancelado.get()) throw CancelacionException()
        return salto.get() >= 0
    }

    override fun toString(): String = "Transferencia(activa=$activa, estado=$estadoFinal)"
}
