param([string]$FromDirectory, [switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$catalog = Get-Content (Join-Path $workspace 'models/manifest/runtime-assets.json') -Raw | ConvertFrom-Json
$assetRoot = Join-Path $workspace 'android/player-plugin/src/main/assets'
if (-not $VerifyOnly -and -not $FromDirectory) { throw 'Pass -FromDirectory with a version-matched model asset directory. See docs/MODELS.md.' }
$sourceRoot = if ($VerifyOnly) { $assetRoot } else { (Resolve-Path -LiteralPath $FromDirectory).Path }
# Verify the complete input before copying any file. The catalog is committed metadata.
foreach ($asset in $catalog.assets) {
    if ($asset.path -notmatch '^(rvm-mnn/rvm\.mnn|depth-mnn/depth\.mnn)$') { throw 'Unexpected model asset path.' }
    $source = Join-Path $sourceRoot $asset.path
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing model: $($asset.path). See docs/MODELS.md." }
    if ((Get-Item -LiteralPath $source).Length -ne $asset.bytes -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) {
        throw "Model differs from the source snapshot: $($asset.path)"
    }
}
if ($VerifyOnly) {
    $header = Join-Path $workspace 'build/rvm/include/rvm_profiles.generated.h'
    $contract = Join-Path $workspace 'models/contracts/rvm_profiles.generated.h'
    if (-not (Test-Path -LiteralPath $header) -or (Get-FileHash -LiteralPath $header).Hash -ne (Get-FileHash -LiteralPath $contract).Hash) {
        throw 'Missing or mismatched native profile contract; rerun Import-ModelAssets.ps1 -FromDirectory.'
    }
    foreach ($name in @('rvm-mnn', 'depth-mnn')) {
        $manifest = Get-Content (Join-Path $assetRoot "$name/manifest.json") -Raw | ConvertFrom-Json
        $record = @($catalog.assets | Where-Object { $_.path.StartsWith("$name/") })[0]
        if ($manifest.mnn_sha256 -ne $record.sha256) { throw "Model manifest mismatch: $name" }
    }
    Write-Output 'Version-matched runtime model assets verified.'
    return
}
foreach ($asset in $catalog.assets) {
    $target = Join-Path $assetRoot $asset.path
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot $asset.path) -Destination $target -Force
}
$headerDirectory = Join-Path $workspace 'build/rvm/include'
New-Item -ItemType Directory -Path $headerDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $workspace 'models/contracts/rvm_profiles.generated.h') -Destination $headerDirectory -Force
foreach ($name in @('rvm-mnn', 'depth-mnn')) {
    $catalog.manifests.$name | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $assetRoot "$name/manifest.json") -Encoding utf8
}
$rvmLicense = Join-Path $workspace 'models/licenses/RVM_GPL-3.0.txt'
$rvmRoot = Join-Path $assetRoot 'rvm'
New-Item -ItemType Directory -Path $rvmRoot -Force | Out-Null
Copy-Item -LiteralPath $rvmLicense -Destination (Join-Path $rvmRoot 'RVM_GPL-3.0.txt') -Force
Copy-Item -LiteralPath $rvmLicense -Destination (Join-Path $assetRoot 'rvm-mnn/RVM_GPL-3.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $workspace 'models/licenses/DepthAnythingV2_Apache-2.0.txt') -Destination (Join-Path $assetRoot 'depth-mnn/LICENSE-DepthAnythingV2-Small.txt') -Force
$licenseInfo = Get-Item -LiteralPath $rvmLicense
@{ assets = @(@{ path = 'rvm/RVM_GPL-3.0.txt'; bytes = $licenseInfo.Length; sha256 = (Get-FileHash -LiteralPath $rvmLicense).Hash.ToLowerInvariant() }) } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $rvmRoot 'bundle_manifest.json') -Encoding utf8
Write-Output 'Imported verified models; all model files remain ignored by Git.'
