param([string]$Serial = '2G0YC5ZF7V0664')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$package = 'com.wapok.thru3d'
$directory = Join-Path $workspace ('artifacts/device/' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_depth_strength')
New-Item -ItemType Directory -Force $directory | Out-Null
$build = Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
$installed = ((& $adb -s $Serial shell pm path $package) | Select-Object -First 1) -replace '^package:', ''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed APK unavailable' }
$hash = ((& $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($LASTEXITCODE -ne 0 -or $hash -notmatch '^[0-9a-f]{64}$') { throw 'Cannot read installed APK hash; check ADB connection' }
if ($hash -ne $build.apk_sha256) { throw 'Installed APK differs from build manifest' }
$beforePower = & $adb -s $Serial shell dumpsys power
$beforeDump = (& $adb -s $Serial shell getprop debug.vrpp.warp.dump | Out-String).Trim()
$result = @{state='failed'; apk_sha256=$hash; strengths=@(); scope='Actual Quest native paused video GPU rewarp at the same PTS; no physical controller or subjective stereo comfort claim'}
function Read-Report([string]$name) {
    $raw = & $adb -s $Serial shell run-as $package cat "files/diagnostics/$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
function Request([string]$label, [string]$operation, [string[]]$extras=@()) {
    $key = $label.Substring(0, [Math]::Min(20, $label.Length)) + '_' + [guid]::NewGuid().ToString('N')
    & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_PLAYER_MPV" --es request $key --es operation $operation @extras | Set-Content "$directory/$label-broadcast.txt"
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt = Read-Report "debug_request_$key.json"
        if ($receipt) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $receipt | ConvertTo-Json -Depth 8 | Set-Content "$directory/$label-receipt.json"
    if (!$receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw "Request rejected: $label" }
    return $receipt
}
function Wait-Report($receipt, [string]$label, [scriptblock]$condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(50)
    do {
        $report = Read-Report "mpv_player_$($receipt.id).json"
        if ($report -and $report.request_id -eq $receipt.id) {
            $report | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-report.json"
            $commands = @($report.commands | Where-Object { $_.request_key -eq $receipt.request -and $_.request_id -eq $receipt.id })
            if ($commands.Count -eq 1) {
                if ($report.media.state -eq 'failed') { throw "${label}: $($report.media.error)" }
                if (& $condition $report) { return $report }
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $label; evidence: $directory"
}
try {
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.prox_close | Out-Null
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_LAUNCH_2D" --es request ('depth_launch_' + [guid]::NewGuid().ToString('N')) | Out-Null
    Start-Sleep -Seconds 7
    $receipt = Request 'open' 'open' @('--es','fixture','depth_2d','--ez','stereo','false','--ez','depth','true','--ez','benchmark','true','--ei','projection','0','--ez','loop','true')
    $current = Wait-Report $receipt 'open' { param($r) $r.layout.depth_enabled -and $r.media.frame_counter -ge 4 -and $r.native_status.bridge.warp_frames -gt 0 }
    $receipt = Request 'pause' 'playing' @('--ez','enabled','false')
    $current = Wait-Report $receipt 'pause' { param($r) $r.native_status.details.paused -eq 'yes' }
    Start-Sleep -Seconds 2 # Drain frames already in flight before checking the held PTS.
    $current = Read-Report "mpv_player_$($receipt.id).json"
    $pts = $current.media.presentation_identity.pts_us
    $generation = $current.media.generation
    $frames = $current.native_status.bridge.warp_frames
    $hashes = @()
    foreach ($strength in @('0.5','1','2','4')) {
        $tag = 'strength_' + $strength.Replace('.','_') + '_' + [guid]::NewGuid().ToString('N')
        & $adb -s $Serial shell setprop debug.vrpp.warp.dump $tag
        $receipt = Request $tag 'depth' @('--ef','strength',$strength)
        $current = Wait-Report $receipt $tag { param($r)
            [math]::Abs($r.layout.depth_strength - [double]$strength) -lt 0.001 -and $r.native_status.bridge.warp_frames -gt $frames
        }
        if ($current.native_status.bridge.warp_failed -or $current.media.generation -ne $generation -or $current.media.presentation_identity.pts_us -ne $pts) { throw 'Strength drag restarted or advanced paused video' }
        $expected = $current.media.format.width * 0.035 * [double]$strength / 2
        if ([math]::Abs($current.native_status.bridge.warp_half_shift_px - $expected) -gt 0.02) { throw "Native parallax capped: $strength" }
        $remote = "/sdcard/Android/data/$package/files/warp_$tag.ppm"
        $local = Join-Path $directory "$tag.ppm"
        & $adb -s $Serial pull $remote $local | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Paused GPU frame capture missing' }
        $frameHash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        if ($hashes -contains $frameHash) { throw 'Strength update did not change rendered pixels' }
        $hashes += $frameHash
        $frames = $current.native_status.bridge.warp_frames
        $result.strengths += @{strength=[double]$strength; pts_us=$pts; generation=$generation; half_shift_px=$current.native_status.bridge.warp_half_shift_px; rendered_sha256=$frameHash}
        Write-Output "Verified paused GPU strength $strength at PTS $pts"
    }
    $receipt = Request 'off' 'depth' @('--ef','strength','0')
    $current = Wait-Report $receipt 'off' { param($r) !$r.layout.depth_requested -and !$r.layout.depth_enabled }
    if ($current.layout.auto_depth) { throw 'Off did not clear automatic conversion' }
    $result.state = 'passed'
} catch { $result.error = $_.Exception.Message; throw }
finally {
    $appProcess = (& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appProcess -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appProcess -v threadtime | Set-Content "$directory/logcat.txt" }
    if (Test-Path "$directory/logcat.txt") {
        if ((Get-Content "$directory/logcat.txt" -Raw) -match '(SCRIPT ERROR:|SHADER ERROR:|FATAL EXCEPTION:|Depth view refresh failed|2D->3D warp unavailable)') { $result.state='failed'; $result.error='Runtime error in device log' }
    }
    & $adb -s $Serial shell setprop debug.vrpp.warp.dump $(if ($beforeDump) { $beforeDump } else { '0' })
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.automation_disable | Out-Null
    if (($beforePower | Out-String) -match 'mWakefulness=Asleep') { & $adb -s $Serial shell input keyevent KEYCODE_SLEEP }
    $result | ConvertTo-Json -Depth 8 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'passed') { throw $result.error }
