package org.wiss.motor.bytes

import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vista de lectura para el reproductor (equivalente a un DataSource). Lectura posicional
 * (offset explicito) por lo que el seek es gratis: se puede leer en cualquier offset aunque el
 * hueco aun no haya llegado; en ese caso se pide ese rango de forma prioritaria al origen (si
 * admite rangos) o se espera. Semantica de [leer]:
 *  - Bytes(n): n >= 1 bytes (parcial) o 0 si len == 0.
 *  - Faltan: timeout, los bytes aun no llegan (NO es EOF).
 *  - Eof / Error(tipo) / Cancelado.
 */
class PlaybackReader internal constructor(
    private val item: ItemCache,
    private val timeoutPorDefectoMs: Long,
) : AutoCloseable {
    private val cancelado = AtomicBoolean(false)
    private val cerrado = AtomicBoolean(false)

    init {
        item.adquirir()
    }

    /** Tamano total o -1 si desconocido. */
    val tamano: Long get() = item.tamano

    fun leer(
        offset: Long,
        destino: ByteArray,
        desde: Int = 0,
        len: Int = destino.size - desde,
        timeoutMs: Long = timeoutPorDefectoMs,
    ): ResultadoLectura = item.leer(
        offset, destino, desde, len,
        TimeUnit.MILLISECONDS.toNanos(timeoutMs),
    ) { cancelado.get() }

    /** Cancela este lector: despierta y aborta lecturas pendientes con Cancelado. */
    fun cancelar() {
        cancelado.set(true)
        item.despertar()
    }

    override fun close() {
        cancelar()
        if (cerrado.compareAndSet(false, true)) item.close()
    }

    override fun toString(): String = "PlaybackReader(cancelado=${cancelado.get()})"
}
