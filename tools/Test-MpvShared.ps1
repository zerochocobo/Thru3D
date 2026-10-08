param([Parameter(Mandatory=$true)][string]$Serial, [switch]$Hardware, [switch]$Install,
    [ValidateSet('Shared','Audio')][string]$Diagnostic = 'Shared')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$package = 'com.wapok.thru3d'
$apk = Join-Path $workspace 'artifacts\quest3-player-debug.apk'
$manifest = Get-Content (Join-Path $workspace 'artifacts\build_manifest.json') -Raw | ConvertFrom-Json
$apkHash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifest.apk_sha256 -ne $apkHash -or $manifest.mpv_debug_candidate -ne 'SourceFrame') { throw 'Build manifest/candidate differs from the APK.' }
$kind = $Diagnostic.ToLowerInvariant()
$request = $kind + '_' + [guid]::NewGuid().ToString('N')
$directory = Join-Path $workspace ('artifacts\device\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + $request)
New-Item -ItemType Directory -Force -Path $directory | Out-Null
Copy-Item -LiteralPath (Join-Path $workspace 'artifacts\build_manifest.json') -Destination $directory
if ($Install) {
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial install -r $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK installation failed.' }
}
$installedPath = ((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if (-not $installedPath -or $installedPath -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Unexpected installed APK path.' }
$installedHash = ((& $adb -s $Serial shell sha256sum $installedPath) -split '\s+')[0]
if ($LASTEXITCODE -ne 0 -or $installedHash -ne $apkHash) { throw 'Installed APK bytes differ from the build.' }
@{serial=$Serial; apk_sha256=$apkHash; installed_sha256=$installedHash; requested_hardware=[bool]$Hardware; diagnostic=$Diagnostic} |
    ConvertTo-Json | Set-Content (Join-Path $directory 'installed.json') -Encoding utf8
& $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_MPV_$($Diagnostic.ToUpperInvariant())" --es request $request --ez hardware $Hardware.ToString().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic broadcast failed.' }
function Read-AppJson([string]$name) {
    $raw = & $adb -s $Serial shell run-as $package cat "files/diagnostics/$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
$receipt = $null
$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
    $receipt = Read-AppJson "debug_request_$request.json"
    if ($receipt) { break }
    Start-Sleep -Seconds 1
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $request) { throw 'Diagnostic request was not accepted.' }
$receipt | ConvertTo-Json | Set-Content (Join-Path $directory 'request.json') -Encoding utf8
$deadline = [DateTime]::UtcNow.AddSeconds(150)
$probeObservedAt = [DateTime]::UtcNow
$audioStateCaptured = $false
$report = $null
do {
    $candidate = Read-AppJson "mpv_$($kind)_$($receipt.id).json"
    if ($candidate -and $candidate.request_id -eq $receipt.id -and $candidate.diagnostic_process -eq $receipt.diagnostic_process) {
        $report = $candidate; break
    }
    if ($Diagnostic -eq 'Audio' -and !$audioStateCaptured -and ([DateTime]::UtcNow - $probeObservedAt).TotalSeconds -ge 12) {
        foreach ($entry in @(@('audio','audio'), @('audio-flinger','media.audio_flinger'), @('power','power'))) {
            & $adb -s $Serial shell dumpsys $entry[1] | Set-Content (Join-Path $directory ($entry[0] + '-during-probe.txt')) -Encoding utf8
        }
        @{recorded_at=(Get-Date).ToString('o'); request_id=$receipt.id; diagnostic_process=$receipt.diagnostic_process;
            app_pid=((& $adb -s $Serial shell pidof $package | Out-String).Trim()); terminal_report_observed=$false} |
            ConvertTo-Json | Set-Content (Join-Path $directory 'audio-state-observation.json') -Encoding utf8
        $audioStateCaptured = $true
    }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
$appPid = (& $adb -s $Serial shell pidof $package | Out-String).Trim()
if ($appPid -match '^\d+$') {
    & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content (Join-Path $directory 'logcat.txt') -Encoding utf8
}
if (-not $report) { throw "No matching terminal report. Inspect live process before retry; evidence: $directory" }
$reportPath = Join-Path $directory 'report.json'
$report | ConvertTo-Json -Depth 30 | Set-Content $reportPath -Encoding utf8
Write-Output "Evidence: $directory"
$report | Select-Object state,error,failure_phase,failure_native_status,closed_native_status,resources_closed | ConvertTo-Json -Depth 6
if ($report.state -ne 'passed_native_checks') { throw "Native $kind diagnostic failed; raw report preserved." }
& "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_$($kind)_probe.py" $reportPath
if ($LASTEXITCODE -ne 0) { throw "Independent $kind verifier failed." }
