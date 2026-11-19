package org.wiss.motor.bytes

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicLong

/**
 * Cache por item con politicas de retencion. EFIMERO: directorio temporal propio, purga LRU con
 * tope de bytes. PERSISTENTE: el item vive en su ruta final. Un mismo item (clave) es unico:
 * abrirlo como PERSISTENTE cuando ya existe como EFIMERO lo PROMUEVE sin perder lo recibido.
 *
 * Orden de locks: store -> item (nunca al reves).
 */
class SegmentStore(
    internal val dirEfimero: Path,
    val topeBytesEfimero: Long,
) : AutoCloseable {
    private val storeLock = Any()
    private val items = HashMap<String, ItemCache>()
    private val ids = AtomicLong(0)
    private val reloj = AtomicLong(0)

    @Volatile
    var purgados: Int = 0
        private set

    init {
        require(topeBytesEfimero >= 0) { "tope negativo" }
        Files.createDirectories(dirEfimero)
        // El efimero es descartable: lo que quedo de una ejecucion anterior se borra.
        Files.newDirectoryStream(dirEfimero, "e-*.bin").use { ds ->
            for (p in ds) {
                try {
                    Files.deleteIfExists(p)
                } catch (_: IOException) {
                }
            }
        }
    }

    internal fun tick(): Long = reloj.incrementAndGet()

    /**
     * Abre (o crea) el item [clave]. El handle devuelto ya cuenta como "en uso": hay que cerrarlo.
     * [rutaFinal] es obligatoria para PERSISTENTE. [tamanoEsperado] (opcional) valida un archivo
     * final ya existente y el tamano de una parte reanudable.
     */
    fun abrir(
        clave: String,
        retencion: Retencion,
        rutaFinal: Path? = null,
        tamanoEsperado: Long = -1,
    ): ItemCache {
        require(retencion == Retencion.EFIMERO || rutaFinal != null) { "PERSISTENTE exige rutaFinal" }
        val item: ItemCache
        synchronized(storeLock) {
            val existente = items[clave]?.takeIf { !it.descartado }
            if (existente == null) {
                val nuevo = ItemCache(this, clave, ids.incrementAndGet(), retencion, rutaFinal)
                if (retencion == Retencion.PERSISTENTE) {
                    nuevo.cargarDeDisco(tamanoEsperado)
                } else if (tamanoEsperado >= 0) {
                    nuevo.fijarTamano(tamanoEsperado)
                }
                items[clave] = nuevo
                item = nuevo
            } else {
                if (retencion == Retencion.PERSISTENTE) existente.promover(rutaFinal!!)
                if (tamanoEsperado >= 0 && existente.tamano < 0) existente.fijarTamano(tamanoEsperado)
                item = existente
            }
            item.adquirir()
            item.ultimoUso = tick()
        }
        purgarEfimero()
        return item
    }

    /**
     * Purga LRU del efimero hasta quedar bajo el tope. Nunca toca items con handles abiertos o
     * persistentes (si todo esta en uso el tope puede excederse temporalmente).
     */
    fun purgarEfimero(): Int {
        synchronized(storeLock) {
            var total = items.values.sumOf { it.bytesEfimeros() }
            if (total <= topeBytesEfimero) return 0
            val candidatos = items.values
                .filter { !it.esPersistente && it.pins.get() == 0 }
                .sortedBy { it.ultimoUso }
            var n = 0
            for (c in candidatos) {
                if (total <= topeBytesEfimero) break
                val b = c.bytesEfimeros()
                if (c.descartarSiLibre()) {
                    items.remove(c.clave, c)
                    total -= b
                    n++
                }
            }
            purgados += n
            return n
        }
    }

    /** Descarta un item efimero ya sin handles (fin o cierre de la pista); si sigue en uso no hace nada. */
    internal fun descartarEfimero(item: ItemCache) {
        synchronized(storeLock) {
            if (item.descartarSiLibre()) items.remove(item.clave, item)
        }
    }

    /** Suma de bytes de items efimeros (en disco). */
    fun bytesEfimeros(): Long = synchronized(storeLock) { items.values.sumOf { it.bytesEfimeros() } }

    fun contiene(clave: String): Boolean = synchronized(storeLock) { items[clave]?.descartado == false }

    internal fun liberado(item: ItemCache) {
        if (item.pins.get() == 0 && item.esPersistente) {
            item.persistirEstado()
            synchronized(storeLock) {
                if (item.pins.get() == 0) items.remove(item.clave, item)
            }
        }
        purgarEfimero()
    }

    /** Descarta todo el efimero y cierra archivos; las partes persistentes conservan su mapa. */
    override fun close() {
        val todos = synchronized(storeLock) { items.values.toList().also { items.clear() } }
        for (i in todos) {
            i.persistirEstado()
            i.descartarForzado()
        }
    }

    override fun toString(): String =
        "SegmentStore(items=${synchronized(storeLock) { items.size }}, tope=$topeBytesEfimero)"
}
