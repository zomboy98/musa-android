package org.wiss.motor.bytes

import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

private fun adaptada(
    o: ByteSource,
    causa: () -> MusaCausa? = { MusaCausa.RED_TRANSITORIA },
    generacion: () -> Long = { 0L },
    reabrir: ((Long, MusaCausa) -> MusaFuenteAudio?)? = null,
) = MusaFuenteAdaptada(o, infoFlac, { causa() }, generacion, reabrir)

private class OrigenObservado(private val o: OrigenSimulado, private val alPrimeraLectura: () -> Unit) : ByteSource {
    private val avisado = AtomicBoolean(false)
    override val tamano: Long get() = o.tamano
    override val admiteRangos: Boolean get() = o.admiteRangos
    override val estado: EstadoOrigen get() = o.estado

    override fun leer(offset: Long, destino: ByteArray, desde: Int, len: Int): Int {
        if (avisado.compareAndSet(false, true)) alPrimeraLectura()
        return o.leer(offset, destino, desde, len)
    }

    override fun cancelar() = o.cancelar()
    override fun close() = o.close()
}

private class SalidaErrorAsincrono(private val codigo: Int) : MusaSalida {
    private val acumulado = java.io.ByteArrayOutputStream()
    private var oyente: MusaOyenteErrorSalida? = null
    val liberaciones = AtomicInteger(0)

    override fun establecerOyenteError(oyente: MusaOyenteErrorSalida) {
        this.oyente = oyente
    }

    override fun abrir(info: MusaInfoMedio) {}

    override fun escribir(buffer: ByteArray, desde: Int, len: Int) {
        acumulado.write(buffer, desde, len)
        if (acumulado.size() == len) oyente!!.alError(MusaMapeoErrores.causaDe(codigo))
    }

    override fun drenar() {}
    override fun pausar() {}
    override fun reanudar() {}
    override fun posicionMs(): Long = 0
    override fun abortar() {}
    override fun liberar() {
        liberaciones.incrementAndGet()
    }
}

private fun esperarEstable(ms: Long = 150, lectura: () -> Long): Long {
    var anterior = -1L
    var desde = System.nanoTime()
    while (true) {
        val actual = lectura()
        if (actual != anterior) {
            anterior = actual
            desde = System.nanoTime()
        } else if ((System.nanoTime() - desde) / 1_000_000 >= ms) {
            return actual
        }
        Thread.sleep(5)
    }
}

private fun configVentana(ventana: Long, reintentos: Int = 2) = MusaConfigMotor(
    chunk = 4096, timeoutLecturaMs = 50, cancelacionMs = 3_000,
    reintentosMax = reintentos, ventanaAdelanteBytes = ventana,
)

fun pruebasMusaReintentos() {
    pruebasReintentos()
    pruebasGeneracion()
    pruebasContrapresion()
    pruebasLimpieza()
    pruebasMapeo()
}

