package org.wiss.motor.bytes

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

enum class MusaMotivo { PISTA_NUEVA, MISMA_PISTA_OTRA_FUENTE, REINTENTO }

sealed interface MusaEvento {
    val generacion: Long

    data class Cargando(override val generacion: Long, val motivo: MusaMotivo) : MusaEvento
    data class Listo(override val generacion: Long) : MusaEvento
    data class Sonando(override val generacion: Long, val posMs: Long) : MusaEvento
    data class Pausado(override val generacion: Long) : MusaEvento
    data class Terminado(override val generacion: Long) : MusaEvento
    data class Falla(override val generacion: Long, val causa: MusaCausa, val reintentable: Boolean) : MusaEvento
    data class Liberado(override val generacion: Long) : MusaEvento
}

fun interface MusaOyente {
    fun alEvento(evento: MusaEvento)
}

fun interface MusaOyenteErrorSalida {
    fun alError(causa: MusaCausa)
}

fun interface MusaEspera {
    fun esperar(ms: Long)
}

interface MusaSalida {
    fun establecerOyenteError(oyente: MusaOyenteErrorSalida) {}

    fun abrir(info: MusaInfoMedio)
    fun escribir(buffer: ByteArray, desde: Int, len: Int)
    fun drenar()
    fun pausar()
    fun reanudar()
    fun posicionMs(): Long
    fun abortar()
    fun liberar()
}

class MusaConfigMotor(
    val chunk: Int = 64 * 1024,
    val timeoutLecturaMs: Long = 200,
    val estancadoMs: Long = 30_000,
    val cancelacionMs: Long = 3_000,
    val reintentosMax: Int = 2,
    val esperaLimiteTasaMs: Long = 2_000,
    val ventanaAdelanteBytes: Long = 16L * 1024 * 1024,
    val espera: MusaEspera? = null,
) {
    init {
        require(chunk > 0 && timeoutLecturaMs > 0 && estancadoMs > 0 && cancelacionMs > 0) { "configuracion" }
        require(reintentosMax >= 0 && esperaLimiteTasaMs >= 0 && ventanaAdelanteBytes >= 0) { "configuracion" }
    }
}

private class MusaFallaInterna(val causa: MusaCausa) : Exception()

private class MusaFallaFuente(val causa: MusaCausa) : Exception()

