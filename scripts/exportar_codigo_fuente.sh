#!/usr/bin/env bash
# Genera musa-codigo-fuente-<version>.zip con los archivos versionados del
# commit actual, sin secretos ni material interno. Uso: [directorio_salida].
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$raiz"

version="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml | head -n1)"
salida="${1:-$raiz}"
nombre="musa-codigo-fuente-${version}"
mkdir -p "$salida"
salida="$(cd "$salida" && pwd)"

excluir=(
  ':(exclude,glob)**/.pw'
  ':(exclude,glob)**/*.p12'
  ':(exclude,glob)**/*.jks'
  ':(exclude,glob)**/*.keystore'
  ':(exclude,glob)**/key.properties'
  ':(exclude,glob)**/firma-local/**'
  ':(exclude,glob)**/mapping*.txt'
  ':(exclude,glob)**/*.symbols'
  ':(exclude,glob)**/scan_out.txt'
  ':(exclude,glob)**/.env'
  ':(exclude,glob)**/.env.*'
  ':(exclude,glob)integration_test/progressive_final_file_harness/loopback-manifests/**'
  ':(exclude,glob)musa-*/**'
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/arbol"

git archive --format=tar HEAD -- . "${excluir[@]}" | tar -x -C "$tmp/arbol"

patrones=(
  'ADMIN_KEY'
  'sp_dc["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9%._-]{20,}'
  'Bearer [A-Za-z0-9._~+/=-]{20,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  '(storePassword|keyPassword)[[:space:]]*[=:][[:space:]]*"[^"$]{4,}"'
)
hallazgos=0
for p in "${patrones[@]}"; do
  coincidencias="$(grep -rIEn --exclude-dir=.git --exclude='exportar_codigo_fuente.*' -e "$p" "$tmp/arbol" | sed "s#$tmp/arbol/##" || true)"
  if [ -n "$coincidencias" ]; then
    echo "Patron '$p':" >&2
    echo "$coincidencias" >&2
    hallazgos=1
  fi
done
if [ -f "$raiz/.pw" ] && [ -s "$raiz/.pw" ]; then
  while IFS= read -r clave; do
    [ -n "$clave" ] || continue
    if grep -rIlF --exclude-dir=.git -e "$clave" "$tmp/arbol"; then hallazgos=1; fi
  done < "$raiz/.pw"
fi
if [ "$hallazgos" -ne 0 ]; then
  echo "ABORTADO: el escaneo de secretos encontro coincidencias (arriba)." >&2
  exit 1
fi
echo "Escaneo de secretos: sin coincidencias."

cat > "$tmp/README-CODIGO-FUENTE.md" <<'R'
# MUSA: codigo fuente

Este paquete contiene el codigo fuente de la aplicacion MUSA correspondiente a
la version publicada.

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
R

git archive --format=zip -9 --prefix "${nombre}/" \
  --add-file="$tmp/README-CODIGO-FUENTE.md" \
  -o "$salida/${nombre}.zip" HEAD -- . "${excluir[@]}"

echo "Paquete: $salida/${nombre}.zip"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$salida/${nombre}.zip"; fi
