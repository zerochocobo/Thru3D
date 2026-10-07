param(
    [string]$Serial,
    [switch]$Install,
    [switch]$Launch,
    [string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' })
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$devicesOutput = & $adb devices -l
if ($LASTEXITCODE -ne 0) { throw 'adb devices failed.' }
$deviceSerials = @($devicesOutput | Where-Object { $_ -match '^([^\s]+)\s+device(?:\s|$)' } | ForEach-Object { ($_ -split '\s+')[0] })
if ($Serial) {
    if ($Serial -notin $deviceSerials) { throw 'Specified device is not connected and authorized.' }
} elseif ($deviceSerials.Count -eq 1) { $Serial = $deviceSerials[0] }
else { throw "Need one authorized Quest or explicit -Serial. Connected authorized devices: $($deviceSerials.Count)" }
$adbArguments = @('-s',$Serial)
$appId = 'com.wapok.thru3d'
$model = (& $adb @adbArguments shell getprop ro.product.model | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not read device model.' }
if ($model -notmatch '^Quest\s*3$') { throw "Expected Quest 3; observed model: $model. No installation performed." }
$evidenceDirectory = Join-Path $workspace ('artifacts\device\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
& $adb @adbArguments shell getprop 2>&1 | Out-File (Join-Path $evidenceDirectory 'getprop.txt') -Encoding utf8
if ($Install) {
    & $adb @adbArguments install -r (Join-Path $workspace 'artifacts\quest3-player-debug.apk')
    if ($LASTEXITCODE -ne 0) { throw 'Quest APK install failed.' }
}
if ($Launch) {
    & $adb @adbArguments shell am start -n "$appId/com.godot.game.GodotAppLauncher"
    if ($LASTEXITCODE -ne 0) { throw 'Quest activity start failed.' }
    Write-Output 'App launch requested. Collect again after the app has produced its diagnostics.'
} else {
    $capabilityText = (& $adb @adbArguments exec-out run-as $appId cat files/diagnostics/capabilities.json | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'No app capability report yet. Launch the installed Debug app and collect again.' }
    try { $capabilityText | ConvertFrom-Json | Out-Null }
    catch { throw "No valid app capability JSON yet. Start the app in Quest and complete any Horizon OS launch prompt. ADB returned: $($capabilityText.Trim())" }
    $capabilityText | Set-Content (Join-Path $evidenceDirectory 'capabilities.json') -Encoding utf8
    $rvmEvidence = @()
    $profileKeys = @((Get-Content (Join-Path $workspace 'models\manifest\rvm_profiles.json') -Raw | ConvertFrom-Json).profiles.key)
    foreach ($backend in @('cpu', 'vulkan')) {
      foreach ($profile in @('latest') + $profileKeys) {
        $filename = if ($profile -eq 'latest') { "rvm_benchmark_$backend.json" } else { "rvm_benchmark_${backend}_$profile.json" }
        $benchmarkText = (& $adb @adbArguments exec-out run-as $appId cat "files/diagnostics/$filename" 2>&1 | Out-String)
        $benchmark = $null
        if ($LASTEXITCODE -eq 0) { try { $benchmark = $benchmarkText | ConvertFrom-Json } catch { $benchmark = $null } }
        if ($null -ne $benchmark -and $null -ne $benchmark.state) {
            $benchmarkText | Set-Content (Join-Path $evidenceDirectory $filename) -Encoding utf8
            $rvmEvidence += @{ backend = $backend; profile = $profile; report = $filename; state = $benchmark.state; evidence = 'collected' }
        } else {
            $rvmEvidence += @{ backend = $backend; profile = $profile; evidence = 'missing'; note = 'No readable benchmark report; run the Y diagnostic and inspect logcat.' }
        }
      }
    }
    ConvertTo-Json -InputObject @($rvmEvidence) -Depth 5 | Set-Content (Join-Path $evidenceDirectory 'rvm_evidence_index.json') -Encoding utf8
}
& $adb @adbArguments logcat -d -v threadtime 'godot:V' 'VRPassthroughPlayer:V' 'AndroidRuntime:E' '*:S' 2>&1 | Out-File (Join-Path $evidenceDirectory 'logcat.txt') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Quest log collection failed.' }
Write-Output "Evidence: $evidenceDirectory"
