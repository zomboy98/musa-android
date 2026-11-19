param(
    [Parameter(Mandatory)][string]$Ndk,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$OutputRoot
)
$ErrorActionPreference = 'Stop'
$bin = Join-Path $Ndk 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $bin 'clang.exe'
$readelf = Join-Path $bin 'llvm-readelf.exe'
$targets = @{'x86_64'='x86_64-linux-android24'; 'arm64-v8a'='aarch64-linux-android24'; 'armeabi-v7a'='armv7a-linux-androideabi24'}
if (Test-Path $OutputRoot) { throw 'Output directory must not exist' }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
foreach ($abi in $targets.Keys) {
    $root = Join-Path $InstallRoot $abi
    $out = Join-Path $OutputRoot $abi
    New-Item -ItemType Directory -Path $out | Out-Null
    $archives = @('libavformat.a', 'libavcodec.a', 'libavutil.a') | ForEach-Object { Join-Path $root "lib/$_" }
    foreach ($archive in $archives) { if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Missing archive: $archive" } }
    & $clang "--target=$($targets[$abi])" -shared -fPIC -fvisibility=hidden -Wall -Wextra -Werror "-I$root/include" (Join-Path $PSScriptRoot 'private_mov.c') "-Wl,--version-script=$PSScriptRoot/exports.map" '-Wl,--exclude-libs,ALL' '-Wl,-soname,libmornye_private_mov.so' @archives -lz -lm -o (Join-Path $out 'libmornye_private_mov.so')
    if ($LASTEXITCODE) { throw "Link failed: $abi" }
    & $readelf --dyn-syms --wide (Join-Path $out 'libmornye_private_mov.so') | Set-Content (Join-Path $out 'dyn-syms.txt')
    if ($LASTEXITCODE) { throw "readelf failed: $abi" }
    & $readelf -d (Join-Path $out 'libmornye_private_mov.so') | Set-Content (Join-Path $out 'dynamic.txt')
    if ($LASTEXITCODE) { throw "readelf failed: $abi" }
    $symbols = Get-Content (Join-Path $out 'dyn-syms.txt') -Raw
    $dynamic = Get-Content (Join-Path $out 'dynamic.txt') -Raw
    if ($symbols -match '(?m)\b(?:av|ff)[a-zA-Z0-9_]+(?:@\S+)?(?:\s|$)') { throw "libav symbol exposed or imported: $abi" }
    if ($dynamic -match '(?i)Shared library: \[lib(?:av|sw)[^]]*\]') { throw "Shared FFmpeg dependency: $abi" }
    if ($dynamic -notmatch 'SONAME.*\[libmornye_private_mov\.so\]') { throw "Missing private SONAME: $abi" }
    if ($symbols -notmatch 'mornye_private_mov@@MORNYE_PRIVATE_MOV_1') { throw "Missing bridge export: $abi" }
    if ($symbols -notmatch 'mornye_private_mov_fd_v1@@MORNYE_PRIVATE_MOV_1') { throw "Missing descriptor bridge export: $abi" }
}