private fun pruebasReintentos() {
    Runner.prueba("reintento: causa reintentable llama a reabrir desde el byte necesario y continua sin repetir bytes") {
        conMotor { store, reg, motor ->
            val d = datos(100_000)
            val o1 = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 50_000)
            val o2 = OrigenSimulado(d, maxPorLlamada = 4096)
            val llamadas = CopyOnWriteArrayList<Pair<Long, MusaCausa>>()
            val f = adaptada(o1) { desde, causa ->
                llamadas += desde to causa
                adaptada(o2)
            }
            val s = SalidaRegistro()
            val rep = motor.abrir(f, s)
            reg.esperar { it is MusaEvento.Liberado }
            val g = rep.generacion
            igual(listOf(50_000L to MusaCausa.RED_TRANSITORIA), llamadas.toList())
            igual(
                listOf("Cargando", "Listo", "Sonando", "Cargando", "Listo", "Sonando", "Terminado", "Liberado"),
                reg.nombres(g),
            )
            val cargas = reg.eventos.filterIsInstance<MusaEvento.Cargando>()
            igual(listOf(MusaMotivo.PISTA_NUEVA, MusaMotivo.REINTENTO), cargas.map { it.motivo })
            afirma(s.bytes.contentEquals(d), "salida completa y en orden")
            verificaSinRepetidos(d.size, o1, o2)
            igual(50_000L, o2.offsetMinimo())
            afirma(o1.cerrado && o2.cerrado)
            igual(1, s.liberaciones.get())
            afirma(!store.contiene("musa-$g") && listar(store.dirEfimero).isEmpty())
        }
    }
    Runner.prueba("reintento: maximo 2 y, agotados, una sola Falla con la causa final") {
        conMotor { _, reg, motor ->
            val d = datos(60_000)
            val origenes = CopyOnWriteArrayList<OrigenSimulado>()
            val llamadas = AtomicInteger(0)
            val o1 = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 30_000)
            origenes += o1
            lateinit var siguiente: (Long, MusaCausa) -> MusaFuenteAudio?
            siguiente = { _, _ ->
                llamadas.incrementAndGet()
                val o = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 30_000)
                origenes += o
                adaptada(o, reabrir = siguiente)
            }
            val s = SalidaRegistro()
            val rep = motor.abrir(adaptada(o1, reabrir = siguiente), s)
            reg.esperar { it is MusaEvento.Liberado }
            val g = rep.generacion
            igual(2, llamadas.get())
            igual(3, origenes.size)
            igual(2, reg.eventos.filterIsInstance<MusaEvento.Cargando>().count { it.motivo == MusaMotivo.REINTENTO })
            igual(1, reg.cuenta(g, MusaEvento.Falla::class.java))
            igual(0, reg.cuenta(g, MusaEvento.Terminado::class.java))
            val f = reg.eventos.filterIsInstance<MusaEvento.Falla>().single()
            igual(MusaCausa.RED_TRANSITORIA, f.causa)
            afirma(origenes.all { it.cerrado })
            afirma(s.bytes.contentEquals(d.copyOf(30_000)), "solo el prefijo integro")
            igual(1, s.liberaciones.get())
        }
    }
    Runner.prueba("reintento: causas no reintentables no llaman a reabrir y fallan una vez") {
        for (causa in listOf(
            MusaCausa.SESION_INVALIDA, MusaCausa.BLOQUEO_RED, MusaCausa.VERIFICACION_REQUERIDA,
            MusaCausa.NO_ENCONTRADO, MusaCausa.CALIDAD_NO_DISPONIBLE,
        )) {
            conMotor { _, reg, motor ->
                val llamadas = AtomicInteger(0)
                val o = OrigenSimulado(datos(40_000), maxPorLlamada = 4096, fallaEnOffset = 20_000)
                val f = adaptada(o, { causa }) { _, _ ->
                    llamadas.incrementAndGet()
                    null
                }
                val rep = motor.abrir(f, SalidaRegistro())
                reg.esperar { it is MusaEvento.Liberado }
                igual(0, llamadas.get(), "reabrir con $causa")
                val fallas = reg.eventos.filterIsInstance<MusaEvento.Falla>()
                igual(1, fallas.size)
                igual(causa, fallas.single().causa)
                afirma(!fallas.single().reintentable)
                igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
                igual(1, reg.eventos.filterIsInstance<MusaEvento.Cargando>().size)
            }
        }
    }
    Runner.prueba("reintento: si reabrir devuelve null falla con la causa original sin Cargando de reintento") {
        conMotor { _, reg, motor ->
            val llamadas = AtomicInteger(0)
            val o = OrigenSimulado(datos(40_000), maxPorLlamada = 4096, fallaEnOffset = 20_000)
            val f = adaptada(o, { MusaCausa.PROVEEDOR_NO_DISPONIBLE }) { _, _ ->
                llamadas.incrementAndGet()
                null
            }
            motor.abrir(f, SalidaRegistro())
            reg.esperar { it is MusaEvento.Liberado }
            igual(1, llamadas.get())
            igual(MusaCausa.PROVEEDOR_NO_DISPONIBLE, reg.eventos.filterIsInstance<MusaEvento.Falla>().single().causa)
            igual(1, reg.eventos.filterIsInstance<MusaEvento.Cargando>().size)
        }
    }
    Runner.prueba("reintento: LIMITE_TASA espera el retardo configurado (inyectado, sin dormir) y otras causas no esperan") {
        val esperas = CopyOnWriteArrayList<Long>()
        val config = MusaConfigMotor(
            chunk = 4096, timeoutLecturaMs = 50, esperaLimiteTasaMs = 777, espera = MusaEspera { esperas += it },
        )
        conMotor(config = config) { _, reg, motor ->
            val d = datos(90_000)
            val llamadas = AtomicInteger(0)
            val o3 = OrigenSimulado(d, maxPorLlamada = 4096)
            val o2 = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 60_000)
            val o1 = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 30_000)
            val f = adaptada(o1, { MusaCausa.LIMITE_TASA }) { _, _ ->
                llamadas.incrementAndGet()
                adaptada(o2, { MusaCausa.RED_TRANSITORIA }) { _, _ ->
                    llamadas.incrementAndGet()
                    adaptada(o3)
                }
            }
            val s = SalidaRegistro()
            motor.abrir(f, s)
            reg.esperar { it is MusaEvento.Liberado }
            igual(listOf(777L), esperas.toList())
            igual(2, llamadas.get())
            afirma(s.bytes.contentEquals(d))
            igual(1, reg.eventos.filterIsInstance<MusaEvento.Terminado>().size)
        }
    }
    Runner.prueba("reintento: cancelar durante la espera de LIMITE_TASA despierta, no llama a reabrir y libera") {
        val config = MusaConfigMotor(chunk = 4096, timeoutLecturaMs = 50, esperaLimiteTasaMs = 60_000)
        conMotor(config = config) { _, reg, motor ->
            val llamadas = AtomicInteger(0)
            val o = OrigenSimulado(datos(40_000), maxPorLlamada = 4096, fallaEnOffset = 20_000)
            val f = adaptada(o, { MusaCausa.LIMITE_TASA }) { _, _ ->
                llamadas.incrementAndGet()
                null
            }
            val s = SalidaRegistro()
            val rep = motor.abrir(f, s)
            esperarHasta {
                Thread.getAllStackTraces().any { (h, pila) ->
                    h.name == "musa-reproduccion-${rep.generacion}" &&
                        h.state == Thread.State.TIMED_WAITING && pila.any { it.methodName == "esperarCancelable" }
                }
            }
            val t0 = System.nanoTime()
            afirma(rep.cancelar(), "confirma la cancelacion")
            afirma((System.nanoTime() - t0) / 1_000_000 < 2_000, "no espero los 60 s")
            reg.esperar { it is MusaEvento.Liberado }
            igual(0, llamadas.get(), "no reintenta tras cancelar")
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Falla::class.java))
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            afirma(o.cerrado && s.liberaciones.get() == 1)
            esperarHasta { hilosVivos("musa-reproduccion") == 0 && hilosVivos("transferencia-bytes") == 0 }
        }
    }
}

