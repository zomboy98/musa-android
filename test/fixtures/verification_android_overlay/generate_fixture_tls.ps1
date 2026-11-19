param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$OpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe'
)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { throw 'Use an absolute external TLS directory' }
$fixtureTlsPath = [IO.Path]::GetFullPath($OutputDirectory)
$fixtureRepoPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ($fixtureTlsPath.StartsWith($fixtureRepoPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture private keys must be outside the checkout'
}
if (Test-Path -LiteralPath $fixtureTlsPath) { throw 'Use a new directory; never overwrite existing keys' }
if (-not (Test-Path -LiteralPath $OpenSsl)) { throw 'OpenSSL executable was not found' }
New-Item -ItemType Directory -Path $fixtureTlsPath | Out-Null
$caKey = Join-Path $fixtureTlsPath 'musa_fixture_ca.key'
$caPem = Join-Path $fixtureTlsPath 'musa_fixture_ca.pem'
$leafKey = Join-Path $fixtureTlsPath 'localhost.key'
$leafCsr = Join-Path $fixtureTlsPath 'localhost.csr'
$leafPem = Join-Path $fixtureTlsPath 'localhost.pem'
$leafExt = Join-Path $fixtureTlsPath 'localhost.ext'
@'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
'@ | Set-Content -LiteralPath $leafExt -Encoding ascii
& rtk $OpenSsl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 -subj '/CN=MUSA Synthetic Test CA' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout $caKey -out $caPem
if ($LASTEXITCODE -ne 0) { throw 'Fixture CA generation failed' }
& rtk $OpenSsl req -new -newkey rsa:2048 -sha256 -nodes -subj '/CN=localhost' -keyout $leafKey -out $leafCsr
if ($LASTEXITCODE -ne 0) { throw 'Fixture leaf request failed' }
& rtk $OpenSsl x509 -req -in $leafCsr -CA $caPem -CAkey $caKey -CAcreateserial -days 2 -sha256 -extfile $leafExt -out $leafPem
if ($LASTEXITCODE -ne 0) { throw 'Fixture leaf signing failed' }
& rtk $OpenSsl verify -CAfile $caPem -verify_hostname localhost $leafPem
if ($LASTEXITCODE -ne 0) { throw 'Fixture certificate validation failed' }
Write-Output 'Fixture TLS prepared. Copy only the CA public PEM into the test-variant raw resource.'
