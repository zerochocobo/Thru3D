param([string]$Serial='2G0YC5ZF7V0664',[switch]$Install)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$package='com.wapok.thru3d'
$provider='org.vrpassthroughplayer.urifixture'
$directory=Join-Path $workspace ('artifacts/device/'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_selection_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$build=Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
Copy-Item "$workspace/artifacts/build_manifest.json" $directory
if ((Get-FileHash "$workspace/artifacts/quest3-player-debug.apk" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $build.apk_sha256) { throw 'Local APK differs' }
& $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-before.txt"
& $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
if ($Install) {
    & $adb -s $Serial install -r "$workspace/artifacts/quest3-player-debug.apk" | Set-Content "$directory/install.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Player install failed' }
    & $adb -s $Serial install -r "$workspace/android/uri-fixture/build/outputs/apk/debug/uri-fixture-debug.apk" | Set-Content "$directory/provider-install.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Provider install failed' }
}
$installed=((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:',''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed path unavailable' }
$installedHash=((& $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed APK differs' }
function Read-Json([string]$target,[string]$file) {
    $raw=& $adb -s $Serial shell run-as $target cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
function Provider([string]$operation) {
    $key='selection_'+[guid]::NewGuid().ToString('N')
    & $adb -s $Serial shell am broadcast -n "$provider/.FixtureCommandReceiver" --es request $key --es operation $operation | Set-Content "$directory/provider-$operation-broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Provider command failed' }
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do {
        $r=Read-Json $provider "$key.json"
        if ($r -and $r.request -eq $key) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $r -or $r.state -ne 'applied') { throw 'Provider receipt absent/rejected' }
    $r | ConvertTo-Json -Depth 10 | Set-Content "$directory/provider-$operation.json"
}
$result=@{state='failed';apk_sha256=$build.apk_sha256;installed_sha256=$installedHash;activity_launched=$false;
    scope='Actual production selection worker/metadata/cancellation/deadline and main heartbeat; private slow provider + real external granted document; system picker UI, Godot/XR/playback unverified'}
try {
    & $adb -s $Serial shell am force-stop $package
    Provider 'restore'
    Provider 'revoke'
    Provider 'offer_persistable'
    foreach ($case in @('unicode','long','blank','no_column','metadata_denied','missing','permission_denied','cancel','timeout','replace_late','close_late','external')) {
        $key='selection_'+[guid]::NewGuid().ToString('N')
        & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_LOCAL_SELECTION" --es request $key --es case $case | Set-Content "$directory/$case-broadcast.txt"
        if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $case" }
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        do {
            $receipt=Read-Json $package "debug_request_$key.json"
            if ($receipt -and $receipt.request -eq $key) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.id -le 0) { throw "Rejected: $case" }
        $receipt | ConvertTo-Json -Depth 10 | Set-Content "$directory/$case-receipt.json"
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        do {
            $r=Read-Json $package "selection_$($receipt.id).json"
            if ($r -and $r.case -eq $case -and $r.request_id -eq $receipt.id -and $r.diagnostic_process -eq $receipt.diagnostic_process) { break }
            $r=$null
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $r) { throw "Fresh selection report absent: $case" }
        $r | ConvertTo-Json -Depth 20 | Set-Content "$directory/$case-report.json"
        Write-Output "Collected $case : events=$($r.events.Count), start=$($r.start_return_ms)ms, main gap=$($r.main_max_gap_ms)ms"
    }
    $result.state='collected_scoped_selection_trace'
} catch { $result.error=$_.Exception.Message }
finally {
    $appPid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    Provider 'revoke'
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell am force-stop $provider
    & $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-after.txt"
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'collected_scoped_selection_trace') { throw $result.error }
& "$workspace/.venv/Scripts/python.exe" "$workspace/benchmarks/local_selection_device.py" $directory
if ($LASTEXITCODE -ne 0) {
    $result.state='failed_independent_selection_audit'
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    throw 'Independent selection audit failed'
}