private fun pruebasGeneracion() {
    Runner.prueba("generacion: si la fuente invalida, descarta lo recibido y pide de nuevo desde el byte necesario") {
        conMotor { store, reg, motor ->
            val a = datos(100_000, 1)
            val b = datos(100_000, 2)
            val gen = AtomicLong(1)
            val o1 = OrigenSimulado(a, maxPorLlamada = 4096)
            val oB = OrigenSimulado(b, maxPorLlamada = 4096)
            val vistoAlLeer = CopyOnWriteArrayList<Boolean>()
            val llamadas = CopyOnWriteArrayList<Pair<Long, MusaCausa>>()
            lateinit var rep: MusaReproduccion
            val observado = OrigenObservado(oB) {
                vistoAlLeer += store.contiene("musa-${rep.generacion}")
                vistoAlLeer += store.contiene("musa-${rep.generacion}-1")
            }
            val f1 = adaptada(o1, generacion = { gen.get() }) { desde, causa ->
                llamadas += desde to causa
                adaptada(observado, generacion = { 2L })
            }
            val s = SalidaRegistro()
            rep = motor.abrir(f1, s, iniciarSonando = false)
            reg.esperar { it is MusaEvento.Pausado }
            esperarHasta { o1.bytesServidos >= 100_000 }
            gen.set(2)
            rep.play()
            reg.esperar { it is MusaEvento.Liberado }
            igual(listOf(4096L to MusaCausa.ENLACE_EXPIRADO), llamadas.toList())
            igual(listOf(false, true), vistoAlLeer.toList())
            igual(4096L, oB.offsetMinimo())
            igual(100_000L - 4096, oB.bytesServidos)
            val salida = s.bytes
            igual(100_000, salida.size)
            afirma(salida.copyOfRange(0, 4096).contentEquals(a.copyOfRange(0, 4096)), "prefijo de la generacion vieja")
            afirma(salida.copyOfRange(4096, 100_000).contentEquals(b.copyOfRange(4096, 100_000)), "resto solo de la nueva")
            igual(1, reg.eventos.filterIsInstance<MusaEvento.Terminado>().size)
            afirma(!store.contiene("musa-${rep.generacion}") && !store.contiene("musa-${rep.generacion}-1"))
            afirma(listar(store.dirEfimero).isEmpty())
        }
    }
    Runner.prueba("generacion: sin invalidacion y misma generacion tras reabrir se conservan los rangos recibidos") {
        conMotor { _, reg, motor ->
            val d = datos(80_000)
            val o1 = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 40_000)
            val o2 = OrigenSimulado(d, maxPorLlamada = 4096)
            val f = adaptada(o1, generacion = { 7L }) { _, _ -> adaptada(o2, generacion = { 7L }) }
            val s = SalidaRegistro()
            motor.abrir(f, s)
            reg.esperar { it is MusaEvento.Liberado }
            afirma(s.bytes.contentEquals(d))
            verificaSinRepetidos(d.size, o1, o2)
        }
    }
}

