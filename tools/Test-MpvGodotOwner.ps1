param([Parameter(Mandatory=$true)][string]$Serial, [switch]$Pixels, [switch]$NormalPixels, [switch]$Xr, [switch]$RequireLiveHead, [switch]$KeepAwake,
    [ValidateSet('mp03_frame_identity','mp05_person_still')][string]$Fixture = 'mp03_frame_identity')
$ErrorActionPreference = 'Stop'
if ($RequireLiveHead -and !$Xr) { throw 'RequireLiveHead needs the XR entry.' }
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$package = 'com.wapok.thru3d'
$directory = Join-Path $workspace ('artifacts\device\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_godot_owner_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $directory | Out-Null
$manifest = Get-Content "$workspace\artifacts\build_manifest.json" -Raw | ConvertFrom-Json
Copy-Item "$workspace\artifacts\build_manifest.json" $directory
$installedPath = ((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if (-not $installedPath -or $installedPath -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Unexpected installed APK path' }
$installedHash = ((& $adb -s $Serial shell sha256sum $installedPath) -split '\s+')[0]
if ($installedHash -ne $manifest.apk_sha256) { throw 'Installed APK differs from build manifest' }
@{apk_sha256=$manifest.apk_sha256; installed_sha256=$installedHash; serial=$Serial} | ConvertTo-Json | Set-Content "$directory/installed.json"
$originalPower = & $adb -s $Serial shell dumpsys power
$originalPower | Set-Content "$directory/power-before.txt"
$script:processIdentity = ''
function Read-AppJson([string]$name) {
    $raw = & $adb -s $Serial shell run-as $package cat "files/diagnostics/$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
function Send-Request([string]$action, [string]$label, [string[]]$extras) {
    $key = $label + '_' + [guid]::NewGuid().ToString('N')
    & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.$action" --es request $key @extras | Set-Content "$directory/$label-broadcast.txt"
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt = Read-AppJson "debug_request_$key.json"
        if ($receipt) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw "$label request not accepted" }
    $receipt | ConvertTo-Json | Set-Content "$directory/$label-receipt.json"
    if ($script:processIdentity -and $receipt.diagnostic_process -ne $script:processIdentity) { throw 'Player process changed' }
    $script:processIdentity = $receipt.diagnostic_process
    return $receipt
}
function Wait-Player($receipt, [string]$label, [scriptblock]$condition, [int]$seconds=40) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        $report = Read-AppJson "mpv_player_$($receipt.id).json"
        if ($report -and $report.request_id -eq $receipt.id) {
            $report | ConvertTo-Json -Depth 32 | Set-Content "$directory/$label-report.json"
            $command = @($report.commands | Where-Object { $_.request_key -eq $receipt.request -and $_.request_id -eq $receipt.id })
            if ($command.Count -eq 1) {
                if ($report.media.state -eq 'failed') { throw "${label}: player failed ($($report.media.error))" }
                if ([bool]$report.diagnostic_2d -eq [bool]$Xr) { throw 'Unexpected Godot entry (XR/2D)' }
                $currentScope = $label -eq 'close' -or
                    ($report.native_status.session_id -eq $report.media.session_id -and
                     $report.native_status.generation -eq $report.media.generation)
                if ($currentScope -and (& $condition $report)) { Write-Output "Verified owner trace: $label" | Out-Host; return $report }
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$label owner state timeout; evidence: $directory"
}
function Command([string]$operation, [string]$label, [string[]]$extras) {
    return Send-Request 'DEBUG_PLAYER_MPV' $label (@('--es','operation',$operation) + $extras)
}
$scope = if ($Xr) { 'Actual Godot XR owner control trace and runtime capability snapshots; compositor pixels, physical tracking accuracy, audio and performance unverified' }
    else { 'Actual Godot 2D owner/RID control trace; independent pixels, XR, audio and performance unverified' }
$result = @{state='failed'; scope=$scope; evidence=$directory; xr_entry=[bool]$Xr; test_proximity_keep_awake=[bool]$KeepAwake}
try {
    & $adb -s $Serial shell am force-stop $package
    if ($KeepAwake) {
        & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.prox_close | Set-Content "$directory/wake-override.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Test keep-awake request failed.' }
    }
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    $launchTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $result.launch_unix_seconds = $launchTime
    if ($Xr) {
        # Cold VR launch from the shell follows the external launcher path;
        # an in-process receiver launch can still focus XR with confidence 0.
        & $adb -s $Serial shell am start -n "$package/com.godot.game.GodotAppLauncher" -a android.intent.action.MAIN -c com.oculus.intent.category.VR -c org.khronos.openxr.intent.category.IMMERSIVE_HMD | Set-Content "$directory/launch.txt"
        if ($LASTEXITCODE -ne 0) { throw 'External VR launcher failed.' }
        $result.launch_entry = 'normal_vr_launcher'
        $result.launch_origin = 'adb_shell_activity_manager'
    } else {
        $launch = Send-Request 'DEBUG_LAUNCH_2D' 'launch' @()
        $result.launch_entry = 'diagnostic_2d'
    }
    Start-Sleep -Seconds 7
    & $adb -s $Serial shell pidof $package | Set-Content "$directory/pid.txt"
    & $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-awake.txt"
    $request = Command 'open' 'open' @('--ez','enabled','true','--es','profile','256x144','--es','fixture',$Fixture)
    $opened = Wait-Player $request 'open' { param($r) $r.media.frame_counter -ge 4 -and $r.layout.alpha_ready -and $r.native_status.post_draw_frames -ge 4 }
    $sourceHandle = @($opened.pairs | Where-Object session_id -eq $opened.media.session_id)[-1].mpv_source_handle
    if ($sourceHandle -le 0) { throw 'Source handle missing from actual bound pair' }
    $request = Command 'playing' 'pause' @('--ez','enabled','false')
    $paused = Wait-Player $request 'pause' { param($r) $r.native_status.details.paused -eq 'yes' -and $r.native_status.session_id -eq $r.media.session_id }
    $generation = $paused.media.generation
    $epoch = $paused.media.presentation_identity.source_epoch
    $request = Command 'seek' 'seek' @('--ei','position_ms','2000')
    $sought = Wait-Player $request 'seek' { param($r) $r.media.generation -gt $generation -and $r.media.presentation_identity.pts_us -eq 2000000 -and $r.media.presentation_identity.source_epoch -gt $epoch -and $r.native_status.post_draw_frames -gt 0 -and $r.native_status.details.paused -eq 'yes' }
    if ($Pixels) {
        $request = Command 'pixels' 'pixels' @()
        $pixelCapture = Wait-Player $request 'pixels' { param($r)
            if ($r.pixel_probe.state -eq 'failed') { throw ('Pixel capture failed: ' + ($r.pixel_probe | ConvertTo-Json -Depth 4 -Compress)) }
            $r.pixel_probe.state -eq 'captured' -and $r.pixel_probe.native_pin_released
        } 60
        & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_godot_pixels.py" "$directory/pixels-report.json" --adb $adb --serial $Serial
        if ($LASTEXITCODE -ne 0) { throw 'Independent Godot pixel verifier failed' }
    }
    $generation = $sought.media.generation
    $request = Command 'alpha' 'normal' @('--ez','enabled','false')
    $normal = Wait-Player $request 'normal' { param($r) $r.media.generation -gt $generation -and !$r.layout.alpha_enabled -and $r.media.presentation_identity.inference_ran -eq $false -and $r.media.frame_counter -gt 0 -and $r.native_status.post_draw_frames -gt 0 }
    if ($NormalPixels) {
        $request = Command 'pixels' 'normal-pixels' @()
        $normalCapture = Wait-Player $request 'normal-pixels' { param($r)
            if ($r.pixel_probe.state -eq 'failed') { throw 'Normal immutable pixel capture failed' }
            $r.pixel_probe.state -eq 'captured' -and $r.pixel_probe.native_pin_released
        } 60
        & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_godot_pixels.py" "$directory/normal-pixels-report.json" --adb $adb --serial $Serial --output-name normal-pixels-verified.json --expect-normal
        if ($LASTEXITCODE -ne 0) { throw 'Normal source/opaque-mask independent verifier failed' }
        $numeric = Get-Content "$directory/normal-pixels-verified.json" -Raw | ConvertFrom-Json
        if ($numeric.alpha_min_byte -ne 255 -or $numeric.alpha_max_byte -ne 255) { throw 'Opaque mask must be exactly 255 in every pixel' }
    }
    $generation = $normal.media.generation
    $request = Command 'alpha' 'alpha' @('--ez','enabled','true')
    $alpha = Wait-Player $request 'alpha' { param($r) $r.media.generation -gt $generation -and $r.layout.alpha_ready -and $r.media.presentation_identity.inference_ran -eq $true -and $r.native_status.post_draw_frames -gt 0 }
    if ($NormalPixels) {
        $request = Command 'pixels' 'alpha-after-normal' @()
        $afterCapture = Wait-Player $request 'alpha-after-normal' { param($r)
            if ($r.pixel_probe.state -eq 'failed') { throw 'Alpha after normal pixel capture failed' }
            $r.pixel_probe.state -eq 'captured' -and $r.pixel_probe.native_pin_released
        } 60
        & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_godot_pixels.py" "$directory/alpha-after-normal-report.json" --adb $adb --serial $Serial --output-name alpha-after-normal-verified.json
        if ($LASTEXITCODE -ne 0) { throw 'Alpha after normal independent verifier failed' }
    }
    if ($Xr) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $xrReady = $false
        do {
            $capabilities = Read-AppJson 'capabilities_latest.json'
            if ($capabilities) { $capabilities | ConvertTo-Json -Depth 24 | Set-Content "$directory/xr-alpha-capabilities.json" }
            $xrReady = $capabilities -and $capabilities.captured_unix_seconds -ge $launchTime -and
                $capabilities.media.session_id -eq $alpha.media.session_id -and
                $capabilities.xr.initialized -and !$capabilities.xr.preview -and $capabilities.xr.viewport_use_xr -and
                $capabilities.xr.view_count -eq 2 -and $capabilities.xr.session_state -eq 'session_focussed' -and
                $capabilities.xr.applied_passthrough -and $capabilities.xr.actual_blend_mode -eq 2 -and
                $capabilities.xr.fb_passthrough_started -and $capabilities.xr.viewport_transparent_bg
            if ($RequireLiveHead) {
                $xrReady = $xrReady -and $capabilities.xr.head_tracker_registered -and $capabilities.xr.head_has_tracking_data -and $capabilities.xr.head_tracking_confidence -eq 2
            }
            if ($xrReady) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if (!$xrReady) { throw 'XR Alpha runtime snapshot did not reach the current focused passthrough session' }
    }
    foreach ($report in @($sought,$normal,$alpha)) {
        $pairs = @($report.pairs | Where-Object session_id -eq $report.media.session_id)
        if ($pairs.Count -eq 0 -or @($pairs | Where-Object mpv_source_handle -ne $sourceHandle).Count -gt 0) { throw 'Revision source instance could not be verified' }
        if ($report.media.logical_session_id -ne $opened.media.logical_session_id) { throw 'Logical media session changed during revision' }
    }
    $request = Command 'playing' 'eof' @('--ez','enabled','true')
    $ended = Wait-Player $request 'eof' { param($r) $r.media.state -eq 'ended' -and $r.native_status.eof_pair_post_draw -and $r.native_status.eof_presented_slot -eq $r.media.presentation_identity.slot_token -and $r.media.presentation_identity.pts_us -eq 5966667 }
    $generation = $ended.media.generation
    $request = Command 'playing' 'restart' @('--ez','enabled','true')
    $restarted = Wait-Player $request 'restart' { param($r) $r.media.generation -gt $generation -and $r.layout.alpha_ready -and $r.native_status.post_draw_frames -gt 0 -and $r.native_status.details.paused -eq 'no' }
    $request = Command 'close' 'close' @()
    $closed = Wait-Player $request 'close' { param($r) $r.media.session_id -le 0 -and !$r.layout.alpha_enabled }
    Start-Sleep -Seconds 2
    $result.state = 'passed_scoped_owner_trace'
    $result.source_handle = $sourceHandle
    $result.opened_frames = $opened.media.frame_counter
    $result.eof_identity = $ended.media.presentation_identity
    $result.restart_generation = $restarted.media.generation
} catch {
    $result.error = $_.Exception.Message
    throw
} finally {
    $appPid = (& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    if ($result.state -eq 'passed_scoped_owner_trace' -and
        (Get-Content "$directory/logcat.txt" -Raw) -match '(SHADER ERROR:|SCRIPT ERROR:|shader compilation failed|"event":"mpv_error")') {
        $result.state = 'failed'
        $result.error = 'Godot log contains a shader, script or playback error'
    }
    & $adb -s $Serial shell am force-stop $package
    if ($KeepAwake) {
        & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.automation_disable | Set-Content "$directory/wake-restored.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Normal proximity restoration failed.' }
    }
    if (($originalPower | Out-String) -match 'mWakefulness=Asleep') { & $adb -s $Serial shell input keyevent KEYCODE_SLEEP }
    & $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-restored.txt"
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'passed_scoped_owner_trace') { throw $result.error }
if ($Xr) {
    $auditArgs = @($directory)
    if ($RequireLiveHead) { $auditArgs += '--require-live-head' }
    & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_xr_owner.py" @auditArgs
    if ($LASTEXITCODE -ne 0) { throw 'Independent XR runtime/owner audit failed' }
}
