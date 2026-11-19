package org.wiss.motor.bytes

import java.util.TreeMap

/** Conjunto de rangos [inicio, fin) disjuntos y fusionados. NO es thread-safe (lo protege el item). */
internal class RangeSet {
    private val m = TreeMap<Long, Long>()

    /** Suma de bytes cubiertos. */
    var total: Long = 0L
        private set

    fun add(inicio: Long, fin: Long) {
        if (fin <= inicio) return
        var ni = inicio
        var nf = fin
        val lo = m.floorEntry(inicio)
        if (lo != null && lo.value >= inicio) {
            ni = lo.key
            nf = maxOf(nf, lo.value)
            total -= lo.value - lo.key
            m.remove(lo.key)
        }
        while (true) {
            val x = m.ceilingEntry(ni) ?: break
            if (x.key > nf) break
            nf = maxOf(nf, x.value)
            total -= x.value - x.key
            m.remove(x.key)
        }
        m[ni] = nf
        total += nf - ni
    }

    /** Fin del tramo contiguo que empieza en [pos]; == pos si [pos] no esta cubierto. */
    fun finContiguo(pos: Long): Long {
        val f = m.floorEntry(pos)
        return if (f != null && f.value > pos) f.value else pos
    }

    /** Primer byte >= [pos] que NO esta cubierto. */
    fun primerHuecoDesde(pos: Long): Long = finContiguo(pos)

    /** Inicio del siguiente rango cubierto estrictamente despues de [pos], o null. */
    fun siguienteInicio(pos: Long): Long? = m.higherKey(pos)

    /** Fin mas alto cubierto (0 si vacio). */
    fun ultimoFin(): Long = if (m.isEmpty()) 0L else m.lastEntry().value

    fun cubre(inicio: Long, fin: Long): Boolean = fin <= inicio || finContiguo(inicio) >= fin

    fun copia(): List<LongArray> = m.entries.map { longArrayOf(it.key, it.value) }

    fun limpiar() {
        m.clear()
        total = 0
    }
}
