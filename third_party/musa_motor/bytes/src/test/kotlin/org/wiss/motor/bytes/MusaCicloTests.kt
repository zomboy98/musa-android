package org.wiss.motor.bytes

import java.io.ByteArrayOutputStream
import java.io.ObjectOutputStream
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private const val MEGA = 1024 * 1024

class RegistroEventos(private val alRecibir: (MusaEvento) -> Unit = {}) : MusaOyente {
    val eventos = CopyOnWriteArrayList<MusaEvento>()
    private val lock = ReentrantLock()
    private val cond = lock.newCondition()

    override fun alEvento(evento: MusaEvento) {
        lock.withLock {
            eventos += evento
            cond.signalAll()
        }
        alRecibir(evento)
    }

    fun esperar(ms: Long = 10_000, pred: (MusaEvento) -> Boolean): MusaEvento {
        val limite = System.nanoTime() + ms * 1_000_000
        lock.withLock {
            while (true) {
                val e = eventos.firstOrNull(pred)
                if (e != null) return e
                val resto = limite - System.nanoTime()
                if (resto <= 0) throw FalloPrueba("evento no llego; hubo ${nombres()}")
                cond.awaitNanos(resto)
            }
        }
    }

    fun nombres(gen: Long? = null): List<String> =
        eventos.filter { gen == null || it.generacion == gen }.map { it.javaClass.simpleName }

    fun cuenta(gen: Long, clase: Class<*>): Int = eventos.count { it.generacion == gen && clase.isInstance(it) }
}

class SalidaRegistro(private val bloquearEscribir: Boolean = false) : MusaSalida {
    private val acumulado = ByteArrayOutputStream()
    private val soltar = CountDownLatch(1)
    val enEscritura = CountDownLatch(1)
    val liberaciones = AtomicInteger(0)

    @Volatile
    var abortada = false
        private set

    @Volatile
    var info: MusaInfoMedio? = null
        private set

    val bytes: ByteArray get() = synchronized(acumulado) { acumulado.toByteArray() }

    override fun abrir(info: MusaInfoMedio) {
        this.info = info
    }

    override fun escribir(buffer: ByteArray, desde: Int, len: Int) {
        synchronized(acumulado) { acumulado.write(buffer, desde, len) }
        if (bloquearEscribir) {
            enEscritura.countDown()
            var interrumpido = false
            while (true) {
                try {
                    soltar.await()
                    break
                } catch (_: InterruptedException) {
                    interrumpido = true
                }
            }
            if (interrumpido) Thread.currentThread().interrupt()
        }
    }

    fun soltar() = soltar.countDown()

    override fun drenar() {}
    override fun pausar() {}
    override fun reanudar() {}
    override fun posicionMs(): Long = 0
    override fun abortar() {
        abortada = true
    }

    override fun liberar() {
        liberaciones.incrementAndGet()
    }
}

class SalidaQueFalla : MusaSalida {
    override fun abrir(info: MusaInfoMedio) {}
    override fun escribir(buffer: ByteArray, desde: Int, len: Int) {
        throw IllegalStateException("secreto-salida")
    }

    override fun drenar() {}
    override fun pausar() {}
    override fun reanudar() {}
    override fun posicionMs(): Long = 0
    override fun abortar() {}
    override fun liberar() {}
}

internal val infoFlac = MusaInfoMedio(MusaContenedor.FLAC, MusaCodec.FLAC)
private val infoVideo = MusaInfoMedio(MusaContenedor.MP4, MusaCodec.AAC, duracionMs = 1000)

internal fun fuenteDe(o: OrigenSimulado, info: MusaInfoMedio = infoFlac) =
    MusaFuenteAdaptada(o, info, { MusaCausa.RED_TRANSITORIA })

internal fun esperarHasta(ms: Long = 10_000, cond: () -> Boolean) {
    val limite = System.nanoTime() + ms * 1_000_000
    while (!cond()) {
        if (System.nanoTime() > limite) {
            throw FalloPrueba("condicion no cumplida a tiempo")
        }
        Thread.sleep(5)
    }
}

