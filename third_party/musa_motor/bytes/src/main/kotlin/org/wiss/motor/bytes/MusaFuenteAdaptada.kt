package org.wiss.motor.bytes

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class MusaFuenteAdaptada(
    private val origen: ByteSource,
    override val info: MusaInfoMedio,
    private val causaDe: (ByteSource) -> MusaCausa? = { null },
    private val generacionDe: () -> Long = { 0L },
    private val reabrirCon: ((Long, MusaCausa) -> MusaFuenteAudio?)? = null,
) : MusaFuenteAudio {
    @Volatile
    private var causaFijada: MusaCausa? = null
    private val cerrada = AtomicBoolean(false)

    override val generacionFuente: Long get() = generacionDe()

    override val tamano: Long get() = origen.tamano

    override val admiteRangos: Boolean get() = origen.admiteRangos

    override val estado: EstadoOrigen
        get() {
            if (causaFijada == null && origen.estado == EstadoOrigen.ERROR) fijarCausa()
            return if (causaFijada != null) EstadoOrigen.ERROR else origen.estado
        }

    override val causa: MusaCausa?
        get() {
            if (causaFijada == null && origen.estado == EstadoOrigen.ERROR) fijarCausa()
            return causaFijada
        }

    override fun leer(offset: Long, destino: ByteArray, desde: Int, len: Int): Int {
        try {
            return origen.leer(offset, destino, desde, len)
        } catch (c: CancelacionException) {
            throw c
        } catch (e: IOException) {
            fijarCausa()
            throw e
        }
    }

    override fun cancelar() {
        origen.cancelar()
    }

    override fun reabrir(desdeByte: Long, causaPrevia: MusaCausa): MusaFuenteAudio? {
        if (!causaPrevia.reintentable) return null
        return reabrirCon?.invoke(desdeByte, causaPrevia)
    }

    override fun close() {
        if (cerrada.compareAndSet(false, true)) origen.close()
    }

    private fun fijarCausa() {
        if (causaFijada == null) causaFijada = causaDe(origen) ?: MusaCausa.DESCONOCIDA
    }

    override fun toString(): String = "MusaFuenteAdaptada(estado=$estado)"
}
