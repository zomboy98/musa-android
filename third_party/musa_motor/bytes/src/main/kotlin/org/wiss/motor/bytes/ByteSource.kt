package org.wiss.motor.bytes

/**
 * Contrato de entrada: lo que entrega un proveedor de audio crudo.
 *
 * Es mas simple que el ProgressiveLease del repo viejo: el origen solo sabe
 * (a) su tamano, (b) leer un rango y (c) en que estado esta. Quien lo bombea
 * hacia el [SegmentStore] es [Transferencia]; el origen no conoce cache ni reproductor.
 */
interface ByteSource : AutoCloseable {
    /** Tamano total en bytes, o -1 si es desconocido (se descubre al llegar a EOF). */
    val tamano: Long

    /**
     * true si [leer] admite cualquier offset (p. ej. HTTP Range). Si es false, el origen
     * solo se puede consumir de forma secuencial desde 0 (una reanudacion vuelve a pedir desde 0).
     */
    val admiteRangos: Boolean

    /** Estado terminal/actual del origen. */
    val estado: EstadoOrigen

    /**
     * Lectura bloqueante de hasta [len] bytes desde [offset] hacia [destino] en [desde].
     * Devuelve n >= 1, o -1 si el origen no tiene mas bytes desde ese offset (fin).
     * Lanza [java.io.IOException] ante fallo y [CancelacionException] tras [cancelar].
     */
    fun leer(offset: Long, destino: ByteArray, desde: Int, len: Int): Int

    /** Aborta cualquier [leer] en curso y futuros. Idempotente. */
    fun cancelar()

    override fun close() {}
}