internal fun hilosVivos(prefijo: String): Int =
    Thread.getAllStackTraces().keys.count { it.isAlive && it.name.startsWith(prefijo) }

internal fun conMotor(
    cancelacionMs: Long = 3_000,
    alRecibir: (MusaEvento) -> Unit = {},
    config: MusaConfigMotor = MusaConfigMotor(chunk = 4096, timeoutLecturaMs = 50, cancelacionMs = cancelacionMs),
    cuerpo: (SegmentStore, RegistroEventos, MusaMotorAudio) -> Unit,
) = conTemp { dir ->
    SegmentStore(dir.resolve("efimero"), 10L * MEGA).use { store ->
        val reg = RegistroEventos(alRecibir)
        val motor = MusaMotorAudio(store, reg, config)
        cuerpo(store, reg, motor)
    }
}

fun pruebasMusa() {
    pruebasTipos()
    pruebasFuenteLocal()
    pruebasAdaptador()
    pruebasCicloVida()
    pruebasCambios()
    pruebasMusaReintentos()
}

private fun pruebasTipos() {
    Runner.prueba("MusaSecreto: redactado, no serializable, borrado al cerrar") {
        val s = MusaSecreto(byteArrayOf(11, 22, 33, 44))
        igual("MusaSecreto(***)", s.toString())
        val d = MusaDescifrado(MusaEsquema.CENC_AES128_CTR, s, "mov")
        val info = MusaInfoMedio(MusaContenedor.MP4, MusaCodec.EAC3, d, 5000)
        afirma(d.toString().contains("***") && info.toString().contains("***"), "toString con marca")
        afirma(!"$info".contains("[B@") && !"$info".contains("22, 33"), "no vuelca bytes")
        var fallo = false
        try {
            ObjectOutputStream(ByteArrayOutputStream()).use { it.writeObject(s) }
        } catch (_: java.io.NotSerializableException) {
            fallo = true
        }
        afirma(fallo, "no debe serializarse")
        var copia: ByteArray? = null
        s.usar { copia = it }
        s.close()
        afirma(copia!!.all { it == 0.toByte() }, "bytes borrados")
        var cerrado = false
        try {
            s.usar { }
        } catch (_: IllegalStateException) {
            cerrado = true
        }
        afirma(cerrado, "no se usa tras cerrar")
    }
    Runner.prueba("MusaCausa: enum cerrado con ambos sentidos y reintentables de sesion") {
        val sesion = MusaCausa.entries.filter { it.origen == MusaOrigenCausa.SESION }
        val motor = MusaCausa.entries.filter { it.origen == MusaOrigenCausa.MOTOR }
        igual(12, sesion.size, "causas sesion->motor")
        afirma(motor.containsAll(listOf(
            MusaCausa.FORMATO_NO_SOPORTADO, MusaCausa.CONTENEDOR_NO_RECONOCIDO, MusaCausa.ARCHIVO_CORRUPTO,
            MusaCausa.CLAVE_INVALIDA, MusaCausa.DESCIFRADO_NO_SOPORTADO, MusaCausa.DATOS_INSUFICIENTES,
            MusaCausa.SALIDA_AUDIO, MusaCausa.CANCELACION_NO_CONFIRMADA,
        )), "causas motor->interfaz")
        afirma(MusaCausa.RED_TRANSITORIA.reintentable && MusaCausa.ENLACE_EXPIRADO.reintentable)
        afirma(!MusaCausa.SESION_INVALIDA.reintentable && !MusaCausa.NO_ENCONTRADO.reintentable)
        igual(MusaCausa.entries.size, MusaCausa.entries.map { it.name }.toSet().size)
    }
}

