param([string]$Serial='2G0YC5ZF7V0664',[switch]$Install,[switch]$HalfStorage)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$package='com.wapok.thru3d'
$directory=Join-Path $workspace ('artifacts/device/'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_rvm_standalone_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$build=Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
Copy-Item "$workspace/artifacts/build_manifest.json" $directory
if ((Get-FileHash "$workspace/artifacts/quest3-player-debug.apk" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $build.apk_sha256) { throw 'APK bytes differ' }
& $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
& $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-before.txt"
if ($Install) {
    & $adb -s $Serial install -r "$workspace/artifacts/quest3-player-debug.apk" | Set-Content "$directory/install.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Install failed' }
}
$installed=((& $adb -s $Serial shell pm path $package | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:','')
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed path unavailable' }
$installedHash=((& $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed hash differs' }
function Read-Json([string]$file) {
    $raw=& $adb -s $Serial shell run-as $package cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
$result=@{state='failed';apk_sha256=$build.apk_sha256;installed_sha256=$installedHash;activity_launched=$false;
    scope='Actual Quest production CPU/Vulkan full-output and resident/JNI synthetic recurrence; no video/XR/quality/thermal validation'}
$profiles=@('256x144','384x216','512x288','256x256','384x384','512x512')
if ($HalfStorage) { $result.scope='Quest GPU FP16 storage/FP32 arithmetic diagnostic candidate; independent four-frame eye states; no video/XR/quality/thermal acceptance' }
$remote='/data/local/tmp/rvm_'+[guid]::NewGuid().ToString('N')+'.tar'
try {
    & $adb -s $Serial shell am force-stop $package
    & "$workspace/.venv/Scripts/python.exe" "$workspace/benchmarks/rvm_standalone_device.py" prepare $directory
    if ($LASTEXITCODE -ne 0) { throw 'Independent fixture preparation rejected' }
    & $adb -s $Serial push "$directory/fixtures.tar" $remote | Set-Content "$directory/fixture-push.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Fixture push failed' }
    & $adb -s $Serial shell run-as $package mkdir -p files/rvm-resident-fixtures
    & $adb -s $Serial shell run-as $package tar -xf $remote -C files/rvm-resident-fixtures
    if ($LASTEXITCODE -ne 0) { throw 'Fixture extraction failed' }
    foreach ($profile in $profiles) {
        $manifest=Get-Content "$workspace/build/rvm-resident-fixtures/$profile/manifest.json" -Raw | ConvertFrom-Json
        $paths=@($manifest.files.PSObject.Properties.Name | Sort-Object | ForEach-Object { "files/rvm-resident-fixtures/$profile/$_" })
        & $adb -s $Serial shell run-as $package sha256sum @paths | Set-Content "$directory/$profile-device-fixtures.sha256"
        if ($LASTEXITCODE -ne 0) { throw 'Device fixture hashes unavailable' }
    }
    $modes=if ($HalfStorage) { @('resident_fp16_storage') } else { @('cpu','vulkan','resident') }
    foreach ($mode in $modes) {
        foreach ($profile in $profiles) {
            $case=$mode+'_'+$profile
            $key='rvm_'+[guid]::NewGuid().ToString('N')
            & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_RVM_STANDALONE" --es request $key --es mode $mode --es profile $profile | Set-Content "$directory/$case-broadcast.txt"
            if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $case" }
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            $receipt=$null
            do {
                $receipt=Read-Json "debug_request_$key.json"
                if ($receipt) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.id -le 0 -or $receipt.request -ne $key) { throw "Rejected receipt: $case" }
            $receipt | ConvertTo-Json -Depth 20 | Set-Content "$directory/$case-receipt.json"
            $casePid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
            if ($casePid -notmatch '^\d+$') { throw "Process absent after accepted receipt: $case" }
            $casePid | Set-Content "$directory/$case-pid.txt"
            $deadline=[DateTime]::UtcNow.AddSeconds(180)
            $report=$null
            $nextProcessCheck=[DateTime]::UtcNow.AddSeconds(2)
            do {
                $report=Read-Json "rvm_standalone_$($receipt.id).json"
                if ($report -and $report.probe_id -eq $receipt.id -and $report.diagnostic_process -eq $receipt.diagnostic_process -and $report.mode -eq $mode -and $report.requested_profile -eq $profile) { break }
                $report=$null
                if ([DateTime]::UtcNow -ge $nextProcessCheck) {
                    $currentPid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
                    if ($currentPid -ne $casePid) { throw "Diagnostic process exited or changed: $case (expected PID $casePid)" }
                    $nextProcessCheck=[DateTime]::UtcNow.AddSeconds(2)
                }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $report) { throw "Fresh report absent: $case" }
            $report | ConvertTo-Json -Depth 40 | Set-Content "$directory/$case-report.json"
            Write-Output "Collected $case : $($report.state) / $($report.elapsed_ms)ms"
            if ($report.state -ne 'passed' -and -not ($HalfStorage -and $report.state -eq 'failed')) { throw "Native numerical check failed: $case" }
        }
    }
    $result.state='collected_scoped_rvm_trace'
} catch { $result.error=$_.Exception.Message }
finally {
    # A crashed process has no live PID; retain tombstone/backtrace evidence too.
    & $adb -s $Serial logcat -d -b crash -v threadtime | Set-Content "$directory/crash-logcat.txt"
    $appPid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell rm -f $remote
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    & $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-after.txt"
    $result | ConvertTo-Json -Depth 20 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'collected_scoped_rvm_trace') { throw $result.error }
$verifier=if ($HalfStorage) { 'benchmarks/native_rvm_resident/verify_half_storage.py' } else { 'benchmarks/rvm_standalone_device.py' }
& "$workspace/.venv/Scripts/python.exe" "$workspace/$verifier" verify $directory
if ($LASTEXITCODE -ne 0) { throw 'Independent device RVM audit rejected' }
