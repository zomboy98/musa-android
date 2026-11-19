<#
.SYNOPSIS
  Mide la fluidez del desplazamiento en el telefono (por ejemplo el Galaxy S24 FE)
  con dumpsys gfxinfo, y registra la tasa de refresco activa.

.DESCRIPTION
  NO se ejecuta sola: es para cuando Alex diga "armala". Usa adb, asi que el
  telefono debe estar conectado con depuracion USB y la app abierta en la
  pantalla que se quiere medir (Inicio, Biblioteca, cola...).

  Pasos:
    1. Lee la tasa de refresco activa (dumpsys display) y el ajuste del sistema.
    2. dumpsys gfxinfo <paquete> reset
    3. Desliza N veces con "input swipe" (abajo y arriba alternando).
    4. Vuelca gfxinfo (frames totales, janky, percentiles 50/90/95/99) en un
       archivo de texto con fecha dentro de -Salida.

  Nota: una compilacion debug es mucho mas lenta que una de perfil o release.
  Para cifras comparables, mide con "flutter build apk --profile" cuando se
  pueda; con debug solo sirve para comparar antes y despues en el mismo modo.

.PARAMETER Paquete
  Id del paquete de la app (por defecto el configurado en android/app/build.gradle).

.PARAMETER Veces
  Cantidad de deslizamientos (por defecto 30).

.PARAMETER Duracion
  Milisegundos de cada deslizamiento (por defecto 350).

.PARAMETER Dispositivo
  Serie de adb (-s) si hay mas de un dispositivo.

.PARAMETER Salida
  Carpeta donde se guardan los resultados (por defecto .\medicion-scroll).

.EXAMPLE
  .\scripts\medir_scroll_s24.ps1 -Veces 40
#>
[CmdletBinding()]
param(
  [string]$Paquete = '',
  [int]$Veces = 30,
  [int]$Duracion = 350,
  [string]$Dispositivo = '',
  [string]$Salida = (Join-Path (Get-Location) 'medicion-scroll'),
  [string]$Adb = 'adb'
)

$ErrorActionPreference = 'Stop'

function Invoke-Adb {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argumentos)
  $todos = @()
  if ($Dispositivo) { $todos += @('-s', $Dispositivo) }
  $todos += $Argumentos
  & $Adb @todos
}

if (-not $Paquete) {
  $gradle = Join-Path $PSScriptRoot '..\android\app\build.gradle.kts'
  if (-not (Test-Path $gradle)) {
    $gradle = Join-Path $PSScriptRoot '..\android\app\build.gradle'
  }
  if (Test-Path $gradle) {
    $m = Select-String -Path $gradle -Pattern 'applicationId\s*=?\s*"([^"]+)"' |
      Select-Object -First 1
    if ($m) { $Paquete = $m.Matches[0].Groups[1].Value }
  }
}
if (-not $Paquete) {
  throw 'No se pudo deducir el paquete: pasalo con -Paquete.'
}

New-Item -ItemType Directory -Force -Path $Salida | Out-Null
$sello = Get-Date -Format 'yyyyMMdd-HHmmss'
$archivo = Join-Path $Salida "scroll-$sello.txt"

# Tamano de pantalla para calcular el recorrido del deslizamiento.
$tam = (Invoke-Adb shell wm size) -join ' '
if ($tam -match '(\d+)x(\d+)') {
  $ancho = [int]$Matches[1]; $alto = [int]$Matches[2]
} else {
  $ancho = 1080; $alto = 2340
}
$x = [int]($ancho / 2)
$yAlto = [int]($alto * 0.75)
$yBajo = [int]($alto * 0.30)

$informe = New-Object System.Collections.Generic.List[string]
$informe.Add("Medicion de scroll $sello")
$informe.Add("Paquete: $Paquete   Deslizamientos: $Veces   Duracion: $Duracion ms")
$informe.Add('')

# Tasa de refresco activa y modos soportados.
$informe.Add('== Tasa de refresco ==')
$display = Invoke-Adb shell dumpsys display
$informe.Add(($display | Select-String -Pattern 'mActiveModeId|activeModeId|mRefreshRate|renderFrameRate|fps=|DisplayModeRecord' |
  Select-Object -First 30 | ForEach-Object { $_.Line.Trim() }))
$informe.Add('Ajuste del sistema:')
$informe.Add((Invoke-Adb shell settings get system peak_refresh_rate) -join ' ')
$informe.Add((Invoke-Adb shell settings get system min_refresh_rate) -join ' ')
$informe.Add('')

Write-Host "Reiniciando contadores de gfxinfo de $Paquete..."
Invoke-Adb shell dumpsys gfxinfo $Paquete reset | Out-Null

Write-Host "Deslizando $Veces veces..."
for ($i = 0; $i -lt $Veces; $i++) {
  if ($i % 2 -eq 0) {
    Invoke-Adb shell input swipe $x $yAlto $x $yBajo $Duracion
  } else {
    Invoke-Adb shell input swipe $x $yBajo $x $yAlto $Duracion
  }
  Start-Sleep -Milliseconds 250
}

Write-Host 'Volcando gfxinfo...'
$gfx = Invoke-Adb shell dumpsys gfxinfo $Paquete
$informe.Add('== gfxinfo (resumen) ==')
$informe.Add(($gfx | Select-String -Pattern 'Total frames rendered|Janky frames|Number (Missed Vsync|High input latency|Slow UI thread|Slow bitmap uploads|Slow issue draw commands|Frame deadline missed)|50th|90th|95th|99th|Profile data' |
  ForEach-Object { $_.Line.Trim() }))
$informe.Add('')
$informe.Add('== gfxinfo (completo) ==')
$informe.Add($gfx)

$informe | Out-File -FilePath $archivo -Encoding utf8
Write-Host "Listo: $archivo"
$gfx | Select-String -Pattern 'Total frames rendered|Janky frames|50th|90th|95th|99th' |
  ForEach-Object { Write-Host $_.Line.Trim() }
