package org.wiss.motor.bytes

object MusaMapeoErrores {
    const val CODIGO_DESCONOCIDO = 1000
    const val CODIGO_ERROR_REMOTO = 1001
    const val CODIGO_VENTANA_EN_VIVO = 1002
    const val CODIGO_TIEMPO_AGOTADO = 1003
    const val CODIGO_COMPROBACION_EJECUCION = 1004

    const val CODIGO_ES_DESCONOCIDO = 2000
    const val CODIGO_ES_RED_CONEXION = 2001
    const val CODIGO_ES_RED_TIEMPO = 2002
    const val CODIGO_ES_TIPO_CONTENIDO_HTTP = 2003
    const val CODIGO_ES_ESTADO_HTTP = 2004
    const val CODIGO_ES_ARCHIVO_AUSENTE = 2005
    const val CODIGO_ES_SIN_PERMISO = 2006
    const val CODIGO_ES_TEXTO_CLARO_NO_PERMITIDO = 2007
    const val CODIGO_ES_POSICION_FUERA_DE_RANGO = 2008

    const val CODIGO_CONTENEDOR_MALFORMADO = 3001
    const val CODIGO_MANIFIESTO_MALFORMADO = 3002
    const val CODIGO_CONTENEDOR_NO_SOPORTADO = 3003
    const val CODIGO_MANIFIESTO_NO_SOPORTADO = 3004

    const val CODIGO_DECODIFICADOR_INICIO = 4001
    const val CODIGO_DECODIFICADOR_CONSULTA = 4002
    const val CODIGO_DECODIFICACION_FALLIDA = 4003
    const val CODIGO_FORMATO_EXCEDE_CAPACIDAD = 4004
    const val CODIGO_FORMATO_NO_SOPORTADO = 4005
    const val CODIGO_RECURSOS_RECLAMADOS = 4006

    const val CODIGO_PISTA_AUDIO_INICIO = 5001
    const val CODIGO_PISTA_AUDIO_ESCRITURA = 5002
    const val CODIGO_PISTA_AUDIO_DESCARGA_ESCRITURA = 5003
    const val CODIGO_PISTA_AUDIO_DESCARGA_INICIO = 5004

    const val CODIGO_DRM_DESCONOCIDO = 6000
    const val CODIGO_DRM_ESQUEMA_NO_SOPORTADO = 6001

    private val tiposRed = setOf(
        "UnknownHostException", "ConnectException", "NoRouteToHostException", "SocketException",
        "SSLException", "SSLHandshakeException", "HttpDataSourceException", "InvalidResponseCodeException",
        "EOFException",
    )
    private val tiposTiempo = setOf("SocketTimeoutException", "TimeoutException", "InterruptedIOException")
    private val tiposAusente = setOf("FileNotFoundException", "NoSuchFileException", "FileDataSourceException")
    private val tiposContenedorNoReconocido = setOf("UnrecognizedInputFormatException")
    private val tiposCorrupto = setOf("ParserException")
    private val tiposSalida = setOf("InitializationException", "WriteException", "AudioTrackInitializationException")
    private val tiposDecodificador = setOf(
        "DecoderInitializationException", "MediaCodecDecoderException", "DecoderException",
    )

    fun causaDe(codigo: Int, tipoExcepcion: String? = null, tiposCausa: List<String> = emptyList()): MusaCausa {
        val porCodigo = porCodigo(codigo)
        if (porCodigo != null) return porCodigo
        val nombres = (listOfNotNull(tipoExcepcion) + tiposCausa).map(::nombreSimple)
        for (n in nombres) porTipo(n)?.let { return it }
        return MusaCausa.DESCONOCIDA
    }

    private fun porCodigo(codigo: Int): MusaCausa? = when (codigo) {
        CODIGO_ES_RED_CONEXION, CODIGO_ES_ESTADO_HTTP, CODIGO_ES_TEXTO_CLARO_NO_PERMITIDO -> MusaCausa.RED_TRANSITORIA
        CODIGO_ES_RED_TIEMPO, CODIGO_TIEMPO_AGOTADO -> MusaCausa.TIEMPO_AGOTADO
        CODIGO_ES_ARCHIVO_AUSENTE, CODIGO_ES_SIN_PERMISO -> MusaCausa.NO_ENCONTRADO
        CODIGO_ES_TIPO_CONTENIDO_HTTP, CODIGO_CONTENEDOR_NO_SOPORTADO, CODIGO_MANIFIESTO_NO_SOPORTADO ->
            MusaCausa.CONTENEDOR_NO_RECONOCIDO
        CODIGO_ES_POSICION_FUERA_DE_RANGO, CODIGO_CONTENEDOR_MALFORMADO, CODIGO_MANIFIESTO_MALFORMADO,
        CODIGO_DECODIFICACION_FALLIDA -> MusaCausa.ARCHIVO_CORRUPTO
        CODIGO_DECODIFICADOR_INICIO, CODIGO_DECODIFICADOR_CONSULTA, CODIGO_RECURSOS_RECLAMADOS ->
            MusaCausa.DECODIFICADOR
        CODIGO_FORMATO_EXCEDE_CAPACIDAD, CODIGO_FORMATO_NO_SOPORTADO -> MusaCausa.FORMATO_NO_SOPORTADO
        CODIGO_PISTA_AUDIO_INICIO, CODIGO_PISTA_AUDIO_ESCRITURA, CODIGO_PISTA_AUDIO_DESCARGA_ESCRITURA,
        CODIGO_PISTA_AUDIO_DESCARGA_INICIO -> MusaCausa.SALIDA_AUDIO
        CODIGO_DRM_ESQUEMA_NO_SOPORTADO -> MusaCausa.DESCIFRADO_NO_SOPORTADO
        in (CODIGO_DRM_DESCONOCIDO + 2)..6999 -> MusaCausa.CLAVE_INVALIDA
        else -> null
    }

    private fun porTipo(nombre: String): MusaCausa? = when {
        nombre in tiposTiempo -> MusaCausa.TIEMPO_AGOTADO
        nombre in tiposRed -> MusaCausa.RED_TRANSITORIA
        nombre in tiposAusente -> MusaCausa.NO_ENCONTRADO
        nombre in tiposContenedorNoReconocido -> MusaCausa.CONTENEDOR_NO_RECONOCIDO
        nombre in tiposCorrupto -> MusaCausa.ARCHIVO_CORRUPTO
        nombre in tiposSalida -> MusaCausa.SALIDA_AUDIO
        nombre in tiposDecodificador -> MusaCausa.DECODIFICADOR
        else -> null
    }

    private fun nombreSimple(tipo: String): String = tipo.substringAfterLast('.').substringAfterLast('$')
}
