# Prueba instrumentada silenciosa: preparación progresiva con ExoPlayer

Estado: **no verificada**. No se compiló ni se ejecutó nada (ni Gradle, ni dispositivo,
ni red). Todo lo de abajo es diseño revisado por lectura, no un resultado.

## Archivos
- `kotlin/com/zarz/mornye/ExoProgressivePreparationInstrumentedTest.kt`
- Fixture `assets/synthetic_fragmented_aac_test.m4a` (**existe**; el test comprueba su
  SHA-256 `6ce40162…fd58`; no está documentado en `assets/README.md`).
- `android/app/build.gradle.kts`: añadida
  `androidTestImplementation("androidx.media3:media3-exoplayer:1.9.2")`
  (misma versión que `third_party/audioplayers_android/android/build.gradle:75`,
  que la declara como `implementation` y por eso no llega al classpath de compilación
  de androidTest).

## Dependencias androidTest ya existentes (build.gradle.kts)
`androidx.test:runner:1.7.0`, `androidx.test.ext:junit:1.3.0`,
`androidx.media:media:1.8.0`, runner `AndroidJUnitRunner`. JUnit 4 llega con
`androidx.test.ext:junit`. Las clases `xyz.luan.audioplayers.source.*` ya se usan desde
otros androidTest (`AudioContextRoutingTest`). `media3-exoplayer` arrastra
`media3-common` y `media3-datasource` como `api`.

## Qué afirma ahora el test
Fase 1, barrera cerrada (segunda mitad del archivo retenida):
1. El latch `outcome` se abre con READY **o** con error; se distinguen
   (`ready` vs `failure`). Un error antes de la liberación falla el test, nunca cuenta
   como READY.
2. Se exige `STATE_READY` dentro de 10 s **antes** de liberar la barrera
   (`assertTrue`, ya no solo `Log.i`), confirmado además consultando
   `playbackState` en el looper del player.
3. Bytes medidos en la propia lease (`servedBytes`, `highWater`), capturados en el
   instante del listener READY: `0 < servido <= split` y `highWater <= split`.
4. `playWhenReady == false` en READY y después; `isPlaying == false`.
5. El renderer silencioso recibió la pista de audio (`currentTracks.isTypeSelected`).
6. Barrera cerrada realmente: `releasedAtReady == false` (se lee antes y después de
   los bytes para evitar la carrera).

Fase 2, tras liberar: espera acotada (5 s); sin error; estado READY/BUFFERING; sigue
`playWhenReady=false`. Se loguea cuántos bytes llegaron; **no** se exige lectura completa.

Todas las esperas son acotadas; `@Test(timeout=60000)`. `finally` siempre: marca la
lease cerrada, libera la barrera, `release()` del player en su looper, `quitSafely` +
`join`. Si la limpieza falla y no hay otro error, el test falla.

## Límites: qué NO puede demostrar (sin fingir éxito)
- **Que el fixture alcance READY con solo la mitad.** Depende de que `moov`/cabecera
  y ≥ el buffer mínimo de reproducción del `LoadControl` por defecto (~2,5 s de audio)
  estén en el primer 50 %. No lo he podido comprobar (no se inspecciona el binario ni
  se conoce su duración). Si no, el test **fallará en la aserción de READY previo**: ese
  fallo sería un hallazgo real sobre el fixture/split, no un defecto del test. Posible
  ajuste: mover `split` a un offset tras la cabecera + N fragmentos.
- **Ausencia de `AudioTrack`.** Solo se garantiza por construcción (la
  `RenderersFactory` devuelve únicamente el renderer propio, sin `MediaCodecAudioRenderer`).
  No se inspecciona el sistema de audio; un `AudioTrack` creado por otra vía no se vería.
- **Que `READY` equivalga a "reproducible".** Con el renderer que no consume muestras y
  `isEnded()=false` no se llega a `STATE_ENDED`, ni se valida decodificación real.
- Es una prueba de la ruta `ProgressiveMediaSource` + `TimedProgressiveDataSource`
  con una lease sintética; no cubre `Media3ProgressivePlayer` ni proveedores reales.
- Posible fragilidad: `knownSize()` devuelve `null` hasta liberar; si el extractor
  necesita longitud para el índice (sidx/mfra), el comportamiento puede diferir.
- No compilado: nombres de API Media3 1.9.2 (`errorCodeName`, `isTypeSelected`,
  `RenderersFactory` como SAM) están tomados del uso previo y de memoria; un error de
  compilación es posible. `UnstableApi` está marcado a nivel de clase.

## Ejecución (cuando se autorice)
`./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.zarz.mornye.ExoProgressivePreparationInstrumentedTest`

## Estado de compilación actualizado (2026-11-12)

La tarea `:app:compileDebugAndroidTestKotlin` terminó correctamente junto con `Media3RetirementInstrumentedTest`. Se excluyó `:app:buildRustBackend`, por lo que la biblioteca Rust no se regeneró. Ninguna de estas pruebas se ha ejecutado en Android; las limitaciones de ejecución anteriores siguen vigentes.
