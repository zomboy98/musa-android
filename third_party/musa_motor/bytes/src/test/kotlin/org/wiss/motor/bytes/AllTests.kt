package org.wiss.motor.bytes

import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.system.exitProcess

private const val MB = 1024 * 1024

private fun nuevoStore(dir: Path, tope: Long = 10L * MB) = SegmentStore(dir.resolve("efimero"), tope)

fun main() {
    pruebasRangos()
    pruebasLectura()
    pruebasSeek()
    pruebasConcurrencia()
    pruebasPromocion()
    pruebasPurga()
    pruebasFinalizacion()
    pruebasReanudacion()
    pruebasOrigenLento()
    pruebasSeguridad()
    pruebasMusa()
    exitProcess(Runner.terminar())
}

// ------------------------------------------------------------------------------------------

private fun pruebasRangos() {
    Runner.prueba("RangeSet: fusion, huecos y total") {
        val r = RangeSet()
        r.add(10, 20); r.add(30, 40); r.add(20, 30)
        igual(1, r.copia().size, "fusionados")
        igual(30L, r.total)
        igual(40L, r.finContiguo(10))
        igual(5L, r.finContiguo(5), "pos sin cubrir")
        r.add(0, 5); r.add(5, 10)
        igual(40L, r.total)
        r.add(100, 110); r.add(105, 120); r.add(50, 60); r.add(55, 101)
        igual(1, r.copia().filter { it[0] == 50L }.size)
        igual(true, r.cubre(50, 120))
        igual(false, r.cubre(40, 51))
        igual(40L, r.primerHuecoDesde(0))
        igual(50L, r.siguienteInicio(40))
    }
}

