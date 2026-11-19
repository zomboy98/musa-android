# Ciclo de vida del motor de audio MUSA y cambios en vivo

Sesion y motor son independientes. La sesion entrega una `MusaFuenteAudio`; el motor solo recibe bytes y no sabe de sesiones ni proveedores. Un archivo local entra por la misma interfaz (`MusaFuenteLocal`, `info.local = true`, sin cache ni sesion).

## Eventos por pista (generacion)

`Cargando(motivo)` -> `Listo` (primer trozo entregado a la salida) -> `Sonando`/`Pausado` -> `Terminado` o `Falla(causa)` -> `Liberado` (ACK de limpieza).

- `Terminado` o `Falla` se emite como maximo una vez por generacion (CAS); nunca ambos.
- Los recursos (lector, transferencia, fuente, salida) se liberan antes de emitir el evento terminal.
- `cancelar()` no emite `Terminado`: espera la confirmacion de liberacion con tiempo limite y emite `Liberado`; si vence, emite `Falla(CANCELACION_NO_CONFIRMADA)` y el `Liberado` llega tarde si el recurso termina por fin soltandose.
- `abrir()` cancela la pista vigente y espera su confirmacion antes de arrancar la siguiente (o hasta el tiempo limite); despues solo se entregan eventos de la generacion nueva.
- Abrir la siguiente pista desde el callback de `Terminado` es valido (no se bloquea).

## Reintentos automaticos

Ante una falla de la fuente con causa `reintentable` el motor llama a `fuente.reabrir(desdeByte, causaPrevia)`, donde `desdeByte` es el primer byte que aun no se entrego a la salida.

- Maximo `MusaConfigMotor.reintentosMax` (2) por pista. Agotados, se emite una sola `Falla` con la causa final.
- Causas no reintentables (sesion invalida, bloqueo de red, verificacion, no encontrado, calidad, integridad, almacenamiento) no llaman a `reabrir`.
- Si `reabrir` devuelve `null`, `Falla` con la causa original y sin `Cargando` de reintento.
- Cada reintento aceptado emite `Cargando(REINTENTO)`; despues `Listo`/`Sonando` de nuevo al llegar el primer trozo.
- `LIMITE_TASA`: antes de `reabrir` espera `esperaLimiteTasaMs` (2000 ms). La espera se interrumpe al cancelar, y en pruebas se sustituye con `MusaConfigMotor.espera` (`MusaEspera`) sin dormir.
- Tras `cancelar()` no se llama a `reabrir`.
- Errores de la salida (`SALIDA_AUDIO` o los que reporte con `MusaOyenteErrorSalida`) nunca se reintentan.

## Contrapresion

`ventanaAdelanteBytes` (16 MiB por defecto, 0 = sin limite) solo se aplica a fuentes remotas en streaming (`info.local = false`, item efimero). La transferencia se detiene cuando el siguiente byte a pedir esta a `ventana` o mas por delante de la posicion de lectura (puede sobrepasar como maximo un `chunk`) y se reanuda al avanzar la lectura. Se despierta tambien al cancelar y ante un salto de lectura (seek), y se libera al llegar el fin de datos, por lo que no hay interbloqueo. Las descargas persistentes y la fuente local no la usan.

## Generacion de la fuente y limpieza

- `MusaFuenteAudio.generacionFuente` identifica los bytes que sirve la fuente (por defecto 0). Si cambia durante la reproduccion el motor lo trata como `ENLACE_EXPIRADO`: descarta la pieza recibida de esa generacion y llama a `reabrir`.
- Si la fuente que devuelve `reabrir` tiene otra generacion, el item efimero se descarta (nuevo item `musa-<generacion>-<n>`) y se pide de nuevo solo desde el byte necesario, sin repetir el prefijo anterior. Con la misma generacion se conservan los rangos y solo se piden los huecos.
- Los items efimeros `musa-<generacion>` se descartan al terminar, cancelar o fallar la pista. No se tocan items ajenos y la purga LRU sigue igual.

## Hilo colgado corregido

Una `Transferencia` cuyo item se descartaba (cierre del store con la pista aun activa) seguia pidiendo bytes en bucle porque `escribir` ignora items descartados; ahora termina en cuanto el item esta descartado. Se vio como fallo intermitente (~20 %) de las esperas de `hilosVivos`; tras el arreglo, 20 corridas seguidas limpias.

## Errores del reproductor (MusaMapeoErrores)

`MusaMapeoErrores.causaDe(codigo, tipoExcepcion, tiposCausa)` es una funcion pura (sin clases de Android) que convierte el codigo entero de error de Media3 y los nombres de tipo de excepcion en `MusaCausa`. Manda el codigo; si es "sin especificar" (1000, 1001, 1002, 1004, 2000, 6000) se usa el tipo de excepcion, y si nada coincide, `DESCONOCIDA`. Causas nuevas: `DECODIFICADOR` y `TIEMPO_AGOTADO` (reintentable).

AVISO: los valores numericos de `PlaybackException.ERROR_CODE_*` (1000 a 6xxx) se escribieron de memoria y estan A VERIFICAR contra la version 1.9.2 de Media3; no se han leido de sus fuentes ni se probaron en un dispositivo. Mientras tanto, el mapeo solo esta probado contra esas mismas constantes.

`MusaSalida` queda lista para una implementacion sobre Media3: `establecerOyenteError(MusaOyenteErrorSalida)` (por defecto no hace nada) permite informar de errores asincronos del reproductor con la causa ya mapeada; el motor los convierte en una sola `Falla` y libera. La implementacion sobre Media3 no esta hecha.

## Cambio en vivo audio -> video, video -> audio, cancion -> cancion

Se usa `motor.abrir(fuenteNueva, salidaNueva, MusaMotivo.MISMA_PISTA_OTRA_FUENTE, desdeByte)` (o `PISTA_NUEVA`). La generacion nueva usa su propia clave de cache, descarta lo recibido de la anterior y la anterior queda liberada antes de que empiece la nueva.

Para enchufar video no hay que tocar el motor ni la sesion:

1. La sesion crea una `MusaFuenteAudio` cuyo `info` describe el contenedor con video (p. ej. MP4/FMP4/WEBM).
2. La app aporta una `MusaSalida` de video (implementa `abrir/escribir/drenar/pausar/reanudar/posicionMs/abortar/liberar`) que consume esos bytes con el decodificador de video.
3. Se llama a `abrir` con `MISMA_PISTA_OTRA_FUENTE` y `desdeByte` aproximado a la posicion actual (resuelta por la sesion con `reabrir`).

No esta implementado: seek por milisegundos, mapeo posicion-tiempo a byte, seleccion de pistas de video, sincronia audio/video y descifrado (CENC/Blowfish). Nada de esto se ha probado en Android: las pruebas son solo JVM con fuentes y salidas simuladas.

## Ejecutar pruebas

Desde esta carpeta, con JDK y la distribucion de Gradle de la cache offline:

    gradle --offline runTests --rerun