private fun pruebasFuenteLocal() {
    Runner.prueba("MusaFuenteLocal: completo desde el inicio, rangos, seek y EOF") {
        conTemp { dir ->
            val d = datos(50_000)
            val ruta = dir.resolve("cancion.flac")
            Files.write(ruta, d)
            MusaFuenteLocal(ruta, 1234).use { f ->
                igual(EstadoOrigen.COMPLETO, f.estado)
                igual(50_000L, f.tamano)
                afirma(f.admiteRangos)
                afirma(f.info.local)
                igual(MusaContenedor.FLAC, f.info.contenedor)
                igual(MusaCodec.FLAC, f.info.codec)
                igual(1234L, f.info.duracionMs)
                afirma(f.causa == null && f.info.descifrado == null)
                igual(null, f.reabrir(0, MusaCausa.RED_TRANSITORIA))
                val b = ByteArray(100)
                igual(100, f.leer(20_000, b, 0, 100))
                afirma(b.contentEquals(d.copyOfRange(20_000, 20_100)))
                igual(10, f.leer(49_990, b, 0, 100))
                afirma(b.copyOf(10).contentEquals(d.copyOfRange(49_990, 50_000)))
                igual(-1, f.leer(50_000, b, 0, 100))
                igual(-1, f.leer(60_000, b, 0, 100))
                igual(0, f.leer(0, b, 0, 0))
                val atras = ByteArray(10)
                igual(10, f.leer(5, atras, 0, 10))
                afirma(atras.contentEquals(d.copyOfRange(5, 15)))
            }
        }
    }
    Runner.prueba("MusaFuenteLocal: archivo ausente -> NO_ENCONTRADO sin excepcion al construir") {
        conTemp { dir ->
            MusaFuenteLocal(dir.resolve("no-existe.mp3")).use { f ->
                igual(EstadoOrigen.ERROR, f.estado)
                igual(MusaCausa.NO_ENCONTRADO, f.causa)
                var io = false
                try {
                    f.leer(0, ByteArray(4), 0, 4)
                } catch (_: java.io.IOException) {
                    io = true
                }
                afirma(io, "leer lanza IOException")
            }
        }
    }
    Runner.prueba("MusaFuenteLocal: cancelar aborta lecturas, es idempotente y extension desconocida") {
        conTemp { dir ->
            val ruta = dir.resolve("raro.xyz")
            Files.write(ruta, datos(100))
            val f = MusaFuenteLocal(ruta)
            igual(MusaContenedor.DESCONOCIDO, f.info.contenedor)
            f.cancelar()
            f.cancelar()
            igual(EstadoOrigen.CANCELADO, f.estado)
            var cancel = false
            try {
                f.leer(0, ByteArray(4), 0, 4)
            } catch (_: CancelacionException) {
                cancel = true
            }
            afirma(cancel)
            f.close()
        }
    }
}

private fun pruebasAdaptador() {
    Runner.prueba("MusaFuenteAdaptada: delega, fija causa al fallar y reabrir respeta reintentable") {
        val d = datos(10_000)
        val o = OrigenSimulado(d, fallaEnOffset = 5000)
        val nueva = MusaFuenteAdaptada(OrigenSimulado(d), infoFlac)
        val f = MusaFuenteAdaptada(o, infoFlac, { MusaCausa.ENLACE_EXPIRADO }) { desde, _ ->
            afirma(desde == 5000L)
            nueva
        }
        igual(10_000L, f.tamano)
        afirma(f.admiteRangos && f.causa == null)
        val b = ByteArray(8000)
        var io = false
        var offset = 0
        try {
            while (true) offset += f.leer(offset.toLong(), b, 0, 4096).also { afirma(it > 0) }
        } catch (_: java.io.IOException) {
            io = true
        }
        afirma(io)
        igual(EstadoOrigen.ERROR, f.estado)
        igual(MusaCausa.ENLACE_EXPIRADO, f.causa)
        afirma(f.reabrir(5000, MusaCausa.ENLACE_EXPIRADO) === nueva, "reabre si es reintentable")
        igual(null, f.reabrir(5000, MusaCausa.SESION_INVALIDA))
        f.close()
        f.close()
        afirma(o.cerrado)
    }
}