class MusaReproduccion internal constructor(
    val generacion: Long,
    val motivo: MusaMotivo,
    private val motor: MusaMotorAudio,
    fuenteInicial: MusaFuenteAudio,
    private val salida: MusaSalida,
    private val almacen: SegmentStore,
    private val config: MusaConfigMotor,
    private val desdeByte: Long,
    iniciarSonando: Boolean,
) {
    private val cerrojo = ReentrantLock()
    private val cambio = cerrojo.newCondition()
    private val cancelada = AtomicBoolean(false)
    private val terminal = AtomicReference<MusaEvento?>(null)
    private val errorSalida = AtomicReference<MusaCausa?>(null)
    private val acuseEmitido = AtomicBoolean(false)
    private val liberado = CountDownLatch(1)
    private val confirmado = CountDownLatch(1)
    private var pausada = !iniciarSonando
    private var listo = false

    @Volatile
    private var fuente: MusaFuenteAudio = fuenteInicial

    @Volatile
    private var posicion: Long = desdeByte

    private var itemActual: ItemCache? = null
    private var generacionItem: Long = 0
    private var itemsAbiertos = 0

    @Volatile
    private var hilo: Thread? = null

    val terminada: Boolean get() = terminal.get() != null

    val estadoTerminal: MusaEvento? get() = terminal.get()

    val liberadaPorCompleto: Boolean get() = liberado.count == 0L

    internal fun arrancar() {
        val h = Thread({ ejecutar() }, "musa-reproduccion-$generacion")
        h.isDaemon = true
        hilo = h
        h.start()
    }

    fun play() {
        var emitir = false
        cerrojo.withLock {
            if (pausada && !cancelada.get() && terminal.get() == null) {
                pausada = false
                salida.reanudar()
                cambio.signalAll()
                emitir = listo
            }
        }
        if (emitir) motor.emitir(this, MusaEvento.Sonando(generacion, salida.posicionMs()))
    }

    fun pause() {
        var emitir = false
        cerrojo.withLock {
            if (!pausada && !cancelada.get() && terminal.get() == null) {
                pausada = true
                salida.pausar()
                emitir = listo
            }
        }
        if (emitir) motor.emitir(this, MusaEvento.Pausado(generacion))
    }

    fun cancelar(timeoutMs: Long = config.cancelacionMs): Boolean {
        if (!cancelada.getAndSet(true)) {
            try {
                fuente.cancelar()
            } catch (_: Exception) {
            }
            try {
                salida.abortar()
            } catch (_: Exception) {
            }
            cerrojo.withLock { cambio.signalAll() }
        }
        if (Thread.currentThread() === hilo) return liberado.count == 0L
        val ok = confirmado.await(timeoutMs, TimeUnit.MILLISECONDS)
        if (!ok) emitirTerminal(MusaEvento.Falla(generacion, MusaCausa.CANCELACION_NO_CONFIRMADA, false))
        return ok
    }

    internal fun emitirAcuse() {
        if (liberado.count == 0L && acuseEmitido.compareAndSet(false, true)) {
            motor.emitir(this, MusaEvento.Liberado(generacion))
        }
    }

    private fun emitirTerminal(evento: MusaEvento) {
        if (terminal.compareAndSet(null, evento)) motor.emitir(this, evento)
    }

    private fun alErrorSalida(causa: MusaCausa) {
        errorSalida.compareAndSet(null, causa)
        cerrojo.withLock { cambio.signalAll() }
    }

    private fun ejecutar() {
        var causa: MusaCausa? = null
        var finNormal = false
        try {
            motor.emitir(this, MusaEvento.Cargando(generacion, motivo))
            enSalida { salida.establecerOyenteError { alErrorSalida(it) } }
            enSalida { salida.abrir(fuente.info) }
            if (pausada) enSalida { salida.pausar() }
            causa = reproducirConReintentos()
            if (causa == null) {
                comprobarCancelacion()
                enSalida { salida.drenar() }
                comprobarCancelacion()
                finNormal = true
            }
        } catch (_: CancelacionException) {
            causa = null
        } catch (f: MusaFallaInterna) {
            causa = f.causa
        } catch (_: Exception) {
            causa = if (cancelada.get()) null else (fuente.causa ?: MusaCausa.DESCONOCIDA)
        } finally {
            liberarFinal()
        }
        liberado.countDown()
        when {
            finNormal -> emitirTerminal(MusaEvento.Terminado(generacion))
            causa != null -> emitirTerminal(MusaEvento.Falla(generacion, causa, causa.reintentable))
        }
        emitirAcuse()
        confirmado.countDown()
    }

    private fun reproducirConReintentos(): MusaCausa? {
        var reintentos = 0
        while (true) {
            val causa = intentar() ?: return null
            comprobarCancelacion()
            if (!causa.reintentable || reintentos >= config.reintentosMax) return causa
            if (causa == MusaCausa.LIMITE_TASA && config.esperaLimiteTasaMs > 0) {
                esperarCancelable(config.esperaLimiteTasaMs)
            }
            comprobarCancelacion()
            val nueva = fuente.reabrir(posicion, causa) ?: return causa
            reintentos++
            cambiarFuente(nueva)
            comprobarCancelacion()
            motor.emitir(this, MusaEvento.Cargando(generacion, MusaMotivo.REINTENTO))
        }
    }

    private fun cambiarFuente(nueva: MusaFuenteAudio) {
        val vieja = fuente
        fuente = nueva
        if (cancelada.get()) {
            try {
                nueva.cancelar()
            } catch (_: Exception) {
            }
        }
        try {
            vieja.close()
        } catch (_: Exception) {
        }
        if (itemActual != null && nueva.generacionFuente != generacionItem) descartarItem()
    }

    private fun descartarItem() {
        val item = itemActual ?: return
        itemActual = null
        try {
            item.close()
        } catch (_: Exception) {
        }
        almacen.descartarEfimero(item)
    }

    private fun abrirItem(f: MusaFuenteAudio): ItemCache {
        itemActual?.let { return it }
        val clave = if (itemsAbiertos == 0) "musa-$generacion" else "musa-$generacion-$itemsAbiertos"
        itemsAbiertos++
        val item = almacen.abrir(clave, Retencion.EFIMERO)
        item.fijarInicioUtil(posicion)
        itemActual = item
        generacionItem = f.generacionFuente
        return item
    }

    private fun intentar(): MusaCausa? {
        val f = fuente
        var lector: PlaybackReader? = null
        var transferencia: Transferencia? = null
        try {
            if (f.info.local) {
                bombearLocal(f)
            } else {
                val item = abrirItem(f)
                transferencia = item.asegurarTransferencia(
                    config.chunk, posicion, config.ventanaAdelanteBytes, true,
                ) { f }
                lector = item.lector(config.timeoutLecturaMs)
                bombearRemoto(lector, f)
            }
            return null
        } catch (c: CancelacionException) {
            throw c
        } catch (e: MusaFallaInterna) {
            throw e
        } catch (e: MusaFallaFuente) {
            return e.causa
        } catch (_: Exception) {
            if (cancelada.get()) throw CancelacionException()
            return f.causa ?: MusaCausa.DESCONOCIDA
        } finally {
            liberarIntento(lector, transferencia, f)
        }
    }

    private fun liberarIntento(lector: PlaybackReader?, transferencia: Transferencia?, f: MusaFuenteAudio) {
        try {
            lector?.close()
        } catch (_: Exception) {
        }
        try {
            transferencia?.cancelar()
            f.cancelar()
        } catch (_: Exception) {
        }
        if (transferencia != null) {
            var fin = transferencia.esperar(50)
            while (!fin) fin = transferencia.esperar(50)
        }
    }

    private fun liberarFinal() {
        try {
            salida.abortar()
        } catch (_: Exception) {
        }
        descartarItem()
        try {
            fuente.close()
        } catch (_: Exception) {
        }
        try {
            salida.liberar()
        } catch (_: Exception) {
        }
    }

    private fun enSalida(bloque: () -> Unit) {
        try {
            bloque()
        } catch (c: CancelacionException) {
            throw c
        } catch (_: Exception) {
            if (cancelada.get()) throw CancelacionException()
            throw MusaFallaInterna(MusaCausa.SALIDA_AUDIO)
        }
    }

    private fun comprobarCancelacion() {
        if (cancelada.get()) throw CancelacionException()
        errorSalida.get()?.let { throw MusaFallaInterna(it) }
    }

    private fun comprobarGeneracion(f: MusaFuenteAudio) {
        if (f.generacionFuente != generacionItem) throw MusaFallaFuente(MusaCausa.ENLACE_EXPIRADO)
    }

    private fun esperarCancelable(ms: Long) {
        val inyectada = config.espera
        if (inyectada != null) {
            inyectada.esperar(ms)
            return
        }
        val limite = System.nanoTime() + ms * 1_000_000
        cerrojo.withLock {
            while (!cancelada.get()) {
                val resto = limite - System.nanoTime()
                if (resto <= 0) break
                cambio.awaitNanos(resto)
            }
        }
    }

    private fun alPrimerByte() {
        val emitirSonando: Boolean
        cerrojo.withLock {
            listo = true
            emitirSonando = !pausada
        }
        motor.emitir(this, MusaEvento.Listo(generacion))
        if (emitirSonando) {
            motor.emitir(this, MusaEvento.Sonando(generacion, salida.posicionMs()))
        } else {
            motor.emitir(this, MusaEvento.Pausado(generacion))
        }
    }

    private fun esperarSiPausada() {
        cerrojo.withLock {
            while (pausada && !cancelada.get() && errorSalida.get() == null) cambio.await(100, TimeUnit.MILLISECONDS)
        }
    }

    private fun entregar(buf: ByteArray, n: Int, primero: Boolean, remota: MusaFuenteAudio?) {
        if (!primero) esperarSiPausada()
        comprobarCancelacion()
        if (remota != null) comprobarGeneracion(remota)
        enSalida { salida.escribir(buf, 0, n) }
        posicion += n
        if (primero) alPrimerByte()
    }

    private fun bombearLocal(f: MusaFuenteAudio) {
        val buf = ByteArray(config.chunk)
        var primero = true
        while (true) {
            comprobarCancelacion()
            val n = f.leer(posicion, buf, 0, buf.size)
            if (n < 0) return
            if (n == 0) continue
            entregar(buf, n, primero, null)
            primero = false
        }
    }

    private fun bombearRemoto(lector: PlaybackReader, f: MusaFuenteAudio) {
        val buf = ByteArray(config.chunk)
        var primero = true
        var esperadoMs = 0L
        while (true) {
            comprobarCancelacion()
            comprobarGeneracion(f)
            when (val r = lector.leer(posicion, buf, 0, buf.size)) {
                is ResultadoLectura.Bytes -> {
                    if (r.n == 0) continue
                    esperadoMs = 0
                    entregar(buf, r.n, primero, f)
                    primero = false
                }
                ResultadoLectura.Faltan -> {
                    esperadoMs += config.timeoutLecturaMs
                    if (esperadoMs >= config.estancadoMs) throw MusaFallaInterna(MusaCausa.DATOS_INSUFICIENTES)
                }
                ResultadoLectura.Eof -> return
                is ResultadoLectura.Error -> throw MusaFallaFuente(f.causa ?: MusaCausa.DESCONOCIDA)
                ResultadoLectura.Cancelado -> {
                    comprobarCancelacion()
                    throw MusaFallaFuente(f.causa ?: MusaCausa.DESCONOCIDA)
                }
            }
        }
    }

    override fun toString(): String = "MusaReproduccion(generacion=$generacion, terminal=${terminal.get()?.javaClass?.simpleName})"
}

