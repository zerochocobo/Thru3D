param([string]$ExistingModel)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifest = Get-Content (Join-Path $workspace 'models\manifest\rvm_mobilenetv3.json') -Raw | ConvertFrom-Json
$destination = Join-Path $workspace $manifest.file
New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
if ($ExistingModel) {
    $hash = (Get-FileHash -LiteralPath $ExistingModel -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $manifest.sha256) { throw 'Existing RVM model does not match the pinned model hash.' }
    Copy-Item -LiteralPath $ExistingModel -Destination $destination -Force
} else {
    & "$workspace\tools\environment\Download-Artifact.ps1" -Uri $manifest.source -Destination $destination -Sha256 $manifest.sha256 -ExpectedBytes $manifest.bytes
    if ($LASTEXITCODE -ne 0) { throw 'RVM model download failed.' }
}
Write-Output "Prepared CPU reference model: $destination"

