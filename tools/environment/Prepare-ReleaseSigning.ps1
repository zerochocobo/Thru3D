param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$signingDirectory = Join-Path $workspace 'artifacts\signing'
$credentialsPath = Join-Path $signingDirectory 'thru3d-signing.json'
$keystorePath = Join-Path $signingDirectory 'thru3d-release.keystore'
New-Item -ItemType Directory -Force -Path $signingDirectory | Out-Null
if (-not (Test-Path -LiteralPath $credentialsPath)) {
    if (Test-Path -LiteralPath $keystorePath) { throw 'Existing signing key has no credentials file; do not replace it.' }
    $randomBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
    $signingPassword = -join ($randomBytes | ForEach-Object { $_.ToString('x2') })
    $previousPassword = $env:THRU3D_KEYSTORE_PASSWORD
    try {
        $env:THRU3D_KEYSTORE_PASSWORD = $signingPassword
        $keytool = Join-Path $ToolRoot 'jdk\jdk-17.0.20.1+1\bin\keytool.exe'
        & $keytool -genkeypair -keystore $keystorePath -storetype PKCS12 -alias thru3d -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Thru3D, O=FFSky Studio' -storepass:env THRU3D_KEYSTORE_PASSWORD -keypass:env THRU3D_KEYSTORE_PASSWORD
        if ($LASTEXITCODE -ne 0) { throw 'Release signing key generation failed.' }
        @{ keystore = $keystorePath; alias = 'thru3d'; password = $signingPassword } |
            ConvertTo-Json | Set-Content -LiteralPath $credentialsPath -Encoding utf8
    } finally { $env:THRU3D_KEYSTORE_PASSWORD = $previousPassword }
}
$credentials = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $credentials.keystore)) { throw 'The saved signing key is missing; do not generate a replacement.' }
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH = $credentials.keystore
$env:GODOT_ANDROID_KEYSTORE_RELEASE_USER = $credentials.alias
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = $credentials.password
Write-Output 'Reusable Thru3D release signing key ready (private backup: artifacts/signing).'