class MusaMotorAudio(
    private val almacen: SegmentStore,
    private val oyente: MusaOyente,
    private val config: MusaConfigMotor = MusaConfigMotor(),
) {
    private val cerrojoAbrir = Any()
    private val cerrojoEventos = Any()
    private var ultimaGeneracion = 0L
    private var vigente: MusaReproduccion? = null
    private var generacionEmision = 0L

    fun abrir(
        fuente: MusaFuenteAudio,
        salida: MusaSalida,
        motivo: MusaMotivo = MusaMotivo.PISTA_NUEVA,
        desdeByte: Long = 0,
        iniciarSonando: Boolean = true,
    ): MusaReproduccion {
        require(desdeByte >= 0) { "desdeByte" }
        synchronized(cerrojoAbrir) {
            val anterior = vigente
            if (anterior != null) {
                anterior.cancelar(config.cancelacionMs)
                anterior.emitirAcuse()
            }
            val generacion = ++ultimaGeneracion
            val nueva = MusaReproduccion(
                generacion, motivo, this, fuente, salida, almacen, config, desdeByte, iniciarSonando,
            )
            synchronized(cerrojoEventos) { generacionEmision = generacion }
            vigente = nueva
            nueva.arrancar()
            return nueva
        }
    }

    fun cerrar(): Boolean {
        synchronized(cerrojoAbrir) {
            val actual = vigente ?: return true
            val ok = actual.cancelar(config.cancelacionMs)
            actual.emitirAcuse()
            return ok
        }
    }

    internal fun emitir(origen: MusaReproduccion, evento: MusaEvento) {
        synchronized(cerrojoEventos) {
            if (origen.generacion != generacionEmision) return
            oyente.alEvento(evento)
        }
    }
}
