package org.wiss.motor.bytes

enum class MusaOrigenCausa { SESION, MOTOR }

enum class MusaCausa(val origen: MusaOrigenCausa, val reintentable: Boolean) {
    RED_TRANSITORIA(MusaOrigenCausa.SESION, true),
    ENLACE_EXPIRADO(MusaOrigenCausa.SESION, true),
    LIMITE_TASA(MusaOrigenCausa.SESION, true),
    BLOQUEO_RED(MusaOrigenCausa.SESION, false),
    VERIFICACION_REQUERIDA(MusaOrigenCausa.SESION, false),
    SESION_INVALIDA(MusaOrigenCausa.SESION, false),
    PROVEEDOR_NO_DISPONIBLE(MusaOrigenCausa.SESION, true),
    NO_ENCONTRADO(MusaOrigenCausa.SESION, false),
    CALIDAD_NO_DISPONIBLE(MusaOrigenCausa.SESION, false),
    INTEGRIDAD(MusaOrigenCausa.SESION, false),
    ALMACENAMIENTO(MusaOrigenCausa.SESION, false),
    CANCELADO(MusaOrigenCausa.SESION, false),
    FORMATO_NO_SOPORTADO(MusaOrigenCausa.MOTOR, false),
    CONTENEDOR_NO_RECONOCIDO(MusaOrigenCausa.MOTOR, false),
    ARCHIVO_CORRUPTO(MusaOrigenCausa.MOTOR, false),
    CLAVE_INVALIDA(MusaOrigenCausa.MOTOR, false),
    DESCIFRADO_NO_SOPORTADO(MusaOrigenCausa.MOTOR, false),
    DATOS_INSUFICIENTES(MusaOrigenCausa.MOTOR, false),
    SALIDA_AUDIO(MusaOrigenCausa.MOTOR, false),
    DECODIFICADOR(MusaOrigenCausa.MOTOR, false),
    TIEMPO_AGOTADO(MusaOrigenCausa.MOTOR, true),
    CANCELACION_NO_CONFIRMADA(MusaOrigenCausa.MOTOR, false),
    DESCONOCIDA(MusaOrigenCausa.MOTOR, false),
}

enum class MusaContenedor { FLAC, MP3, ADTS, OGG, WAV, MP4, FMP4, WEBM, DESCONOCIDO }

enum class MusaCodec { AAC, FLAC, MP3, OPUS, VORBIS, ALAC, EAC3, EAC3_JOC, AC4, PCM, DESCONOCIDO }

enum class MusaEsquema { CENC_AES128_CTR, BLOWFISH_CBC_CADA_3 }

class MusaSecreto(bytes: ByteArray) : AutoCloseable {
    private val contenido: ByteArray = bytes.copyOf()

    @Volatile
    private var cerrado = false

    val tamano: Int get() = contenido.size

    fun <R> usar(bloque: (ByteArray) -> R): R {
        check(!cerrado) { "secreto cerrado" }
        return bloque(contenido)
    }

    override fun close() {
        cerrado = true
        contenido.fill(0)
    }

    override fun toString(): String = "MusaSecreto(***)"
}

data class MusaDescifrado(
    val esquema: MusaEsquema,
    val clave: MusaSecreto,
    val formatoEntrada: String? = null,
)

data class MusaInfoMedio(
    val contenedor: MusaContenedor,
    val codec: MusaCodec,
    val descifrado: MusaDescifrado? = null,
    val duracionMs: Long? = null,
    val local: Boolean = false,
)

interface MusaFuenteAudio : ByteSource {
    val info: MusaInfoMedio

    val generacionFuente: Long get() = 0L

    val causa: MusaCausa?

    fun reabrir(desdeByte: Long, causaPrevia: MusaCausa): MusaFuenteAudio?
}
