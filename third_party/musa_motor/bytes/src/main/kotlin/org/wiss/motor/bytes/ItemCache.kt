package org.wiss.motor.bytes

import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import java.util.function.BooleanSupplier
import kotlin.concurrent.withLock

/**
 * Cache de UN item (una pista) con huecos. Toda mutacion/lectura ocurre bajo un unico lock;
 * los lectores esperan en una Condition (sin sondeo con sleep).
 *
 * Almacenamiento: un archivo sparse. EFIMERO -> archivo en el directorio efimero del store
 * (nombre sin relacion con la clave). PERSISTENTE -> `<rutaFinal>.part` directamente junto a
 * su destino, de modo que finalizar es un unico rename atomico (sin staging ni copias).
 *
 * Los handles se obtienen con [SegmentStore.abrir] y hay que cerrarlos ([close]); mientras
 * haya algun handle abierto el item no se purga.
 */
class ItemCache internal constructor(
    private val store: SegmentStore,
    internal val clave: String,
    id: Long,
    retencionInicial: Retencion,
    rutaFinalInicial: Path?,
) : AutoCloseable {
    private val lock = ReentrantLock()
    private val cambio = lock.newCondition()
    private val rangos = RangeSet()

    private var raf: RandomAccessFile? = null
    private var archivo: Path
    private var rutaFinal: Path? = rutaFinalInicial
    private var retencionActual: Retencion = retencionInicial
    private var tam: Long = -1
    private var estadoActual: EstadoOrigen = EstadoOrigen.EN_CURSO
    private var causa: String? = null
    private var yaFinalizado = false
    private var yaDescartado = false
    private var transferencia: Transferencia? = null
    private var lecturaPos = 0L
    private var inicioUtil = 0L

    internal val pins = AtomicInteger(0)

    @Volatile
    private var bytesVol: Long = 0

    @Volatile
    internal var ultimoUso: Long = 0

    /** Hook que registra la [Transferencia] activa para pedir rangos prioritarios (seek). */
    @Volatile
    internal var priorizador: ((Long) -> Unit)? = null

    init {
        archivo = if (retencionInicial == Retencion.EFIMERO) {
            store.dirEfimero.resolve("e-$id.bin")
        } else {
            parteDe(rutaFinalInicial!!)
        }
    }

    // ------------------------------------------------------------------ consultas

    val retencion: Retencion get() = lock.withLock { retencionActual }
    val estado: EstadoOrigen get() = lock.withLock { estadoActual }
    val tamano: Long get() = lock.withLock { tam }
    val bytesRecibidos: Long get() = bytesVol
    val finalizado: Boolean get() = lock.withLock { yaFinalizado }
    val descartado: Boolean get() = lock.withLock { yaDescartado }

    /** Tipo (clase) de la causa del ultimo ERROR, sin mensaje. */
    val causaError: String? get() = lock.withLock { causa }

    /** Rangos [inicio, fin) ya recibidos (copia). */
    fun rangosRecibidos(): List<LongArray> = lock.withLock { rangos.copia() }

    internal fun bytesEfimeros(): Long = if (retencionNoLock() == Retencion.EFIMERO) bytesVol else 0

    private fun retencionNoLock(): Retencion = retencionActual // lectura benigna (solo estadisticas)

    // ------------------------------------------------------------------ escritura

    /** Fija el tamano total (una vez conocido). Despierta a los lectores que esperaban pasado el fin. */
    fun fijarTamano(total: Long) {
        require(total >= 0) { "tamano negativo" }
        lock.withLock {
            if (yaDescartado) return
            check(tam < 0 || tam == total) { "tamano incoherente" }
            check(rangos.ultimoFin() <= total) { "hay bytes mas alla del tamano" }
            tam = total
            cambio.signalAll()
        }
    }

    /** Escribe [len] bytes de [src] en [offset]. Idempotente para rangos repetidos. Seguro entre hilos. */
    fun escribir(offset: Long, src: ByteArray, desde: Int, len: Int) {
        require(offset >= 0 && len >= 0 && desde >= 0 && desde + len <= src.size) { "argumentos" }
        if (len == 0) return
        lock.withLock {
            if (yaDescartado || yaFinalizado || estadoActual != EstadoOrigen.EN_CURSO) return
            require(tam < 0 || offset + len <= tam) { "escritura mas alla del tamano" }
            val f = archivoRw()
            f.seek(offset)
            f.write(src, desde, len)
            rangos.add(offset, offset + len)
            bytesVol = rangos.total
            ultimoUso = store.tick()
            cambio.signalAll()
        }
        if (retencion == Retencion.EFIMERO) store.purgarEfimero()
    }

    /**
     * Marca el estado terminal. COMPLETO exige cobertura total; si el item es PERSISTENTE se
     * finaliza aqui mismo (UNICO punto de finalizacion).
     */
    fun terminar(nuevo: EstadoOrigen, tipoCausa: String? = null) {
        require(nuevo.terminal) { "estado no terminal" }
        lock.withLock {
            if (yaDescartado || yaFinalizado || estadoActual != EstadoOrigen.EN_CURSO) return
            if (nuevo == EstadoOrigen.COMPLETO) {
                if (tam < 0) tam = rangos.ultimoFin()
                if (!rangos.cubre(inicioUtil, tam)) {
                    estadoActual = EstadoOrigen.ERROR
                    causa = "Incompleto"
                } else {
                    estadoActual = EstadoOrigen.COMPLETO
                    if (retencionActual == Retencion.PERSISTENTE) finalizarLocked()
                }
            } else {
                estadoActual = nuevo
                causa = tipoCausa
            }
            if (retencionActual == Retencion.PERSISTENTE && !yaFinalizado) guardarSidecarLocked()
            cambio.signalAll()
        }
    }

    /** Permite reintentar tras ERROR/CANCELADO conservando lo ya recibido. */
    fun reanudar(): Boolean = lock.withLock { reanudarLocked() }

    private fun reanudarLocked(): Boolean {
        if (yaDescartado || yaFinalizado) return false
        if (estadoActual == EstadoOrigen.ERROR || estadoActual == EstadoOrigen.CANCELADO) {
            estadoActual = EstadoOrigen.EN_CURSO
            causa = null
        }
        return estadoActual == EstadoOrigen.EN_CURSO
    }

    // ------------------------------------------------------------------ promocion y finalizacion

    /**
     * EFIMERO -> PERSISTENTE sin reiniciar la transferencia: el archivo ya recibido se MUEVE a
     * `<ruta>.part` (rename; no se vuelve a pedir nada). Si ya estaba completo, finaliza.
     */
    fun promover(ruta: Path) {
        lock.withLock {
            check(!yaDescartado) { "item descartado" }
            if (retencionActual == Retencion.PERSISTENTE) {
                check(rutaFinal == ruta) { "ya es persistente en otra ruta" }
                return
            }
            archivoRw() // garantiza que exista (item vacio / tamano 0)
            cerrarArchivoLocked()
            val destino = parteDe(ruta)
            destino.parent?.let { Files.createDirectories(it) }
            Files.move(archivo, destino, StandardCopyOption.REPLACE_EXISTING)
            archivo = destino
            rutaFinal = ruta
            retencionActual = Retencion.PERSISTENTE
            if (estadoActual == EstadoOrigen.COMPLETO) finalizarLocked() else guardarSidecarLocked()
            cambio.signalAll()
        }
    }

    /** Unico lugar donde se finaliza: verifica tamano y hace rename atomico part -> ruta final. */
    private fun finalizarLocked() {
        val destino = checkNotNull(rutaFinal)
        try {
            val f = archivoRw()
            f.fd.sync()
            if (f.length() != tam) {
                estadoActual = EstadoOrigen.ERROR
                causa = "TamanoIncorrecto"
                return
            }
            cerrarArchivoLocked()
            try {
                Files.move(archivo, destino, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(archivo, destino, StandardCopyOption.REPLACE_EXISTING)
            }
            Files.deleteIfExists(sidecarDe(destino))
            archivo = destino
            yaFinalizado = true
        } catch (e: IOException) {
            estadoActual = EstadoOrigen.ERROR
            causa = e.javaClass.simpleName
        }
    }

    // ------------------------------------------------------------------ lectura (reproductor)

    /** Despierta a los lectores bloqueados (para cancelacion de un [PlaybackReader]). */
    internal fun despertar() = lock.withLock { cambio.signalAll() }

    /**
     * Lee hasta [len] bytes desde [offset]. Semantica de lectura parcial: devuelve lo contiguo que
     * haya (>= 1 byte) en cuanto exista. Si no hay nada: espera por condicion hasta [timeoutNs];
     * al agotarse -> [ResultadoLectura.Faltan]. Si el hueco no llegara solo, pide ese offset de
     * forma prioritaria a la transferencia (seek), si el origen lo permite.
     */
    internal fun leer(
        offset: Long,
        destino: ByteArray,
        desde: Int,
        len: Int,
        timeoutNs: Long,
        cancelado: BooleanSupplier,
    ): ResultadoLectura {
        require(offset >= 0 && len >= 0 && desde >= 0 && desde + len <= destino.size) { "argumentos" }
        val limite = System.nanoTime() + timeoutNs
        var prioridadPedida = false
        lock.lock()
        try {
            if (lecturaPos != offset) {
                lecturaPos = offset
                cambio.signalAll()
            }
            while (true) {
                if (yaDescartado || cancelado.asBoolean) return ResultadoLectura.Cancelado
                if (tam >= 0 && offset >= tam) return ResultadoLectura.Eof
                if (len == 0) return ResultadoLectura.Bytes(0)
                val fin = rangos.finContiguo(offset)
                if (fin > offset) {
                    val n = minOf(len.toLong(), fin - offset).toInt()
                    val f = archivoLectura()
                    f.seek(offset)
                    f.readFully(destino, desde, n)
                    ultimoUso = store.tick()
                    lecturaPos = offset + n
                    cambio.signalAll()
                    return ResultadoLectura.Bytes(n)
                }
                when (estadoActual) {
                    EstadoOrigen.COMPLETO -> return if (tam in 0..offset) ResultadoLectura.Eof
                    else ResultadoLectura.Error("Incompleto")
                    EstadoOrigen.ERROR -> return ResultadoLectura.Error(causa ?: "Error")
                    EstadoOrigen.CANCELADO -> return ResultadoLectura.Cancelado
                    EstadoOrigen.EN_CURSO -> Unit
                }
                if (!prioridadPedida) {
                    prioridadPedida = true
                    priorizador?.invoke(offset)
                }
                val restante = limite - System.nanoTime()
                if (restante <= 0) return ResultadoLectura.Faltan
                try {
                    cambio.awaitNanos(restante)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return ResultadoLectura.Cancelado
                }
            }
        } catch (e: IOException) {
            return ResultadoLectura.Error(e.javaClass.simpleName)
        } finally {
            lock.unlock()
        }
    }

    /** Espera (por condicion) a tener al menos [minimo] bytes recibidos o un estado terminal. */
    fun esperarRecibidos(minimo: Long, timeoutMs: Long): Boolean {
        val limite = System.nanoTime() + timeoutMs * 1_000_000
        lock.withLock {
            while (rangos.total < minimo) {
                if (yaDescartado || estadoActual != EstadoOrigen.EN_CURSO) return false
                val restante = limite - System.nanoTime()
                if (restante <= 0) return false
                cambio.awaitNanos(restante)
            }
            return true
        }
    }

    /** Espera a un estado terminal (o descarte). true si se alcanzo antes del timeout. */
    fun esperarTerminal(timeoutMs: Long): Boolean {
        val limite = System.nanoTime() + timeoutMs * 1_000_000
        lock.withLock {
            while (estadoActual == EstadoOrigen.EN_CURSO && !yaDescartado) {
                val restante = limite - System.nanoTime()
                if (restante <= 0) return false
                cambio.awaitNanos(restante)
            }
            return true
        }
    }

    // ------------------------------------------------------------------ ayudas del bombeo

    /** Primer byte faltante desde [desde] (con vuelta a 0); -1 si no falta nada (tamano conocido). */
    internal fun primerHuecoDesde(desde: Long): Long = lock.withLock {
        var p = rangos.primerHuecoDesde(desde)
        if (tam >= 0 && p >= tam) {
            p = rangos.primerHuecoDesde(0)
            if (p >= tam) return -1
        }
        p
    }

    /** Primer byte faltante desde [desde] sin dar la vuelta a 0; -1 si no falta nada hacia delante (tamano conocido). */
    internal fun primerHuecoAdelante(desde: Long): Long = lock.withLock {
        val p = rangos.primerHuecoDesde(desde)
        if (tam >= 0 && p >= tam) -1 else p
    }

    /** Bytes anteriores a [desde] no se necesitan: el item se considera completo sin ellos. */
    internal fun fijarInicioUtil(desde: Long) {
        require(desde >= 0) { "inicio" }
        lock.withLock { inicioUtil = desde }
    }

    /**
     * Contrapresion: bloquea (por condicion) mientras [pos] este a [ventana] bytes o mas por delante de
     * la posicion de lectura, salvo cancelacion, salto pedido ([interrumpir]), descarte o estado terminal.
     */
    internal fun esperarVentana(pos: Long, ventana: Long, interrumpir: () -> Boolean) {
        lock.withLock {
            while (!yaDescartado && estadoActual == EstadoOrigen.EN_CURSO &&
                pos - lecturaPos >= ventana && !interrumpir()
            ) {
                try {
                    cambio.await()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
            }
        }
    }

    /** Hasta donde se puede pedir desde [pos] sin repetir bytes ya recibidos. */
    internal fun limiteDesde(pos: Long): Long = lock.withLock {
        val tope = if (tam >= 0) tam else Long.MAX_VALUE
        minOf(tope, rangos.siguienteInicio(pos) ?: Long.MAX_VALUE)
    }

    /**
     * Devuelve la transferencia activa o arranca una nueva con el origen que fabrique [fabrica]
     * (se invoca bajo el lock del item: debe ser barata). null si el item ya esta completo y no
     * hay nada que pedir. Reanuda tras ERROR/CANCELADO pidiendo SOLO los huecos.
     */
    fun asegurarTransferencia(
        chunk: Int = 64 * 1024,
        desde: Long = 0,
        ventanaAdelanteBytes: Long = 0,
        soloAdelante: Boolean = false,
        fabrica: () -> ByteSource,
    ): Transferencia? {
        require(desde >= 0 && ventanaAdelanteBytes >= 0) { "argumentos" }
        lock.withLock {
            check(!yaDescartado) { "item descartado" }
            val actual = transferencia
            if (actual != null && actual.activa) return actual
            if (yaFinalizado || estadoActual == EstadoOrigen.COMPLETO) return null
            reanudarLocked()
            if (desde > lecturaPos) lecturaPos = desde
            val nueva = Transferencia(this, fabrica(), chunk, desde, ventanaAdelanteBytes, soloAdelante)
            transferencia = nueva
            pins.incrementAndGet()
            nueva.arrancar()
            return nueva
        }
    }

    internal fun transferenciaTerminada(t: Transferencia) {
        lock.withLock {
            if (transferencia === t) {
                priorizador = null
                transferencia = null
            }
        }
        close()
    }

    /** Un lector de reproductor sobre este item. Cerrarlo al terminar. */
    fun lector(timeoutMs: Long = 10_000): PlaybackReader = PlaybackReader(this, timeoutMs)

    // ------------------------------------------------------------------ ciclo de vida

    internal fun adquirir() {
        pins.incrementAndGet()
    }

    override fun close() {
        if (pins.decrementAndGet() == 0) lock.withLock { cerrarArchivoLocked() }
        store.liberado(this)
    }

    /** Solo EFIMERO y sin handles abiertos. Borra el archivo. Llamado por el store (purga LRU). */
    internal fun descartarSiLibre(): Boolean = lock.withLock {
        if (pins.get() > 0 || retencionActual != Retencion.EFIMERO || yaDescartado) return false
        borrarLocked()
        true
    }

    /** Descarte forzado (cierre del store). */
    internal fun descartarForzado() = lock.withLock {
        if (retencionActual == Retencion.EFIMERO && !yaDescartado) borrarLocked()
        else cerrarArchivoLocked()
    }

    private fun borrarLocked() {
        cerrarArchivoLocked()
        try {
            Files.deleteIfExists(archivo)
        } catch (_: IOException) {
        }
        yaDescartado = true
        estadoActual = EstadoOrigen.CANCELADO
        bytesVol = 0
        rangos.limpiar()
        cambio.signalAll()
    }

    /** Guarda el mapa de rangos de una descarga parcial para poder reanudar tras reiniciar. */
    internal fun persistirEstado() = lock.withLock {
        if (retencionActual == Retencion.PERSISTENTE && !yaFinalizado && !yaDescartado) guardarSidecarLocked()
    }

    internal val esPersistente: Boolean get() = lock.withLock { retencionActual == Retencion.PERSISTENTE }

    // ------------------------------------------------------------------ disco

    private fun archivoRw(): RandomAccessFile {
        raf?.let { return it }
        archivo.parent?.let { Files.createDirectories(it) }
        val f = RandomAccessFile(archivo.toFile(), "rw")
        raf = f
        return f
    }

    private fun archivoLectura(): RandomAccessFile {
        raf?.let { return it }
        val f = RandomAccessFile(archivo.toFile(), if (yaFinalizado) "r" else "rw")
        raf = f
        return f
    }

    private fun cerrarArchivoLocked() {
        try {
            raf?.close()
        } catch (_: IOException) {
        }
        raf = null
    }

    private fun guardarSidecarLocked() {
        val destino = rutaFinal ?: return
        try {
            if (!Files.exists(archivo)) return
            val sb = StringBuilder().append(tam).append('\n')
            for (r in rangos.copia()) sb.append(r[0]).append('-').append(r[1]).append('\n')
            Files.writeString(sidecarDe(destino), sb.toString())
        } catch (_: IOException) {
        }
    }

    /** Carga estado previo de disco (solo PERSISTENTE, justo tras crear el item, sin concurrencia). */
    internal fun cargarDeDisco(tamanoEsperado: Long) {
      lock.withLock {
        val destino = rutaFinal ?: return
        try {
            if (Files.isRegularFile(destino)) {
                val len = Files.size(destino)
                if (tamanoEsperado < 0 || len == tamanoEsperado) {
                    tam = len
                    rangos.add(0, len)
                    bytesVol = len
                    estadoActual = EstadoOrigen.COMPLETO
                    yaFinalizado = true
                    archivo = destino
                    return
                }
            }
            val parte = parteDe(destino)
            val side = sidecarDe(destino)
            if (Files.isRegularFile(parte) && Files.isRegularFile(side)) {
                val lineas = Files.readAllLines(side)
                val t = lineas[0].trim().toLong()
                val largo = Files.size(parte)
                val tmp = RangeSet()
                for (l in lineas.drop(1)) {
                    if (l.isBlank()) continue
                    val p = l.trim().split('-')
                    tmp.add(p[0].toLong(), p[1].toLong())
                }
                val coherente = tmp.ultimoFin() <= largo &&
                    (tamanoEsperado < 0 || t < 0 || t == tamanoEsperado)
                if (coherente) {
                    for (r in tmp.copia()) rangos.add(r[0], r[1])
                    bytesVol = rangos.total
                    if (t >= 0) tam = t
                }
            }
            if (tam < 0 && tamanoEsperado >= 0) tam = tamanoEsperado
        } catch (_: Exception) {
            rangos.limpiar()
            bytesVol = 0
        }
      }
    }

    override fun toString(): String =
        "ItemCache(estado=${estadoActual}, recibidos=${bytesVol}, pins=${pins.get()})"

    internal companion object {
        fun parteDe(ruta: Path): Path = ruta.resolveSibling(ruta.fileName.toString() + ".part")
        fun sidecarDe(ruta: Path): Path = ruta.resolveSibling(ruta.fileName.toString() + ".part.rng")
    }
}
