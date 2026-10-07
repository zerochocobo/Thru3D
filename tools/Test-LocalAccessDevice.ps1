param([string]$Serial = '2G0YC5ZF7V0664', [switch]$Install)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$package = 'com.wapok.thru3d'
$directory = Join-Path $workspace ('artifacts/device/' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_local_access_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$build = Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
$apk = "$workspace/artifacts/quest3-player-debug.apk"
if ((Get-FileHash $apk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $build.apk_sha256) { throw 'Candidate APK bytes differ from manifest' }
Copy-Item "$workspace/artifacts/build_manifest.json" $directory
& $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-before.txt"
& $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
if ($Install) {
    & $adb -s $Serial install -r $apk | Set-Content "$directory/install.txt"
    if ($LASTEXITCODE -ne 0) { throw 'APK installation failed' }
}
$installed = ((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed APK path unavailable' }
$installedHash = ((& $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed APK differs from candidate' }
function Read-Json([string]$file) {
    $raw = & $adb -s $Serial shell run-as $package cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
$result = @{state='failed';apk_sha256=$build.apk_sha256;installed_sha256=$installedHash;activity_launched=$false;
    scope='Actual Quest private file/provider descriptor preflight, cancellation and timeout; external SAF grants, persistence/reboot, MPV decode and XR not tested'}
try {
    & $adb -s $Serial shell am force-stop $package
    foreach ($case in @('file_present','file_missing','content_present','content_missing','content_denied','cancel','timeout')) {
        $key = 'access_' + [guid]::NewGuid().ToString('N')
        & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_LOCAL_ACCESS" --es request $key --es case $case | Set-Content "$directory/$case-broadcast.txt"
        if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $case" }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $receipt = $null
        do {
            $receipt = Read-Json "debug_request_$key.json"
            if ($receipt) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key -or $receipt.id -le 0) { throw "Rejected or absent receipt: $case" }
        $receipt | ConvertTo-Json -Depth 10 | Set-Content "$directory/$case-receipt.json"
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $report = $null
        do {
            $report = Read-Json "local_access_$($receipt.id).json"
            if ($report -and $report.diagnostic_process -eq $receipt.diagnostic_process -and $report.request_id -eq $receipt.id -and $report.case -eq $case) { break }
            $report = $null
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $report) { throw "Fresh access report absent: $case" }
        $report | ConvertTo-Json -Depth 10 | Set-Content "$directory/$case-report.json"
        Write-Output "Collected $case : $($report.state) / $($report.error) / $($report.elapsed_ms)ms"
    }
    $result.state='collected_scoped_local_access_trace'
} catch { $result.error=$_.Exception.Message }
finally {
    $appPid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    & $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-after.txt"
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'collected_scoped_local_access_trace') { throw $result.error }
& "$workspace/.venv/Scripts/python.exe" "$workspace/benchmarks/local_access_device.py" $directory
if ($LASTEXITCODE -ne 0) {
    $result.state='failed_independent_access_audit'
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    throw 'Independent local access audit failed'
}