private fun pruebasCicloVida() {
    Runner.prueba("ciclo: fin normal remoto emite Cargando, Listo, Sonando, Terminado y Liberado una vez") {
        conMotor { _, reg, motor ->
            val d = datos(200_000)
            val o = OrigenSimulado(d, maxPorLlamada = 8000)
            val s = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(o), s)
            reg.esperar { it is MusaEvento.Liberado }
            igual(listOf("Cargando", "Listo", "Sonando", "Terminado", "Liberado"), reg.nombres(rep.generacion))
            afirma(s.bytes.contentEquals(d), "bytes completos y en orden")
            igual(1, s.liberaciones.get())
            afirma(o.cerrado && rep.liberadaPorCompleto)
            igual(infoFlac, s.info)
            afirma(rep.cancelar(), "cancelar tras terminar confirma sin emitir mas")
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Liberado::class.java))
        }
    }
    Runner.prueba("ciclo: fin con longitud antes desconocida emite Terminado") {
        conMotor { _, reg, motor ->
            val d = datos(123_457)
            val o = OrigenSimulado(d, tamanoConocido = false, maxPorLlamada = 5000)
            val s = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(o), s)
            reg.esperar { it is MusaEvento.Liberado }
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Falla::class.java))
            afirma(s.bytes.contentEquals(d))
        }
    }
    Runner.prueba("ciclo: fin con fuente local sin pasar por la cache") {
        conMotor { store, reg, motor ->
            conTemp { dir ->
                val d = datos(150_000)
                val ruta = dir.resolve("a.mp3")
                Files.write(ruta, d)
                val s = SalidaRegistro()
                val rep = motor.abrir(MusaFuenteLocal(ruta), s)
                reg.esperar { it is MusaEvento.Liberado }
                igual(listOf("Cargando", "Listo", "Sonando", "Terminado", "Liberado"), reg.nombres(rep.generacion))
                afirma(s.bytes.contentEquals(d))
                igual(0L, store.bytesEfimeros())
                afirma(!store.contiene("musa-${rep.generacion}"))
                igual(1, s.liberaciones.get())
            }
        }
    }
    Runner.prueba("ciclo: archivo local vacio termina sin Listo y local ausente falla NO_ENCONTRADO") {
        conMotor { _, reg, motor ->
            conTemp { dir ->
                val vacio = dir.resolve("vacio.wav")
                Files.write(vacio, ByteArray(0))
                val rep = motor.abrir(MusaFuenteLocal(vacio), SalidaRegistro())
                reg.esperar { it is MusaEvento.Liberado && it.generacion == rep.generacion }
                igual(listOf("Cargando", "Terminado", "Liberado"), reg.nombres(rep.generacion))
                val rep2 = motor.abrir(MusaFuenteLocal(dir.resolve("falta.flac")), SalidaRegistro())
                reg.esperar { it is MusaEvento.Liberado && it.generacion == rep2.generacion }
                val f = reg.eventos.filterIsInstance<MusaEvento.Falla>().single { it.generacion == rep2.generacion }
                igual(MusaCausa.NO_ENCONTRADO, f.causa)
                afirma(!f.reintentable)
                igual(0, reg.cuenta(rep2.generacion, MusaEvento.Terminado::class.java))
            }
        }
    }
    Runner.prueba("ciclo: cancelacion durante la recepcion libera todo y confirma con Liberado") {
        conMotor { _, reg, motor ->
            val d = datos(100_000)
            val o = OrigenSimulado(d, maxPorLlamada = 4096)
            o.liberarHasta(8192)
            val s = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(o), s)
            reg.esperar { it is MusaEvento.Sonando }
            afirma(rep.cancelar(), "debe confirmar")
            reg.esperar { it is MusaEvento.Liberado }
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Falla::class.java))
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Liberado::class.java))
            afirma(o.cerrado && s.abortada)
            igual(1, s.liberaciones.get())
            afirma(rep.liberadaPorCompleto)
            afirma(s.bytes.size <= 8192, "no sigue escribiendo")
            esperarHasta { hilosVivos("transferencia-bytes") == 0 }
        }
    }
    Runner.prueba("ciclo: cancelacion sin respuesta vence el tiempo, emite Falla una vez y el ACK tardio llega") {
        conMotor(cancelacionMs = 300) { _, reg, motor ->
            val d = datos(50_000)
            val o = OrigenSimulado(d, maxPorLlamada = 4096)
            val bloqueada = SalidaRegistro(bloquearEscribir = true)
            val rep = motor.abrir(fuenteDe(o), bloqueada)
            afirma(bloqueada.enEscritura.await(10, TimeUnit.SECONDS))
            val t0 = System.nanoTime()
            igual(false, rep.cancelar(300), "no hay confirmacion")
            val ms = (System.nanoTime() - t0) / 1_000_000
            afirma(ms in 250..3000, "respeto el tiempo limite: $ms ms")
            val f = reg.eventos.filterIsInstance<MusaEvento.Falla>().single()
            igual(MusaCausa.CANCELACION_NO_CONFIRMADA, f.causa)
            afirma(!f.reintentable)
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Liberado::class.java), "sin ACK todavia")
            igual(false, rep.cancelar(100), "segundo cancelar tampoco duplica el evento")
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Falla::class.java))
            afirma(!rep.liberadaPorCompleto)
            bloqueada.soltar()
            reg.esperar { it is MusaEvento.Liberado }
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Liberado::class.java))
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            afirma(rep.liberadaPorCompleto)
            igual(1, bloqueada.liberaciones.get())
        }
    }
    Runner.prueba("ciclo: error a mitad emite Falla con causa y sin Terminado; sin datos sensibles en eventos") {
        conMotor { _, reg, motor ->
            val d = datos(100_000)
            val o = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 50_000)
            val s = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(o), s)
            reg.esperar { it is MusaEvento.Liberado }
            val g = rep.generacion
            igual(0, reg.cuenta(g, MusaEvento.Terminado::class.java))
            igual(1, reg.cuenta(g, MusaEvento.Falla::class.java))
            val f = reg.eventos.filterIsInstance<MusaEvento.Falla>().single()
            igual(MusaCausa.RED_TRANSITORIA, f.causa)
            afirma(f.reintentable)
            afirma(s.bytes.contentEquals(d.copyOf(s.bytes.size)) && s.bytes.size <= 50_000, "prefijo integro")
            afirma(!reg.eventos.joinToString().contains("secreto"), "ningun mensaje de origen en eventos")
            igual(1, s.liberaciones.get())
            afirma(o.cerrado)
            igual(f, rep.estadoTerminal)
        }
    }
    Runner.prueba("ciclo: fallo de la salida de audio es SALIDA_AUDIO y libera") {
        conMotor { _, reg, motor ->
            val o = OrigenSimulado(datos(20_000))
            val rep = motor.abrir(fuenteDe(o), SalidaQueFalla())
            reg.esperar { it is MusaEvento.Liberado }
            val f = reg.eventos.filterIsInstance<MusaEvento.Falla>().single()
            igual(MusaCausa.SALIDA_AUDIO, f.causa)
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
            afirma(!reg.eventos.joinToString().contains("secreto"))
            afirma(o.cerrado)
        }
    }
    Runner.prueba("ciclo: pausa y reanudacion emiten Pausado y Sonando, y los datos no avanzan en pausa") {
        conMotor { _, reg, motor ->
            val d = datos(60_000)
            val o = OrigenSimulado(d, maxPorLlamada = 4096)
            val s = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(o), s, iniciarSonando = false)
            reg.esperar { it is MusaEvento.Pausado }
            igual(listOf("Cargando", "Listo", "Pausado"), reg.nombres(rep.generacion))
            Thread.sleep(250)
            afirma(s.bytes.size <= 4096, "en pausa solo el primer trozo: ${s.bytes.size}")
            rep.play()
            reg.esperar { it is MusaEvento.Sonando }
            rep.pause()
            rep.play()
            reg.esperar { it is MusaEvento.Terminado }
            afirma(s.bytes.contentEquals(d))
            igual(1, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
        }
    }
}

