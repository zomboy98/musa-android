package org.wiss.motor.bytes

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.concurrent.atomic.AtomicBoolean

class MusaFuenteLocal(ruta: Path, duracionMs: Long? = null) : MusaFuenteAudio {
    private val canal: FileChannel?
    private val cancelada = AtomicBoolean(false)
    private val cerrada = AtomicBoolean(false)

    override val tamano: Long
    override val causa: MusaCausa?
    override val info: MusaInfoMedio

    init {
        var abierto: FileChannel? = null
        var tam = -1L
        var motivo: MusaCausa? = null
        try {
            if (!Files.isRegularFile(ruta)) throw NoSuchFileException("ausente")
            abierto = FileChannel.open(ruta, StandardOpenOption.READ)
            tam = abierto.size()
        } catch (_: NoSuchFileException) {
            motivo = MusaCausa.NO_ENCONTRADO
        } catch (_: IOException) {
            motivo = MusaCausa.ALMACENAMIENTO
        }
        canal = abierto
        tamano = tam
        causa = motivo
        info = infoPorExtension(ruta, duracionMs)
    }

    override val admiteRangos: Boolean get() = true

    override val estado: EstadoOrigen
        get() = when {
            causa != null -> EstadoOrigen.ERROR
            cancelada.get() -> EstadoOrigen.CANCELADO
            else -> EstadoOrigen.COMPLETO
        }

    override fun leer(offset: Long, destino: ByteArray, desde: Int, len: Int): Int {
        require(offset >= 0 && desde >= 0 && len >= 0 && desde + len <= destino.size) { "argumentos" }
        if (cancelada.get()) throw CancelacionException()
        val c = canal ?: throw IOException("origen local no disponible")
        if (len == 0) return 0
        if (offset >= tamano) return -1
        try {
            val n = c.read(ByteBuffer.wrap(destino, desde, len), offset)
            return if (n <= 0) -1 else n
        } catch (_: ClosedChannelException) {
            if (cancelada.get()) throw CancelacionException()
            throw IOException("origen local cerrado")
        }
    }

    override fun cancelar() {
        cancelada.set(true)
        cerrarCanal()
    }

    override fun reabrir(desdeByte: Long, causaPrevia: MusaCausa): MusaFuenteAudio? = null

    override fun close() {
        cerrarCanal()
    }

    private fun cerrarCanal() {
        if (cerrada.compareAndSet(false, true)) {
            try {
                canal?.close()
            } catch (_: IOException) {
            }
        }
    }

    override fun toString(): String = "MusaFuenteLocal(estado=$estado)"

    companion object {
        fun infoPorExtension(ruta: Path, duracionMs: Long? = null): MusaInfoMedio {
            val nombre = ruta.fileName?.toString()?.lowercase() ?: ""
            val ext = nombre.substringAfterLast('.', "")
            val (contenedor, codec) = when (ext) {
                "flac" -> MusaContenedor.FLAC to MusaCodec.FLAC
                "mp3" -> MusaContenedor.MP3 to MusaCodec.MP3
                "aac" -> MusaContenedor.ADTS to MusaCodec.AAC
                "ogg" -> MusaContenedor.OGG to MusaCodec.VORBIS
                "opus" -> MusaContenedor.OGG to MusaCodec.OPUS
                "wav" -> MusaContenedor.WAV to MusaCodec.PCM
                "m4a", "mp4" -> MusaContenedor.MP4 to MusaCodec.DESCONOCIDO
                "webm" -> MusaContenedor.WEBM to MusaCodec.DESCONOCIDO
                else -> MusaContenedor.DESCONOCIDO to MusaCodec.DESCONOCIDO
            }
            return MusaInfoMedio(contenedor, codec, null, duracionMs, true)
        }
    }
}
