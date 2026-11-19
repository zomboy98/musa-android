# Public beta build: MUSA as a bare player, without any bundled add-on.
# Usage: scripts/build_publico.ps1 [extra flutter build apk args]
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets/bundled_extensions'
$stash = Join-Path ([IO.Path]::GetTempPath()) ("musa_sflx_" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stash | Out-Null
try {
  Set-Location $root
  Move-Item (Join-Path $assets '*.sflx') $stash
  Set-Content -Path (Join-Path $assets 'manifest.json') -Value '{"extensions": []}'
  flutter build apk --release --split-per-abi --dart-define=MUSA_PUBLIC=true @args
  if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
} finally {
  Get-ChildItem $stash -Filter *.sflx -ErrorAction SilentlyContinue | Move-Item -Destination $assets
  git -C $root checkout -- assets/bundled_extensions/manifest.json
  Remove-Item $stash -Recurse -Force -ErrorAction SilentlyContinue
}