private fun pruebasCambios() {
    Runner.prueba("cambio rapido de pista: solo la ultima generacion llega al final y las viejas no emiten sobre la nueva") {
        conMotor { _, reg, motor ->
            val origenes = ArrayList<OrigenSimulado>()
            val salidas = ArrayList<SalidaRegistro>()
            val total = 25
            for (i in 1 until total) {
                val o = OrigenSimulado(datos(40_000, i.toLong()), maxPorLlamada = 4096)
                o.liberarHasta(if (i % 2 == 0) 0 else 4096)
                origenes += o
                val s = SalidaRegistro()
                salidas += s
                motor.abrir(fuenteDe(o), s)
            }
            val ultimo = datos(40_000, 999)
            val oUlt = OrigenSimulado(ultimo, maxPorLlamada = 4096)
            val sUlt = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(oUlt), sUlt)
            reg.esperar { it is MusaEvento.Terminado && it.generacion == rep.generacion }
            reg.esperar { it is MusaEvento.Liberado && it.generacion == rep.generacion }
            igual(total.toLong(), rep.generacion)
            var maxima = 0L
            for (e in reg.eventos) {
                afirma(e.generacion >= maxima, "evento de generacion vieja ${e.generacion} tras $maxima")
                maxima = e.generacion
            }
            for (g in 1L until total) {
                igual(0, reg.cuenta(g, MusaEvento.Terminado::class.java), "gen $g no termina")
                igual(1, reg.cuenta(g, MusaEvento.Liberado::class.java), "gen $g libera una vez")
            }
            for (l in reg.eventos.withIndex().filter { it.value is MusaEvento.Liberado }) {
                val sig = reg.eventos.withIndex().firstOrNull {
                    it.value.generacion == l.value.generacion + 1 && it.value is MusaEvento.Cargando
                }
                afirma(sig == null || sig.index > l.index, "la pista siguiente no empieza antes de liberar la anterior")
            }
            afirma(sUlt.bytes.contentEquals(ultimo))
            afirma(origenes.all { it.cerrado }, "todos los origenes cerrados")
            afirma(salidas.all { it.liberaciones.get() == 1 }, "cada salida liberada una vez")
            esperarHasta { hilosVivos("musa-reproduccion") == 0 && hilosVivos("transferencia-bytes") == 0 }
        }
    }
    Runner.prueba("cambio en vivo audio->video y video->audio: misma pista, otra fuente, generacion nueva sin fugas") {
        conMotor { _, reg, motor ->
            val a = datos(80_000, 1)
            val v = datos(90_000, 2)
            val oA = OrigenSimulado(a, maxPorLlamada = 4096)
            oA.liberarHasta(4096)
            val sA = SalidaRegistro()
            val r1 = motor.abrir(fuenteDe(oA, infoFlac), sA)
            reg.esperar { it is MusaEvento.Sonando }
            val oV = OrigenSimulado(v, maxPorLlamada = 4096)
            oV.liberarHasta(4096)
            val sV = SalidaRegistro()
            val r2 = motor.abrir(fuenteDe(oV, infoVideo), sV, MusaMotivo.MISMA_PISTA_OTRA_FUENTE)
            afirma(r2.generacion == r1.generacion + 1)
            reg.esperar { it is MusaEvento.Liberado && it.generacion == r1.generacion }
            val c2 = reg.esperar { it is MusaEvento.Cargando && it.generacion == r2.generacion } as MusaEvento.Cargando
            igual(MusaMotivo.MISMA_PISTA_OTRA_FUENTE, c2.motivo)
            afirma(oA.cerrado && sA.liberaciones.get() == 1)
            val oA2 = OrigenSimulado(a, maxPorLlamada = 4096)
            val sA2 = SalidaRegistro()
            val r3 = motor.abrir(fuenteDe(oA2, infoFlac), sA2, MusaMotivo.MISMA_PISTA_OTRA_FUENTE, desdeByte = 10_000)
            reg.esperar { it is MusaEvento.Terminado && it.generacion == r3.generacion }
            reg.esperar { it is MusaEvento.Liberado && it.generacion == r3.generacion }
            igual(0, reg.cuenta(r2.generacion, MusaEvento.Terminado::class.java))
            afirma(oV.cerrado && sV.liberaciones.get() == 1)
            afirma(sA2.bytes.contentEquals(a.copyOfRange(10_000, a.size)), "reanuda desde el byte pedido")
            igual(infoVideo, sV.info)
            igual(0, reg.cuenta(r1.generacion, MusaEvento.Terminado::class.java))
            esperarHasta { hilosVivos("musa-reproduccion") == 0 }
        }
    }
    Runner.prueba("cambio de cancion tras cancelacion no confirmada: la nueva empieza y los eventos tardios viejos se descartan") {
        conMotor(cancelacionMs = 300) { _, reg, motor ->
            val bloqueada = SalidaRegistro(bloquearEscribir = true)
            val r1 = motor.abrir(fuenteDe(OrigenSimulado(datos(30_000), maxPorLlamada = 4096)), bloqueada)
            afirma(bloqueada.enEscritura.await(10, TimeUnit.SECONDS))
            val dB = datos(30_000, 7)
            val sB = SalidaRegistro()
            val r2 = motor.abrir(fuenteDe(OrigenSimulado(dB, maxPorLlamada = 4096)), sB)
            reg.esperar { it is MusaEvento.Terminado && it.generacion == r2.generacion }
            reg.esperar { it is MusaEvento.Liberado && it.generacion == r2.generacion }
            igual(1, reg.cuenta(r1.generacion, MusaEvento.Falla::class.java))
            val antes = reg.eventos.size
            bloqueada.soltar()
            esperarHasta { r1.liberadaPorCompleto }
            Thread.sleep(100)
            igual(antes, reg.eventos.size, "la generacion vieja no emite sobre la nueva")
            afirma(sB.bytes.contentEquals(dB))
            igual(1, bloqueada.liberaciones.get())
        }
    }
    Runner.prueba("cambio de cancion automatico: abrir la siguiente dentro del callback de Terminado no se bloquea") {
        val siguiente = AtomicInteger(0)
        val referencia = arrayOfNulls<MusaMotorAudio>(1)
        val dB = datos(30_000, 5)
        val sB = SalidaRegistro()
        conMotor(alRecibir = { e ->
            if (e is MusaEvento.Terminado && e.generacion == 1L && siguiente.compareAndSet(0, 1)) {
                referencia[0]!!.abrir(fuenteDe(OrigenSimulado(dB, maxPorLlamada = 4096)), sB)
            }
        }) { _, reg, motor ->
            referencia[0] = motor
            val sA = SalidaRegistro()
            motor.abrir(fuenteDe(OrigenSimulado(datos(30_000), maxPorLlamada = 4096)), sA)
            reg.esperar { it is MusaEvento.Liberado && it.generacion == 2L }
            igual(listOf("Cargando", "Listo", "Sonando", "Terminado", "Liberado"), reg.nombres(1))
            igual(listOf("Cargando", "Listo", "Sonando", "Terminado", "Liberado"), reg.nombres(2))
            val i1 = reg.eventos.indexOfFirst { it is MusaEvento.Liberado && it.generacion == 1L }
            val i2 = reg.eventos.indexOfFirst { it is MusaEvento.Cargando && it.generacion == 2L }
            afirma(i1 in 0 until i2, "la anterior se libera antes de empezar la siguiente")
            afirma(sB.bytes.contentEquals(dB))
            igual(1, sA.liberaciones.get())
        }
    }
    Runner.prueba("cerrar el motor cancela la reproduccion vigente") {
        conMotor { _, reg, motor ->
            val o = OrigenSimulado(datos(40_000), maxPorLlamada = 4096)
            o.liberarHasta(4096)
            val s = SalidaRegistro()
            val rep = motor.abrir(fuenteDe(o), s)
            reg.esperar { it is MusaEvento.Sonando }
            afirma(motor.cerrar())
            reg.esperar { it is MusaEvento.Liberado }
            afirma(o.cerrado && s.liberaciones.get() == 1 && rep.liberadaPorCompleto)
            igual(0, reg.cuenta(rep.generacion, MusaEvento.Terminado::class.java))
        }
    }
}