private fun pruebasContrapresion() {
    Runner.prueba("contrapresion: la recepcion no pasa de la ventana por delante de la lectura y se reanuda al leer") {
        conMotor(config = configVentana(8192)) { _, reg, motor ->
            val d = datos(200_000)
            val o = OrigenSimulado(d, maxPorLlamada = 4096)
            val s = SalidaRegistro()
            val rep = motor.abrir(adaptada(o), s, iniciarSonando = false)
            reg.esperar { it is MusaEvento.Pausado }
            val estable = esperarEstable { o.bytesServidos }
            afirma(estable >= 12_288, "llena la ventana: $estable")
            afirma(estable <= 8192 + 8192 + 4096, "no se adelanta mas que la ventana: $estable")
            rep.play()
            reg.esperar { it is MusaEvento.Terminado }
            afirma(s.bytes.contentEquals(d))
            igual(d.size.toLong(), o.bytesServidos)
        }
    }
    Runner.prueba("contrapresion: tamano desconocido o menor que la ventana termina sin interbloqueo") {
        conMotor(config = configVentana(8192)) { _, reg, motor ->
            val d1 = datos(30_001)
            val s1 = SalidaRegistro()
            motor.abrir(adaptada(OrigenSimulado(d1, tamanoConocido = false, maxPorLlamada = 4096)), s1)
            reg.esperar { it is MusaEvento.Terminado && it.generacion == 1L }
            afirma(s1.bytes.contentEquals(d1))
            val d2 = datos(5_000)
            val s2 = SalidaRegistro()
            motor.abrir(adaptada(OrigenSimulado(d2, maxPorLlamada = 4096)), s2)
            reg.esperar { it is MusaEvento.Terminado && it.generacion == 2L }
            afirma(s2.bytes.contentEquals(d2))
            val d3 = datos(60_000)
            val s3 = SalidaRegistro()
            motor.abrir(adaptada(OrigenSimulado(d3, admiteRangos = false, maxPorLlamada = 4096)), s3)
            reg.esperar { it is MusaEvento.Terminado && it.generacion == 3L }
            afirma(s3.bytes.contentEquals(d3), "origen secuencial con ventana")
        }
    }
    Runner.prueba("contrapresion: cancelar con la recepcion frenada libera la transferencia") {
        conMotor(config = configVentana(8192)) { _, reg, motor ->
            val o = OrigenSimulado(datos(200_000), maxPorLlamada = 4096)
            val s = SalidaRegistro()
            val rep = motor.abrir(adaptada(o), s, iniciarSonando = false)
            reg.esperar { it is MusaEvento.Pausado }
            esperarEstable { o.bytesServidos }
            afirma(rep.cancelar(), "confirma")
            reg.esperar { it is MusaEvento.Liberado }
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            afirma(o.cerrado && s.liberaciones.get() == 1)
            esperarHasta { hilosVivos("transferencia-bytes") == 0 && hilosVivos("musa-reproduccion") == 0 }
        }
    }
    Runner.prueba("contrapresion: un salto de lectura lejano con la recepcion frenada no se interbloquea") {
        conTemp { dir ->
            SegmentStore(dir.resolve("e"), 10L * 1024 * 1024).use { store ->
                val d = datos(300_000)
                val o = OrigenSimulado(d, maxPorLlamada = 4096)
                val item = store.abrir("k", Retencion.EFIMERO)
                val t = item.asegurarTransferencia(4096, 0, 8192) { o }!!
                val lector = item.lector()
                afirma(leerExacto(lector, 0, 100).contentEquals(d.copyOfRange(0, 100)))
                val estable = esperarEstable { o.bytesServidos }
                afirma(estable <= 100 + 8192 + 4096, "frenada: $estable")
                afirma(leerExacto(lector, 250_000, 100).contentEquals(d.copyOfRange(250_000, 250_100)))
                afirma(leerExacto(lector, 10, 100).contentEquals(d.copyOfRange(10, 110)), "vuelta atras ya recibida")
                t.cancelar()
                afirma(t.esperar(10_000))
                lector.close()
                item.close()
            }
        }
    }
    Runner.prueba("contrapresion: no se aplica a la fuente local ni cambia el resultado") {
        conMotor(config = configVentana(1024)) { _, reg, motor ->
            conTemp { dir ->
                val d = datos(70_000)
                val ruta = dir.resolve("l.flac")
                Files.write(ruta, d)
                val s = SalidaRegistro()
                motor.abrir(MusaFuenteLocal(ruta), s)
                reg.esperar { it is MusaEvento.Terminado }
                afirma(s.bytes.contentEquals(d))
            }
        }
    }
}

