param(
    [Parameter(Mandatory)][string]$Sdk,
    [Parameter(Mandatory)][string]$AvdHome,
    [Parameter(Mandatory)][string]$AvdName,
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$Fixture,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][string]$AarLibDir,
    [Parameter(Mandatory)][string]$PrivateSo,
    [Parameter(Mandatory)][string]$CoexistExecutable,
    [int]$Port = 5592
)
$ErrorActionPreference = 'Stop'
$serial = "emulator-$Port"
$adb = Join-Path $Sdk 'platform-tools/adb.exe'
$emulator = Join-Path $Sdk 'emulator/emulator.exe'
$run = Join-Path $EvidenceRoot ("mornye-cenc-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $run | Out-Null
if (Get-NetTCPConnection -LocalPort $Port,($Port + 1) -State Listen -ErrorAction SilentlyContinue) { throw 'Emulator ports occupied' }
$devices = & $adb devices
if ($devices -match [regex]::Escape($serial)) { throw 'Serial already in use' }
& python (Join-Path $PSScriptRoot 'truncate_fixture.py') $Fixture (Join-Path $run 'truncated.mp4')
if ($LASTEXITCODE) { throw 'Truncated fixture creation failed' }
$env:ANDROID_AVD_HOME = $AvdHome
$env:ANDROID_USER_HOME = $run
$env:ANDROID_SDK_ROOT = $Sdk
$proc = $null
try {
    $proc = Start-Process -FilePath $emulator -ArgumentList @('-avd', $AvdName, '-port', $Port, '-no-window', '-no-audio', '-no-snapshot', '-no-boot-anim', '-memory', '1536', '-gpu', 'swiftshader_indirect') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'emulator.out') -RedirectStandardError (Join-Path $run 'emulator.err')
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ($proc.HasExited) { throw 'Emulator exited' }
        $ErrorActionPreference = 'Continue'
        $state = & $adb -s $serial get-state 2>$null
        $ErrorActionPreference = 'Stop'
        if ($state -eq 'device') { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'Emulator timeout' }
    $remote = '/data/local/tmp/mornye-cenc-' + [guid]::NewGuid().ToString('N')
    & $adb -s $serial shell mkdir -p $remote
    if ($LASTEXITCODE) { throw 'mkdir failed' }
    & $adb -s $serial push $Executable "$remote/test"
    if ($LASTEXITCODE) { throw 'test push failed' }
    & $adb -s $serial push $Fixture "$remote/fixture.mp4"
    if ($LASTEXITCODE) { throw 'fixture push failed' }
    & $adb -s $serial push (Join-Path $run 'truncated.mp4') "$remote/truncated.mp4"
    if ($LASTEXITCODE) { throw 'truncated push failed' }
    & $adb -s $serial push "$AarLibDir/." "$remote/"
    if ($LASTEXITCODE) { throw 'AAR libraries push failed' }
    & $adb -s $serial push $PrivateSo "$remote/libmornye_private_mov.so"
    if ($LASTEXITCODE) { throw 'private library push failed' }
    & $adb -s $serial push $CoexistExecutable "$remote/coexist"
    if ($LASTEXITCODE) { throw 'coexist test push failed' }
    $stream = [IO.File]::OpenRead($PrivateSo)
    try { $localHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose() }
    $remoteHash = ((& $adb -s $serial shell sha256sum "$remote/libmornye_private_mov.so") -split '\s+')[0].ToLowerInvariant()
    if ($LASTEXITCODE -or $localHash -ne $remoteHash) { throw 'Private library hash mismatch' }
    "private-so-sha256=$localHash local=remote" | Set-Content (Join-Path $run 'hashes.txt')
    & $adb -s $serial shell "cd $remote && chmod 755 test && LD_LIBRARY_PATH=. ./test" | Tee-Object -FilePath (Join-Path $run 'test-result.txt')
    if ($LASTEXITCODE) { throw 'Native test failed' }
    & $adb -s $serial pull "$remote/ok.flac" (Join-Path $run 'ok.flac')
    if ($LASTEXITCODE) { throw 'Output pull failed' }
    & python (Join-Path $PSScriptRoot 'verify_pcm.py') (Join-Path $run 'ok.flac') | Tee-Object -Append -FilePath (Join-Path $run 'test-result.txt')
    if ($LASTEXITCODE) { throw 'PCM comparison failed' }
    & $adb -s $serial shell "cd $remote && chmod 755 coexist && LD_LIBRARY_PATH=. ./coexist" | Tee-Object -Append -FilePath (Join-Path $run 'test-result.txt')
    if ($LASTEXITCODE) { throw 'Coexistence test failed' }
    & $adb -s $serial shell "cd $remote && LD_LIBRARY_PATH=. ./coexist private-first" | Tee-Object -Append -FilePath (Join-Path $run 'test-result.txt')
    if ($LASTEXITCODE) { throw 'Private-first coexistence test failed' }
} finally {
    if ($proc -and -not $proc.HasExited) { & $adb -s $serial emu kill; $proc.WaitForExit(15000) | Out-Null }
    Write-Output "Evidence directory: $run"
}
