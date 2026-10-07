param([string]$Serial='2G0YC5ZF7V0664', [ValidateSet('256x144','384x216','512x288','256x256','384x384','512x512')][string]$Profile='384x216', [switch]$Install, [switch]$LegacyFullFrameReference, [switch]$LegacyAspectReference, [switch]$Ordered)
$ErrorActionPreference='Stop'
if ($LegacyFullFrameReference -and $LegacyAspectReference) { throw 'Select only one legacy reference' }
$workspace=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$package='com.wapok.thru3d'
$key='motion_'+[guid]::NewGuid().ToString('N')
$directory=Join-Path $workspace ('artifacts/device/'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+$key)
New-Item -ItemType Directory -Force $directory | Out-Null
$remote="/data/local/tmp/$key.mp4"
$build=Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
$fixture=Get-Content "$workspace/tests/fixtures/mp07_motion_4k.json" -Raw | ConvertFrom-Json
$source=Join-Path $workspace $fixture.file
if ((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fixture.sha256) { throw 'Motion fixture differs from lock' }
Copy-Item "$workspace/artifacts/build_manifest.json" $directory
Copy-Item $PSCommandPath "$directory/acquisition-script.ps1"
Copy-Item "$workspace/benchmarks/mpv_motion_probe.py" "$directory/acquisition-verifier.py"
function Read-Json([string]$name) {
    $raw=& $adb -s $Serial shell run-as $package cat "files/diagnostics/$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
try {
    & $adb -s $Serial shell am force-stop $package
    if ($Install) {
        & $adb -s $Serial install -r "$workspace/artifacts/quest3-player-debug.apk" | Set-Content "$directory/install.txt"
        if ($LASTEXITCODE -ne 0) { throw 'APK installation failed' }
    }
    $path=((& $adb -s $Serial shell pm path $package | Select-String '/base.apk$' | Select-Object -First 1).ToString()) -replace '^package:',''
    if ($path -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed APK path unavailable' }
    $installed=((& $adb -s $Serial shell sha256sum $path) -split '\s+')[0]
    if ($installed -ne $build.apk_sha256) { throw 'Installed APK differs from build' }
    @{apk_sha256=$build.apk_sha256; installed_sha256=$installed; serial=$Serial; profile=$Profile; ordered_frames=[bool]$Ordered;
        acquisition_sha256=(Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
        verifier_sha256=(Get-FileHash "$workspace/benchmarks/mpv_motion_probe.py" -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content "$directory/installed.json"
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
    & $adb -s $Serial shell dumpsys thermalservice | Set-Content "$directory/thermal-before.txt"
    & $adb -s $Serial push $source $remote | Set-Content "$directory/fixture-push.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Fixture transfer failed' }
    & $adb -s $Serial shell run-as $package mkdir -p files/fixtures
    & $adb -s $Serial shell run-as $package cp $remote files/fixtures/mp07_motion_4k.mp4
    if ($LASTEXITCODE -ne 0) { throw 'Private fixture copy failed' }
    & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_MPV_MOTION" --es request $key --es profile $Profile --ez ordered ([bool]$Ordered).ToString().ToLowerInvariant() | Set-Content "$directory/broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Motion request failed' }
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do { $receipt=Read-Json "debug_request_$key.json"; if ($receipt) { break }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $deadline)
    if (!$receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw 'Motion request not accepted' }
    $receipt | ConvertTo-Json | Set-Content "$directory/request.json"
    $deadline=[DateTime]::UtcNow.AddSeconds($(if ($Ordered) {330} else {120}))
    do {
        $candidate=Read-Json "mpv_motion_$($receipt.id).json"
        if ($candidate -and $candidate.request_id -eq $receipt.id -and
            $candidate.diagnostic_process -eq $receipt.diagnostic_process -and $candidate.profile -eq $Profile) {
            $report=$candidate; break
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    $appPid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    if (!$report) { throw "No terminal report; inspect process before retry: $directory" }
    $report | ConvertTo-Json -Depth 50 | Set-Content "$directory/report.json"
    if ($report.request_id -ne $receipt.id -or $report.diagnostic_process -ne $receipt.diagnostic_process) { throw 'Motion report belongs to another process/request' }
    if ([bool]$report.ordered_frames -ne [bool]$Ordered) { throw 'Motion ordering differs from request' }
    if ($report.state -ne 'passed_native_checks') { throw "Motion native failure: $($report.error); evidence: $directory" }
    $referenceArgs=@()
    if ($LegacyAspectReference) { $referenceArgs+='--aspect-reference' }
    elseif (!$LegacyFullFrameReference) { $referenceArgs+='--yuv-aspect-reference' }
    & "$workspace/.venv/Scripts/python.exe" "$workspace/benchmarks/mpv_motion_probe.py" "$directory/report.json" --adb $adb --serial $Serial @referenceArgs
    if ($LASTEXITCODE -ne 0) { throw "Independent motion audit failed: $directory" }
} finally {
    & $adb -s $Serial shell rm -f $remote
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    & $adb -s $Serial shell dumpsys thermalservice | Set-Content "$directory/thermal-after.txt"
    Write-Output "Evidence: $directory"
}