private fun pruebasLimpieza() {
    Runner.prueba("limpieza: el item efimero se descarta al terminar, al cancelar y al fallar; los ajenos se conservan") {
        conMotor { store, reg, motor ->
            val ajeno = store.abrir("ajeno", Retencion.EFIMERO)
            ajeno.escribir(0, datos(100), 0, 100)
            ajeno.close()
            val s1 = SalidaRegistro()
            val r1 = motor.abrir(adaptada(OrigenSimulado(datos(50_000), maxPorLlamada = 4096)), s1)
            reg.esperar { it is MusaEvento.Liberado && it.generacion == r1.generacion }
            afirma(!store.contiene("musa-${r1.generacion}"), "fin")
            val o2 = OrigenSimulado(datos(50_000), maxPorLlamada = 4096)
            o2.liberarHasta(8192)
            val r2 = motor.abrir(adaptada(o2), SalidaRegistro())
            reg.esperar { it is MusaEvento.Sonando && it.generacion == r2.generacion }
            afirma(store.contiene("musa-${r2.generacion}"), "durante la reproduccion existe")
            afirma(r2.cancelar())
            reg.esperar { it is MusaEvento.Liberado && it.generacion == r2.generacion }
            afirma(!store.contiene("musa-${r2.generacion}"), "cancelada")
            val r3 = motor.abrir(adaptada(OrigenSimulado(datos(50_000), maxPorLlamada = 4096, fallaEnOffset = 20_000), reabrir = null), SalidaRegistro())
            reg.esperar { it is MusaEvento.Liberado && it.generacion == r3.generacion }
            afirma(!store.contiene("musa-${r3.generacion}"), "fallida")
            afirma(store.contiene("ajeno"))
            igual(100L, store.bytesEfimeros())
            igual(1, listar(store.dirEfimero).size)
        }
    }
    Runner.prueba("limpieza: la purga LRU sigue descartando items ajenos y respeta el item en uso") {
        conTemp { dir ->
            SegmentStore(dir.resolve("e"), 6000).use { store ->
                val a = store.abrir("a", Retencion.EFIMERO)
                a.escribir(0, datos(5000), 0, 5000)
                a.close()
                val reg = RegistroEventos()
                val motor = MusaMotorAudio(store, reg, MusaConfigMotor(chunk = 4096, timeoutLecturaMs = 50))
                val d = datos(30_000)
                val s = SalidaRegistro()
                val rep = motor.abrir(adaptada(OrigenSimulado(d, maxPorLlamada = 4096)), s)
                reg.esperar { it is MusaEvento.Liberado }
                afirma(s.bytes.contentEquals(d), "el item en uso no se purgo")
                afirma(!store.contiene("a") && store.purgados >= 1, "LRU descarto el ajeno")
                afirma(!store.contiene("musa-${rep.generacion}"))
                igual(0L, store.bytesEfimeros())
            }
        }
    }
}

