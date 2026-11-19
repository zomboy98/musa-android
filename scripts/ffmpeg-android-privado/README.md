# FFmpeg Android privado: preparación experimental

`build.sh` extrae exclusivamente el árbol del commit `38b88335f99e76ed89ff3c93f877fdefce736c13` (tag `n8.1.2`), sin copiar modificaciones del checkout. Produce por ABI bibliotecas estáticas PIC y encabezados instalados del mismo build. El resultado no se ha compilado ni validado todavía y no se integra en la aplicación.

Pensado para Linux CI x86-64: requiere Git, GNU Make, Perl, herramientas habituales Unix y Android NDK Linux 28.2.13676358. No se ejecuta en WSL ni utiliza el NDK Windows. Ejemplo en un runner Linux con las dependencias preparadas:

```bash
export FFMPEG_REPO=/ruta/al/checkout-ffmpeg
export ANDROID_NDK_HOME=/ruta/al/ndk/28.2.13676358
bash build.sh /ruta/nueva/fuera-del-checkout all
```

Nunca reutiliza ni sobrescribe la salida. Conserva el archivo fuente, commit, versión del NDK, directorios de compilación, configuración de FFmpeg y hashes. La reproducibilidad aquí significa entradas y configuración fijadas; no se promete identidad binaria entre máquinas. Hacen falta pruebas de compilación, CENC, cancelación y ruta completa para cada ABI.

El script fija `SOURCE_DATE_EPOCH` al timestamp del commit y registra versiones de herramientas. Tras instalar comprueba opciones MOV/FLAC, encabezados, bibliotecas, símbolos de formato y arquitectura de los objetos ELF; conserva la evidencia. Estas comprobaciones no demuestran ABI en ejecución, aislamiento, seguridad, funcionamiento CENC ni cumplimiento de licencia. `bash test-preflight.sh` prueba exclusivamente rechazos sintéticos sin compilar.

El destino futuro debe enlazar los archivos `.a` solo en un puente nativo privado, con `-Wl,--exclude-libs,ALL`, símbolos de puente exportados mediante mapa de versiones y sin `--whole-archive` innecesario. Verificar símbolos dinámicos con `llvm-readelf --dyn-syms` y dependencias con `llvm-readelf -d`, y probar que FFmpegKit mantiene su funcionamiento; estas opciones todavía no prueban aislamiento efectivo ni están configuradas en la aplicación.

Se omiten opciones GPL/nonfree y bibliotecas externas; verificar el `config.h` y la licencia de cada resultado antes de distribuir. FFmpeg recomienda enlace dinámico como vía sencilla de cumplimiento LGPL. La distribución de un enlace estático requiere estudiar y cumplir, entre otras obligaciones, las condiciones de relink/reemplazo, código fuente correspondiente y avisos; no se afirma conformidad legal. Ver https://ffmpeg.org/legal.html y https://ffmpeg.org/doxygen/trunk/md_LICENSE.html.