private fun pruebasLectura() {
    Runner.prueba("lectura parcial bloqueante con timeout (Faltan != EOF)") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(10_000)
                val o = OrigenSimulado(d, maxPorLlamada = 1000)
                o.liberarHasta(0)
                store.abrir("k1", Retencion.EFIMERO).use { item ->
                    item.asegurarTransferencia(512) { o }
                    item.lector(100).use { lector ->
                        val buf = ByteArray(100)
                        val t0 = System.nanoTime()
                        igual(ResultadoLectura.Faltan, lector.leer(0, buf), "sin datos aun")
                        val ms = (System.nanoTime() - t0) / 1_000_000
                        afirma(ms >= 90, "debio esperar el timeout, espero $ms ms")
                        o.liberarHasta(1000)
                        // pide mucho mas de lo disponible: devuelve parcial en cuanto hay bytes
                        val grande = ByteArray(5000)
                        val r = lector.leer(0, grande, 0, 5000, 5000)
                        afirma(r is ResultadoLectura.Bytes && r.n in 1..1000, "parcial: $r")
                        val n = (r as ResultadoLectura.Bytes).n
                        afirma(grande.copyOf(n).contentEquals(d.copyOf(n)), "contenido parcial")
                        // un lector bloqueado en 1000 se despierta cuando llega el dato
                        val res = AtomicReference<ResultadoLectura>()
                        val b2 = ByteArray(50)
                        val hilo = Thread { res.set(lector.leer(1000, b2, 0, 50, 10_000)) }
                        hilo.start()
                        o.liberarHasta(3000)
                        hilo.join(10_000)
                        afirma(res.get() is ResultadoLectura.Bytes, "desperto con bytes: ${res.get()}")
                        afirma(b2.copyOf((res.get() as ResultadoLectura.Bytes).n)
                            .contentEquals(d.copyOfRange(1000, 1000 + (res.get() as ResultadoLectura.Bytes).n)), "contenido")
                        o.liberarHasta(Long.MAX_VALUE)
                    }
                }
            }
        }
    }

    Runner.prueba("EOF correcto, lectura completa y len=0") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(20_000)
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(4096) { OrigenSimulado(d) }!!
                    afirma(t.esperar(10_000), "termino")
                    igual(EstadoOrigen.COMPLETO, item.estado)
                    item.lector().use { l ->
                        afirma(leerExacto(l, 0, d.size).contentEquals(d), "contenido completo")
                        igual(ResultadoLectura.Eof, l.leer(d.size.toLong(), ByteArray(10)), "EOF en el fin")
                        igual(ResultadoLectura.Eof, l.leer(d.size + 500L, ByteArray(10)), "EOF pasado el fin")
                        igual(ResultadoLectura.Bytes(0), l.leer(5, ByteArray(10), 0, 0), "len=0")
                    }
                }
            }
        }
    }

    Runner.prueba("tamano desconocido: el EOF del origen fija el tamano") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(9_000)
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(2048) { OrigenSimulado(d, tamanoConocido = false) }!!
                    afirma(t.esperar(10_000))
                    igual(EstadoOrigen.COMPLETO, item.estado)
                    igual(9_000L, item.tamano)
                    item.lector().use { l ->
                        afirma(leerExacto(l, 0, 9000).contentEquals(d))
                        igual(ResultadoLectura.Eof, l.leer(9000, ByteArray(4)))
                    }
                }
            }
        }
    }

    Runner.prueba("ERROR del origen: bytes previos legibles, luego Error(tipo) sin mensaje") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(30_000)
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(4096) { OrigenSimulado(d, fallaEnOffset = 12_000) }!!
                    afirma(t.esperar(10_000))
                    igual(EstadoOrigen.ERROR, item.estado)
                    item.lector().use { l ->
                        afirma(leerExacto(l, 0, 12_000).contentEquals(d.copyOf(12_000)), "bytes antes del fallo")
                        val r = l.leer(12_000, ByteArray(10))
                        igual(ResultadoLectura.Error("IOException"), r)
                        afirma(!r.toString().contains("boom") && !(item.causaError ?: "").contains("boom"), "sin mensaje")
                    }
                }
            }
        }
    }

    Runner.prueba("CANCEL: cancelar la transferencia y cancelar un lector bloqueado") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val o = OrigenSimulado(datos(50_000))
                o.liberarHasta(8192)
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(4096) { o }!!
                    item.lector().use { l ->
                        afirma(item.esperarRecibidos(8192, 10_000))
                        // lector bloqueado en un hueco; lo cancela otro hilo
                        val res = AtomicReference<ResultadoLectura>()
                        val inicio = CountDownLatch(1)
                        val hilo = Thread {
                            inicio.countDown()
                            res.set(l.leer(30_000, ByteArray(10), 0, 10, 60_000))
                        }
                        hilo.start()
                        inicio.await()
                        l.cancelar() // despierta por condicion, sin sondeo
                        hilo.join(10_000)
                        igual(ResultadoLectura.Cancelado, res.get(), "lector cancelado")
                        igual(ResultadoLectura.Cancelado, l.leer(0, ByteArray(4)), "lector cancelado queda cancelado")
                    }
                    t.cancelar()
                    afirma(t.esperar(10_000))
                    igual(EstadoOrigen.CANCELADO, item.estado)
                    item.lector().use { l2 ->
                        igual(ResultadoLectura.Cancelado, l2.leer(40_000, ByteArray(10)), "hueco tras cancelar")
                        afirma(leerExacto(l2, 0, 8192).isNotEmpty(), "lo recibido sigue legible")
                    }
                    afirma(o.cerrado, "origen cerrado")
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasSeek() {
    Runner.prueba("seek a un hueco: se pide ese rango de forma prioritaria al origen") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(1_000_000)
                val o = OrigenSimulado(d, maxPorLlamada = 4096)
                o.liberarHasta(0) // la 1a peticion (offset 0) queda en vuelo
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(4096) { o }!!
                    item.lector().use { l ->
                        val buf = ByteArray(2000)
                        igual(ResultadoLectura.Faltan, l.leer(800_000, buf, 0, 2000, 100), "hueco aun no llega")
                        o.liberarHasta(Long.MAX_VALUE)
                        val r = l.leer(800_000, buf, 0, 2000, 10_000)
                        afirma(r is ResultadoLectura.Bytes, "bytes del hueco: $r")
                        val n = (r as ResultadoLectura.Bytes).n
                        afirma(buf.copyOf(n).contentEquals(d.copyOfRange(800_000, 800_000 + n)), "contenido")
                        val saltos = o.servidos.map { it[0] }
                        afirma(800_000L in saltos, "el origen recibio la peticion del rango prioritario")
                        // la peticion prioritaria llego pronto (no se sirvio todo lo anterior)
                        afirma(saltos.indexOf(800_000L) <= 2, "salto inmediato, pos=${saltos.indexOf(800_000L)}")
                        t.cancelar()
                        t.esperar(10_000)
                    }
                }
            }
        }
    }

    Runner.prueba("seek con origen SIN rangos: espera (Faltan) y luego llega secuencialmente") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(60_000)
                val o = OrigenSimulado(d, admiteRangos = false, maxPorLlamada = 4096)
                o.liberarHasta(0)
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(4096) { o }!!
                    item.lector().use { l ->
                        igual(ResultadoLectura.Faltan, l.leer(50_000, ByteArray(10), 0, 10, 100))
                        o.liberarHasta(Long.MAX_VALUE)
                        val b = leerExacto(l, 50_000, 10_000)
                        afirma(b.contentEquals(d.copyOfRange(50_000, 60_000)))
                    }
                    afirma(t.esperar(10_000))
                    afirma(o.servidos.map { it[0] } == o.servidos.map { it[0] }.sorted(), "peticiones secuenciales")
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasConcurrencia() {
    Runner.prueba("escritura concurrente segura (8 escritores solapados + lectores)") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val size = 400_000
                val d = datos(size)
                store.abrir("k", Retencion.EFIMERO).use { item ->
                    item.fijarTamano(size.toLong())
                    val trozo = 5_000
                    val n = size / trozo
                    val errores = AtomicInteger(0)
                    val hilos = (0 until 8).map { tid ->
                        Thread {
                            try {
                                val orden = (0 until n).filter { it % 8 == tid }.shuffled(java.util.Random(tid.toLong()))
                                for (i in orden) {
                                    item.escribir(i * trozo.toLong(), d, i * trozo, trozo)
                                    // escritura duplicada y desplazada (solape con el vecino)
                                    val s = i * trozo + 1000
                                    if (s + 2000 <= size) item.escribir(s.toLong(), d, s, 2000)
                                }
                            } catch (_: Throwable) {
                                errores.incrementAndGet()
                            }
                        }
                    }
                    val lectores = (0 until 3).map { k ->
                        Thread {
                            try {
                                item.lector().use { l ->
                                    val rnd = java.util.Random(100L + k)
                                    repeat(60) {
                                        val off = rnd.nextInt(size - 3000)
                                        val b = ByteArray(3000)
                                        val r = l.leer(off.toLong(), b, 0, 3000, 30_000)
                                        if (r is ResultadoLectura.Bytes) {
                                            if (!b.copyOf(r.n).contentEquals(d.copyOfRange(off, off + r.n))) errores.incrementAndGet()
                                        } else errores.incrementAndGet()
                                    }
                                }
                            } catch (_: Throwable) {
                                errores.incrementAndGet()
                            }
                        }
                    }
                    (hilos + lectores).forEach { it.start() }
                    (hilos + lectores).forEach { it.join(30_000) }
                    igual(0, errores.get(), "errores concurrentes")
                    igual(size.toLong(), item.bytesRecibidos, "sin bytes de mas ni de menos")
                    item.terminar(EstadoOrigen.COMPLETO)
                    igual(EstadoOrigen.COMPLETO, item.estado)
                    item.lector().use { l -> afirma(leerExacto(l, 0, size).contentEquals(d), "contenido final") }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasPromocion() {
    Runner.prueba("promocion EFIMERO->PERSISTENTE con transferencia en curso: no se re-pide nada") {
        conTemp { dir ->
            val store = nuevoStore(dir)
            store.use {
                val size = 200_000
                val d = datos(size)
                val o = OrigenSimulado(d, maxPorLlamada = 4096)
                o.liberarHasta(80_000)
                val ruta = dir.resolve("descargas/pista.bin")
                val item = store.abrir("pista", Retencion.EFIMERO)
                val t = item.asegurarTransferencia(4096) { o }!!
                item.lector().use { l ->
                    afirma(leerExacto(l, 0, 10_000).contentEquals(d.copyOf(10_000)), "suena mientras llega")
                }
                afirma(item.esperarRecibidos(80_000, 10_000))
                afirma(!Files.exists(ruta), "efimero no publica nada")
                // el usuario decide descargar: misma clave, ahora persistente
                val item2 = store.abrir("pista", Retencion.PERSISTENTE, ruta)
                afirma(item === item2, "mismo item (no se reinicia la transferencia)")
                igual(Retencion.PERSISTENTE, item.retencion)
                afirma(Files.exists(ItemCache.parteDe(ruta)), "los bytes recibidos se movieron al .part")
                igual(emptyList<String>(), listar(dir.resolve("efimero")), "nada queda en el efimero")
                item2.close()
                o.liberarHasta(Long.MAX_VALUE)
                afirma(t.esperar(10_000))
                igual(EstadoOrigen.COMPLETO, item.estado)
                afirma(item.finalizado, "finalizado")
                afirma(Files.readAllBytes(ruta).contentEquals(d), "archivo final identico")
                verificaSinRepetidos(size, o) // cero bytes pedidos dos veces
                igual(1, o.servidos.count { it[0] == 0L }, "el offset 0 se pidio una sola vez")
                item.close()
            }
        }
    }

    Runner.prueba("promocion tras abandonar el streaming: la descarga pide SOLO los huecos") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val size = 200_000
                val d = datos(size)
                val o1 = OrigenSimulado(d, maxPorLlamada = 4096)
                o1.liberarHasta(60_000)
                val item = store.abrir("p", Retencion.EFIMERO)
                val t1 = item.asegurarTransferencia(4096) { o1 }!!
                afirma(item.esperarRecibidos(60_000, 10_000))
                t1.cancelar() // el usuario sale del streaming
                afirma(t1.esperar(10_000))
                igual(EstadoOrigen.CANCELADO, item.estado)
                val recibido = item.bytesRecibidos
                val ruta = dir.resolve("out/p.bin")
                store.abrir("p", Retencion.PERSISTENTE, ruta).close()
                val o2 = OrigenSimulado(d, maxPorLlamada = 4096)
                val t2 = item.asegurarTransferencia(4096) { o2 }!!
                afirma(t2.esperar(10_000))
                igual(EstadoOrigen.COMPLETO, item.estado)
                afirma(Files.readAllBytes(ruta).contentEquals(d), "archivo final")
                igual(recibido, o1.bytesServidos, "lo recibido por el origen 1")
                igual(size - recibido, o2.bytesServidos, "el origen 2 solo sirvio lo que faltaba")
                afirma(o2.offsetMinimo() >= recibido, "no repidio el principio")
                verificaSinRepetidos(size, o1, o2)
                item.close()
            }
        }
    }

    Runner.prueba("promover un item ya completo finaliza al instante y no hay nada que pedir") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(30_000)
                val item = store.abrir("p", Retencion.EFIMERO)
                afirma(item.asegurarTransferencia(4096) { OrigenSimulado(d) }!!.esperar(10_000))
                val ruta = dir.resolve("x/p.bin")
                store.abrir("p", Retencion.PERSISTENTE, ruta).close()
                afirma(item.finalizado)
                afirma(Files.readAllBytes(ruta).contentEquals(d))
                val fabricas = AtomicInteger(0)
                afirma(item.asegurarTransferencia { fabricas.incrementAndGet(); OrigenSimulado(d) } == null, "sin transferencia")
                igual(0, fabricas.get(), "no se creo ningun origen")
                item.close()
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasPurga() {
    Runner.prueba("purga LRU del efimero con tope de bytes (no toca persistentes ni items en uso)") {
        conTemp { dir ->
            nuevoStore(dir, tope = 250_000).use { store ->
                fun llenar(clave: String, cerrar: Boolean = true): ItemCache {
                    val it = store.abrir(clave, Retencion.EFIMERO)
                    it.fijarTamano(100_000)
                    it.escribir(0, ByteArray(100_000), 0, 100_000)
                    it.terminar(EstadoOrigen.COMPLETO)
                    if (cerrar) it.close()
                    return it
                }
                llenar("A"); llenar("B")
                igual(200_000L, store.bytesEfimeros())
                llenar("C") // 300k > 250k: expulsa el menos reciente (A)
                afirma(!store.contiene("A"), "A expulsado")
                afirma(store.contiene("B") && store.contiene("C"), "B y C se quedan")
                igual(1, store.purgados)
                // tocar B (lectura) lo hace mas reciente que C
                store.abrir("B", Retencion.EFIMERO).also { b ->
                    b.lector().use { l -> leerExacto(l, 0, 10) }
                    b.close()
                }
                llenar("D") // ahora el LRU es C
                afirma(!store.contiene("C"), "C expulsado (LRU)")
                afirma(store.contiene("B") && store.contiene("D"), "B y D")
                // un item en uso no se expulsa aunque se exceda el tope
                val enUso = store.abrir("B", Retencion.EFIMERO)
                llenar("E"); llenar("F")
                afirma(store.contiene("B"), "B en uso no se purga")
                afirma(!store.contiene("D"), "D (libre y antiguo) si")
                // persistentes no cuentan para el tope efimero
                val antes = store.bytesEfimeros()
                val per = store.abrir("per", Retencion.PERSISTENTE, dir.resolve("per/p.bin"))
                per.fijarTamano(500_000)
                per.escribir(0, ByteArray(500_000), 0, 500_000)
                igual(antes, store.bytesEfimeros(), "persistente fuera del tope")
                afirma(store.contiene("per"))
                per.close()
                enUso.close()
                afirma(store.bytesEfimeros() <= 250_000, "bajo el tope tras liberar: ${store.bytesEfimeros()}")
                afirma(listar(dir.resolve("efimero")).size <= 2, "el disco refleja la purga: ${listar(dir.resolve("efimero"))}")
            }
        }
    }

    Runner.prueba("streaming no se guarda: sin archivos finales y el efimero se limpia al cerrar/reabrir") {
        conTemp { dir ->
            val d = datos(50_000)
            val store = nuevoStore(dir)
            val item = store.abrir("s", Retencion.EFIMERO)
            afirma(item.asegurarTransferencia(4096) { OrigenSimulado(d) }!!.esperar(10_000))
            item.close()
            igual(listOf("efimero"), listar(dir), "solo existe el directorio efimero")
            afirma(listar(dir.resolve("efimero")).isNotEmpty(), "hay cache temporal")
            store.close()
            igual(emptyList<String>(), listar(dir.resolve("efimero")), "close() descarta el efimero")
            // restos de una ejecucion anterior se borran al construir
            Files.write(dir.resolve("efimero/e-99.bin"), ByteArray(10))
            nuevoStore(dir).close()
            igual(emptyList<String>(), listar(dir.resolve("efimero")), "restos purgados al iniciar")
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasFinalizacion() {
    Runner.prueba("finalizacion atomica: .part en su ruta, rename unico, sin staging, verifica tamano") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val size = 100_000
                val d = datos(size)
                val ruta = dir.resolve("musica/a.flac")
                Files.createDirectories(ruta.parent)
                Files.write(ruta, "contenido viejo".toByteArray()) // se reemplaza atomicamente
                val o = OrigenSimulado(d, maxPorLlamada = 4096)
                o.liberarHasta(50_000)
                val item = store.abrir("a", Retencion.PERSISTENTE, ruta, tamanoEsperado = size.toLong())
                val t = item.asegurarTransferencia(4096) { o }!!
                afirma(item.esperarRecibidos(50_000, 10_000))
                afirma(Files.exists(ItemCache.parteDe(ruta)), ".part junto a la ruta final")
                afirma(Files.readAllBytes(ruta).contentEquals("contenido viejo".toByteArray()), "la ruta final intacta hasta el rename")
                igual(false, listar(dir.resolve("efimero")).any { it.endsWith(".bin") }, "sin copias en staging/efimero")
                o.liberarHasta(Long.MAX_VALUE)
                afirma(t.esperar(10_000))
                igual(listOf("a.flac"), listar(ruta.parent), "solo queda el archivo final (sin .part ni .rng)")
                afirma(Files.readAllBytes(ruta).contentEquals(d), "contenido final")
                item.close()
                // reabrir: ya esta descargado -> COMPLETO sin tocar el origen
                val fabricas = AtomicInteger(0)
                store.abrir("a", Retencion.PERSISTENTE, ruta, tamanoEsperado = size.toLong()).use { again ->
                    igual(EstadoOrigen.COMPLETO, again.estado)
                    afirma(again.finalizado)
                    afirma(again.asegurarTransferencia { fabricas.incrementAndGet(); OrigenSimulado(d) } == null)
                    again.lector().use { l -> afirma(leerExacto(l, 1000, 500).contentEquals(d.copyOfRange(1000, 1500))) }
                }
                igual(0, fabricas.get())
            }
        }
    }

    Runner.prueba("finalizacion: fin prematuro del origen (tamano incorrecto) NO publica la ruta final") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val d = datos(20_000)
                val ruta = dir.resolve("dl/b.bin")
                store.abrir("b", Retencion.PERSISTENTE, ruta).use { item ->
                    val t = item.asegurarTransferencia(4096) { OrigenSimulado(d, finPrematuroEn = 9_000) }!!
                    afirma(t.esperar(10_000))
                    igual(EstadoOrigen.ERROR, item.estado)
                    afirma(!Files.exists(ruta), "ruta final no existe")
                    afirma(Files.exists(ItemCache.parteDe(ruta)), "la parte queda para reanudar")
                    igual(9_000L, item.bytesRecibidos)
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasReanudacion() {
    Runner.prueba("descarga interrumpida (error) y reanudada: solo se piden los huecos") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val size = 100_000
                val d = datos(size)
                val ruta = dir.resolve("dl/c.bin")
                val o1 = OrigenSimulado(d, maxPorLlamada = 4096, fallaEnOffset = 60_000)
                val item = store.abrir("c", Retencion.PERSISTENTE, ruta)
                val t1 = item.asegurarTransferencia(4096) { o1 }!!
                afirma(t1.esperar(10_000))
                igual(EstadoOrigen.ERROR, item.estado)
                igual(60_000L, item.bytesRecibidos)
                afirma(!Files.exists(ruta))
                val o2 = OrigenSimulado(d, maxPorLlamada = 4096)
                val t2 = item.asegurarTransferencia(4096) { o2 }!!
                afirma(t2.esperar(10_000))
                igual(EstadoOrigen.COMPLETO, item.estado)
                igual(60_000L, o2.offsetMinimo(), "reanuda en el hueco")
                igual(40_000L, o2.bytesServidos, "solo lo que faltaba")
                afirma(Files.readAllBytes(ruta).contentEquals(d))
                verificaSinRepetidos(size, o1, o2)
                item.close()
            }
        }
    }

    Runner.prueba("descarga interrumpida y reanudada tras REINICIAR el store (mapa en disco)") {
        conTemp { dir ->
            val size = 120_000
            val d = datos(size)
            val ruta = dir.resolve("dl/d.bin")
            val o1 = OrigenSimulado(d, maxPorLlamada = 4096)
            o1.liberarHasta(50_000)
            val recibido: Long
            run {
                val store = nuevoStore(dir)
                val item = store.abrir("d", Retencion.PERSISTENTE, ruta, size.toLong())
                val t = item.asegurarTransferencia(4096) { o1 }!!
                afirma(item.esperarRecibidos(50_000, 10_000))
                t.cancelar()
                afirma(t.esperar(10_000))
                recibido = item.bytesRecibidos
                item.close()
                store.close() // "proceso reiniciado"
            }
            afirma(Files.exists(ItemCache.parteDe(ruta)) && Files.exists(ItemCache.sidecarDe(ruta)), "parte + mapa en disco")
            nuevoStore(dir).use { store2 ->
                val o2 = OrigenSimulado(d, maxPorLlamada = 4096)
                store2.abrir("d", Retencion.PERSISTENTE, ruta, size.toLong()).use { item ->
                    igual(recibido, item.bytesRecibidos, "mapa recuperado")
                    val t = item.asegurarTransferencia(4096) { o2 }!!
                    afirma(t.esperar(10_000))
                    igual(EstadoOrigen.COMPLETO, item.estado)
                    igual(size - recibido, o2.bytesServidos, "solo los huecos tras reiniciar")
                    verificaSinRepetidos(size, o1, o2)
                }
                afirma(Files.readAllBytes(ruta).contentEquals(d))
                igual(listOf("d.bin"), listar(ruta.parent))
            }
        }
    }

    Runner.prueba("una sola transferencia por item: asegurarTransferencia es idempotente mientras corre") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val o = OrigenSimulado(datos(30_000))
                o.liberarHasta(0)
                store.abrir("x", Retencion.EFIMERO).use { item ->
                    val t1 = item.asegurarTransferencia(4096) { o }!!
                    val t2 = item.asegurarTransferencia(4096) { throw IllegalStateException("no debe crear otro origen") }
                    afirma(t1 === t2)
                    o.liberarHasta(Long.MAX_VALUE)
                    afirma(t1.esperar(10_000))
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasOrigenLento() {
    Runner.prueba("origen lento por trozos con retardo: suena mientras llega (streaming) y no se guarda") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val size = 256 * 1024
                val d = datos(size)
                val o = OrigenSimulado(d, maxPorLlamada = 16 * 1024, retardoMs = 25)
                store.abrir("lento", Retencion.EFIMERO).use { item ->
                    val t0 = System.nanoTime()
                    val t = item.asegurarTransferencia(16 * 1024) { o }!!
                    var primerByteMs = -1L
                    val salida = ByteArray(size)
                    item.lector().use { l ->
                        var pos = 0
                        while (true) {
                            val r = l.leer(pos.toLong(), salida, pos, minOf(8192, size - pos).coerceAtLeast(1), 10_000)
                            if (r is ResultadoLectura.Bytes) {
                                if (primerByteMs < 0) primerByteMs = (System.nanoTime() - t0) / 1_000_000
                                pos += r.n
                                if (pos >= size) break
                            } else throw FalloPrueba("lectura sin bytes: $r")
                        }
                    }
                    val totalMs = (System.nanoTime() - t0) / 1_000_000
                    afirma(t.esperar(10_000))
                    afirma(salida.contentEquals(d), "contenido consumido en streaming")
                    afirma(totalMs >= 16 * 25 * 0.8, "el origen realmente fue lento: $totalMs ms")
                    afirma(primerByteMs < totalMs / 2, "empezo a sonar pronto: primer byte $primerByteMs ms de $totalMs ms")
                    verificaSinRepetidos(size, o)
                }
                igual(listOf("efimero"), listar(dir), "nada persistido")
            }
        }
    }

    Runner.prueba("origen lento con seek en mitad: salta al hueco sin esperar a llegar secuencialmente") {
        conTemp { dir ->
            nuevoStore(dir).use { store ->
                val size = 512 * 1024
                val d = datos(size)
                val o = OrigenSimulado(d, maxPorLlamada = 8 * 1024, retardoMs = 20) // secuencial seria ~1.3 s
                store.abrir("lento2", Retencion.EFIMERO).use { item ->
                    val t = item.asegurarTransferencia(8 * 1024) { o }!!
                    item.lector().use { l ->
                        val t0 = System.nanoTime()
                        val b = leerExacto(l, 400_000, 4000)
                        val ms = (System.nanoTime() - t0) / 1_000_000
                        afirma(b.contentEquals(d.copyOfRange(400_000, 404_000)))
                        afirma(ms < 600, "el seek no espero al secuencial: $ms ms")
                    }
                    t.cancelar()
                    t.esperar(10_000)
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------

private fun pruebasSeguridad() {
    Runner.prueba("toString/errores no filtran claves, rutas ni mensajes del origen") {
        conTemp { dir ->
            val secretos = listOf("CLAVE-SECRETA-XYZ", "carpeta-secreta-abc", dir.toString(), "boom-secreto-token-123")
            val store = nuevoStore(dir)
            val ruta = dir.resolve("carpeta-secreta-abc/p.bin")
            val item = store.abrir("CLAVE-SECRETA-XYZ", Retencion.PERSISTENTE, ruta)
            val t = item.asegurarTransferencia(4096) { OrigenSimulado(datos(10_000), fallaEnOffset = 5000) }!!
            t.esperar(10_000)
            val lector = item.lector()
            val textos = listOf(
                store.toString(), item.toString(), lector.toString(), t.toString(),
                lector.leer(5000, ByteArray(4)).toString(), ResultadoLectura.Faltan.toString(),
                item.causaError.toString(), item.estado.toString(), item.rangosRecibidos().joinToString { it.toList().toString() },
            )
            for (txt in textos) for (s in secretos) afirma(!txt.contains(s), "filtra '$s' en '$txt'")
            lector.close(); item.close(); store.close()
        }
    }
}