private fun pruebasMapeo() {
    Runner.prueba("salida: un error asincrono del reproductor mapeado a MusaCausa produce una Falla y libera") {
        conMotor { _, reg, motor ->
            val o = OrigenSimulado(datos(200_000), maxPorLlamada = 4096)
            val s = SalidaErrorAsincrono(MusaMapeoErrores.CODIGO_FORMATO_NO_SOPORTADO)
            val rep = motor.abrir(adaptada(o), s)
            reg.esperar { it is MusaEvento.Liberado }
            val fallas = reg.eventos.filterIsInstance<MusaEvento.Falla>()
            igual(1, fallas.size)
            igual(MusaCausa.FORMATO_NO_SOPORTADO, fallas.single().causa)
            afirma(!fallas.single().reintentable)
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            igual(1, s.liberaciones.get())
            afirma(o.cerrado)
        }
    }
    Runner.prueba("mapeo: codigos de Media3 y tipos de excepcion a MusaCausa") {
        val m = MusaMapeoErrores
        val tabla = listOf(
            m.CODIGO_ES_RED_CONEXION to MusaCausa.RED_TRANSITORIA,
            m.CODIGO_ES_RED_TIEMPO to MusaCausa.TIEMPO_AGOTADO,
            m.CODIGO_TIEMPO_AGOTADO to MusaCausa.TIEMPO_AGOTADO,
            m.CODIGO_ES_ARCHIVO_AUSENTE to MusaCausa.NO_ENCONTRADO,
            m.CODIGO_ES_SIN_PERMISO to MusaCausa.NO_ENCONTRADO,
            m.CODIGO_CONTENEDOR_NO_SOPORTADO to MusaCausa.CONTENEDOR_NO_RECONOCIDO,
            m.CODIGO_CONTENEDOR_MALFORMADO to MusaCausa.ARCHIVO_CORRUPTO,
            m.CODIGO_DECODIFICACION_FALLIDA to MusaCausa.ARCHIVO_CORRUPTO,
            m.CODIGO_DECODIFICADOR_INICIO to MusaCausa.DECODIFICADOR,
            m.CODIGO_DECODIFICADOR_CONSULTA to MusaCausa.DECODIFICADOR,
            m.CODIGO_FORMATO_NO_SOPORTADO to MusaCausa.FORMATO_NO_SOPORTADO,
            m.CODIGO_FORMATO_EXCEDE_CAPACIDAD to MusaCausa.FORMATO_NO_SOPORTADO,
            m.CODIGO_PISTA_AUDIO_INICIO to MusaCausa.SALIDA_AUDIO,
            m.CODIGO_PISTA_AUDIO_ESCRITURA to MusaCausa.SALIDA_AUDIO,
            m.CODIGO_DRM_ESQUEMA_NO_SOPORTADO to MusaCausa.DESCIFRADO_NO_SOPORTADO,
            6004 to MusaCausa.CLAVE_INVALIDA,
            m.CODIGO_DESCONOCIDO to MusaCausa.DESCONOCIDA,
            m.CODIGO_DRM_DESCONOCIDO to MusaCausa.DESCONOCIDA,
            -1 to MusaCausa.DESCONOCIDA,
            Int.MAX_VALUE to MusaCausa.DESCONOCIDA,
        )
        for ((codigo, esperada) in tabla) igual(esperada, m.causaDe(codigo), "codigo $codigo")
        igual(MusaCausa.TIEMPO_AGOTADO, m.causaDe(m.CODIGO_ES_DESCONOCIDO, "java.net.SocketTimeoutException"))
        igual(MusaCausa.RED_TRANSITORIA, m.causaDe(m.CODIGO_ES_DESCONOCIDO, "java.net.UnknownHostException"))
        igual(MusaCausa.NO_ENCONTRADO, m.causaDe(m.CODIGO_DESCONOCIDO, "FileNotFoundException"))
        igual(MusaCausa.ARCHIVO_CORRUPTO, m.causaDe(m.CODIGO_DESCONOCIDO, "androidx.media3.common.ParserException"))
        igual(MusaCausa.DECODIFICADOR, m.causaDe(m.CODIGO_DESCONOCIDO, "Otro", listOf("X\$DecoderInitializationException")))
        igual(MusaCausa.DESCONOCIDA, m.causaDe(m.CODIGO_DESCONOCIDO, "RuntimeException"))
        igual(MusaCausa.FORMATO_NO_SOPORTADO, m.causaDe(m.CODIGO_FORMATO_NO_SOPORTADO, "SocketTimeoutException"), "el codigo manda")
        afirma(MusaCausa.TIEMPO_AGOTADO.reintentable && MusaCausa.TIEMPO_AGOTADO.origen == MusaOrigenCausa.MOTOR)
        afirma(!MusaCausa.DECODIFICADOR.reintentable)
    }
}
