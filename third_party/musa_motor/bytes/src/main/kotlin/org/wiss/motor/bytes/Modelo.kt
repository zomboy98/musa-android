package org.wiss.motor.bytes

import java.io.IOException

/** Estado de una transferencia / de un origen de bytes. */
enum class EstadoOrigen {
    EN_CURSO, COMPLETO, ERROR, CANCELADO;

    val terminal: Boolean get() = this != EN_CURSO
}

/** Politica de retencion de un item en el SegmentStore. */
enum class Retencion {
    /** Streaming: cache temporal descartable (purga LRU), nunca se publica. */
    EFIMERO,

    /** Descarga: vive en su ruta final (como .part hasta completarse). */
    PERSISTENTE,
}

/** Resultado de una lectura de reproductor. Nunca contiene rutas ni claves. */
sealed interface ResultadoLectura {
    /** Se copiaron [n] bytes (puede ser menos que lo pedido: semantica de lectura parcial). */
    data class Bytes(val n: Int) : ResultadoLectura

    /** Timeout: esos bytes todavia no han llegado (NO es fin de archivo). */
    data object Faltan : ResultadoLectura

    /** Fin de archivo legitimo. */
    data object Eof : ResultadoLectura

    /** El origen fallo; [tipo] es solo el nombre de la clase de la causa (sin mensaje). */
    data class Error(val tipo: String) : ResultadoLectura

    /** La transferencia, el lector o el item fueron cancelados/descartados. */
    data object Cancelado : ResultadoLectura
}

/** Lanzada por un [ByteSource] cuando se llama a cancelar() mientras leia. */
class CancelacionException : IOException("cancelado")
