param([string]$Salida = '')
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

$linea = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*([^+\s]+)' | Select-Object -First 1
$version = $linea.Matches[0].Groups[1].Value
if (-not $Salida) { $Salida = $raiz }
New-Item -ItemType Directory -Force -Path $Salida | Out-Null
$Salida = (Resolve-Path $Salida).Path
$nombre = "musa-codigo-fuente-$version"

$excluir = @(
  ':(exclude,glob)**/.pw', ':(exclude,glob)**/*.p12', ':(exclude,glob)**/*.jks',
  ':(exclude,glob)**/*.keystore', ':(exclude,glob)**/key.properties',
  ':(exclude,glob)**/firma-local/**', ':(exclude,glob)**/mapping*.txt',
  ':(exclude,glob)**/*.symbols', ':(exclude,glob)**/scan_out.txt',
  ':(exclude,glob)**/.env', ':(exclude,glob)**/.env.*',
  ':(exclude,glob)integration_test/progressive_final_file_harness/loopback-manifests/**',
  ':(exclude,glob)musa-*/**'
)

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("musa-src-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zipTmp = Join-Path $tmp 'arbol.zip'
  git archive --format=zip -o $zipTmp HEAD -- . @excluir
  if ($LASTEXITCODE -ne 0) { throw 'git archive fallo' }
  $arbol = Join-Path $tmp 'arbol'
  Expand-Archive -Path $zipTmp -DestinationPath $arbol

  $patrones = @(
    'ADMIN_KEY',
    'sp_dc["'']?\s*[=:]\s*["'']?[A-Za-z0-9%._-]{20,}',
    'Bearer [A-Za-z0-9._~+/=-]{20,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'AKIA[0-9A-Z]{16}',
    '(storePassword|keyPassword)\s*[=:]\s*"[^"$]{4,}"'
  )
  $hallazgos = $false
  $archivos = Get-ChildItem -Path $arbol -Recurse -File | Where-Object { $_.Name -notlike 'exportar_codigo_fuente.*' }
  foreach ($p in $patrones) {
    $coinc = $archivos | Select-String -Pattern $p -CaseSensitive -ErrorAction SilentlyContinue
    if ($coinc) {
      $hallazgos = $true
      [Console]::Error.WriteLine("Patron '$p':")
      $coinc | Select-Object -First 20 | ForEach-Object {
        [Console]::Error.WriteLine("$($_.Path.Substring($arbol.Length + 1)):$($_.LineNumber)")
      }
    }
  }
  $pw = Join-Path $raiz '.pw'
  if ((Test-Path $pw) -and (Get-Item $pw).Length -gt 0) {
    foreach ($clave in (Get-Content $pw | Where-Object { $_ })) {
      $coinc = $archivos | Select-String -Pattern $clave -SimpleMatch -List -ErrorAction SilentlyContinue
      if ($coinc) { $hallazgos = $true; $coinc | ForEach-Object { [Console]::Error.WriteLine($_.Path) } }
    }
  }
  if ($hallazgos) { throw 'ABORTADO: el escaneo de secretos encontro coincidencias.' }
  Write-Host 'Escaneo de secretos: sin coincidencias.'

  $readme = Join-Path $tmp 'README-CODIGO-FUENTE.md'
  @'
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
'@ | Set-Content -Path $readme -Encoding utf8

  $destino = Join-Path $Salida "$nombre.zip"
  git archive --format=zip -9 --prefix "$nombre/" "--add-file=$readme" -o $destino HEAD -- . @excluir
  if ($LASTEXITCODE -ne 0) { throw 'git archive fallo' }
  Write-Host "Paquete: $destino"
  (Get-FileHash -Algorithm SHA256 $destino).Hash.ToLower() + "  $nombre.zip"
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
