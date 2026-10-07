param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$Regenerate)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$workspace\tools\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$python = Join-Path $workspace '.venv\Scripts\python.exe'
$pnnx = Join-Path $ToolRoot 'pnnx\20260704\pnnx-20260704-windows\pnnx.exe'
if (-not (Test-Path -LiteralPath $pnnx)) { throw 'Install the pinned pnnx portable 20260704 package; see the R00 implementation document.' }
$toolchain = Get-Content (Join-Path $workspace 'tools\environment\toolchain.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $pnnx -Algorithm SHA256).Hash.ToLowerInvariant() -ne $toolchain.pnnx.exe_sha256) { throw 'Pinned pnnx executable hash changed.' }
$modelManifest = Get-Content (Join-Path $workspace 'models\manifest\rvm_mobilenetv3.json') -Raw | ConvertFrom-Json
$source = Join-Path $workspace $modelManifest.file
if (-not (Test-Path -LiteralPath $source)) { & "$PSScriptRoot\Prepare-RvmReference.ps1" }
if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $modelManifest.sha256) { throw 'Source RVM hash changed.' }
$profiles = Get-Content (Join-Path $workspace 'models\manifest\rvm_profiles.json') -Raw | ConvertFrom-Json
foreach ($entry in $profiles.profiles) {
    $profile = Join-Path $workspace "build\rvm\$($entry.key)"
    $report = Join-Path $workspace "artifacts\rvm-ncnn-reference\$($entry.key)\report.json"
    if ($Regenerate -or -not (Test-Path -LiteralPath (Join-Path $profile 'rvm.ncnn.bin')) -or -not (Test-Path -LiteralPath $report)) {
        & $python "$PSScriptRoot\convert_rvm.py" --width $entry.width --height $entry.height --pnnx $pnnx --output $profile
        if ($LASTEXITCODE -ne 0) { throw "Full recurrent RVM conversion failed: $($entry.key)" }
        & $python "$workspace\benchmarks\rvm_ncnn_reference.py" --profile $profile --output (Split-Path -Parent $report)
        if ($LASTEXITCODE -ne 0) { throw "RVM ncnn sequence verification failed: $($entry.key)" }
    }
}
& $python "$PSScriptRoot\prepare_rvm_assets.py"
if ($LASTEXITCODE -ne 0) { throw 'Verified RVM assets could not be prepared.' }
& $python "$workspace\benchmarks\rvm_profile_package.py"
if ($LASTEXITCODE -ne 0) { throw 'RVM profile/oracle package integrity failed.' }
& $python "$PSScriptRoot\prepare_rvm_mnn.py"
if ($LASTEXITCODE -ne 0) { throw 'MNN OpenCL RVM model could not be prepared.' }
