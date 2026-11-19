package org.wiss.motor.bytes

import java.nio.file.Files
import java.nio.file.Path
import java.util.Random
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Runner propio (no hay kotlin.test/JUnit en la cache offline). */
class FalloPrueba(mensaje: String) : AssertionError(mensaje)

fun afirma(cond: Boolean, msg: String = "afirmacion falsa") {
    if (!cond) throw FalloPrueba(msg)
}

fun <T> igual(esperado: T, real: T, msg: String = "") {
    if (esperado != real) throw FalloPrueba("$msg esperado=<$esperado> real=<$real>")
}

object Runner {
    class Resultado(val nombre: String, val ok: Boolean, val ms: Long, val detalle: String)

    val resultados = CopyOnWriteArrayList<Resultado>()

    fun prueba(nombre: String, timeoutMs: Long = 30_000, cuerpo: () -> Unit) {
        val t0 = System.nanoTime()
        var error: Throwable? = null
        val hilo = Thread({
            try {
                cuerpo()
            } catch (t: Throwable) {
                error = t
            }
        }, "prueba")
        hilo.isDaemon = true
        hilo.start()
        hilo.join(timeoutMs)
        val ms = (System.nanoTime() - t0) / 1_000_000
        val r = when {
            hilo.isAlive -> Resultado(nombre, false, ms, "TIMEOUT (${timeoutMs}ms): posible bloqueo")
            error != null -> Resultado(nombre, false, ms, "${error.javaClass.simpleName}: ${error.message}\n" +
                error.stackTrace.take(6).joinToString("\n") { "      at $it" })
            else -> Resultado(nombre, true, ms, "")
        }
        resultados += r
        println("${if (r.ok) "PASA " else "FALLA"} $nombre (${ms} ms)")
        if (!r.ok) println("      ${r.detalle}")
    }

    fun terminar(): Int {
        val fallos = resultados.count { !it.ok }
        println("----")
        println("Total: ${resultados.size}  Pasan: ${resultados.size - fallos}  Fallan: $fallos")
        return if (fallos == 0) 0 else 1
    }
}

// ---------------------------------------------------------------- utilidades de prueba

fun datos(n: Int, semilla: Long = 42): ByteArray = ByteArray(n).also { Random(semilla).nextBytes(it) }

fun <T> conTemp(bloque: (Path) -> T): T {
    val dir = Files.createTempDirectory("bytes-prueba-")
    try {
        return bloque(dir)
    } finally {
        dir.toFile().deleteRecursively()
    }
}

fun listar(dir: Path): List<String> =
    Files.list(dir).use { s -> s.map { it.fileName.toString() }.sorted().toList() }

/** Lee exactamente [len] bytes con el lector (bucle de lecturas parciales). */
fun leerExacto(lector: PlaybackReader, offset: Long, len: Int, timeoutMs: Long = 10_000): ByteArray {
    val out = ByteArray(len)
    var got = 0
    while (got < len) {
        when (val r = lector.leer(offset + got, out, got, len - got, timeoutMs)) {
            is ResultadoLectura.Bytes -> got += r.n
            else -> throw FalloPrueba("lectura exacta interrumpida en ${offset + got}: $r")
        }
    }
    return out
}

/**
 * Origen simulado. Cuenta peticiones (offset, bytes servidos). Puede pausarse con
 * [liberarHasta] (sirve solo offsets < limite) para pruebas deterministas sin sleeps.
 */
class OrigenSimulado(
    val contenido: ByteArray,
    override val admiteRangos: Boolean = true,
    private val tamanoConocido: Boolean = true,
    private val maxPorLlamada: Int = 4096,
    private val retardoMs: Long = 0,
    private val fallaEnOffset: Long = -1,
    private val finPrematuroEn: Long = -1,
) : ByteSource {
    private val lock = ReentrantLock()
    private val cond = lock.newCondition()
    private var limite: Long = Long.MAX_VALUE
    private var cancel = false
    private var cursorSecuencial = 0L

    /** (offset, bytes servidos) de cada llamada que sirvio algo. */
    val servidos = CopyOnWriteArrayList<LongArray>()

    @Volatile
    var llamadas = 0
        private set

    @Volatile
    var cerrado = false
        private set

    override val tamano: Long get() = if (tamanoConocido) contenido.size.toLong() else -1
    override val estado: EstadoOrigen
        get() = lock.withLock { if (cancel) EstadoOrigen.CANCELADO else EstadoOrigen.EN_CURSO }

    fun liberarHasta(n: Long) = lock.withLock {
        limite = n
        cond.signalAll()
    }

    val bytesServidos: Long get() = servidos.sumOf { it[1] }
    fun offsetMinimo(): Long = servidos.minOf { it[0] }

    override fun leer(offset: Long, destino: ByteArray, desde: Int, len: Int): Int {
        llamadas++
        lock.withLock {
            while (offset >= limite && !cancel) cond.await()
            if (cancel) throw CancelacionException()
        }
        if (!admiteRangos) {
            if (offset != cursorSecuencial) throw IllegalStateException("origen secuencial leido en $offset, cursor $cursorSecuencial")
        }
        if (retardoMs > 0) Thread.sleep(retardoMs) // SOLO simula un origen lento
        if (finPrematuroEn in 0..offset) return -1
        if (offset >= contenido.size) return -1
        if (fallaEnOffset in 0..offset) throw java.io.IOException("boom-secreto-token-123")
        var n = minOf(len, maxPorLlamada, contenido.size - offset.toInt())
        val lim = lock.withLock { limite }
        if (lim != Long.MAX_VALUE) n = minOf(n.toLong(), lim - offset).toInt()
        if (fallaEnOffset >= 0) n = minOf(n.toLong(), fallaEnOffset - offset).toInt()
        if (finPrematuroEn >= 0) n = minOf(n.toLong(), finPrematuroEn - offset).toInt()
        System.arraycopy(contenido, offset.toInt(), destino, desde, n)
        cursorSecuencial = offset + n
        servidos += longArrayOf(offset, n.toLong())
        return n
    }

    override fun cancelar() = lock.withLock {
        cancel = true
        cond.signalAll()
    }

    override fun close() {
        cerrado = true
    }
}

/** Comprueba que los servidos (de uno o varios origenes) cubren [0,size) sin repetir ningun byte. */
fun verificaSinRepetidos(size: Int, vararg origenes: OrigenSimulado) {
    val todos = origenes.flatMap { it.servidos }.sortedBy { it[0] }
    var fin = 0L
    for (s in todos) {
        afirma(s[0] == fin, "hueco o solape en ${s[0]} (esperado $fin)")
        fin = s[0] + s[1]
    }
    igual(size.toLong(), fin, "cobertura total")
}
