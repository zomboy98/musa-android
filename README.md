# MUSA

Reproductor de música para Android (Flutter, Kotlin y Rust). Versión beta pública 0.9 (beta 4).


## Licencia

MUSA se distribuye bajo la licencia LGPL-3.0-only, con los terminos de la
GPL-3 incorporados. Los textos completos estan en `LICENSE` y `COPYING`. Tienes
derecho a recibir el codigo fuente y a modificarlo bajo esos terminos. La
atribucion del trabajo original se conserva en `NOTICE` y en la pantalla de
licencias de la aplicacion (Acerca > Licencias).

## Como compilar (a grandes rasgos)

1. Instala Flutter (la version indicada en `pubspec.yaml`) y, para Android, el
   SDK de Android y el NDK.
2. `flutter pub get` y `flutter gen-l10n`.
3. Para el motor nativo, usa los scripts de `scripts/` (`build_rust_backend.sh`
   o `build_rust_backend_windows.ps1`) y `scripts/build_android.sh`.
4. `flutter build apk --release` con tu propia firma (no incluida).

## Alcance

Los complementos y los servicios de MUSA son programas independientes que no
forman parte de este paquete.
