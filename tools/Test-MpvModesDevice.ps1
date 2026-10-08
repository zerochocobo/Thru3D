param([Parameter(Mandatory=$true)][string]$Serial, [ValidateRange(2,100)][int]$Switches = 100, [switch]$KeepAwake, [switch]$Xr)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$package = 'com.wapok.thru3d'
$directory = Join-Path $workspace ('artifacts/device/' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_modes_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $directory | Out-Null
$build = Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
Copy-Item "$workspace/artifacts/build_manifest.json" $directory
$installedPath = ((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if ($installedPath -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed APK unavailable' }
$installedHash = ((& $adb -s $Serial shell sha256sum $installedPath) -split '\s+')[0]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed APK differs from build' }
$power = & $adb -s $Serial shell dumpsys power
$power | Set-Content "$directory/power-before.txt"
& $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
& $adb -s $Serial shell dumpsys thermalservice | Set-Content "$directory/thermal-before.txt"
$script:process = ''
function Read-Json([string]$name) {
    $raw = & $adb -s $Serial shell run-as $package cat "files/diagnostics/$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}
function Request([string]$label, [string]$operation, [string[]]$extras=@()) {
    if ($operation -in @('open','seek')) { $extras += @('--es','seek_mode','exact') }
    $key = $label + '_' + [guid]::NewGuid().ToString('N')
    & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_PLAYER_MPV" --es request $key --es operation $operation @extras | Set-Content "$directory/$label-broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $label" }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt = Read-Json "debug_request_$key.json"
        if ($receipt) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw "Request not accepted: $label" }
    if ($script:process -and $script:process -ne $receipt.diagnostic_process) { throw 'Process changed' }
    $script:process = $receipt.diagnostic_process
    $receipt | ConvertTo-Json | Set-Content "$directory/$label-receipt.json"
    return $receipt
}
function Wait-Report($receipt, [string]$label, [scriptblock]$condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    do {
        $r = Read-Json "mpv_player_$($receipt.id).json"
        if ($r -and $r.request_id -eq $receipt.id) {
            $r | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-report.json"
            if ($r.media.state -eq 'failed') { throw "${label}: $($r.media.error)" }
            if ([bool]$r.diagnostic_2d -eq [bool]$Xr) { throw 'Unexpected XR/2D entry' }
            $commands = @($r.commands | Where-Object { $_.request_key -eq $receipt.request -and $_.request_id -eq $receipt.id })
            if ($commands.Count -eq 1 -and (& $condition $r)) { Write-Host "Verified mode state: $label"; return $r }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Mode timeout: $label; evidence: $directory"
}
function Revision([string]$label, [string]$operation, [string[]]$extras, [string]$profile, [bool]$alpha, [int]$generation) {
    $receipt = Request $label $operation $extras
    return Wait-Report $receipt $label { param($r)
        $r.media.generation -gt $generation -and $r.layout.profile -eq $profile -and
            $r.media.frame_counter -gt 0 -and $r.native_status.post_draw_frames -gt 0 -and
            $r.native_status.session_id -eq $r.media.session_id -and $r.native_status.generation -eq $r.media.generation -and
            $r.layout.alpha_enabled -eq $alpha -and $r.media.presentation_identity.inference_ran -eq $alpha -and
            (!$alpha -or $r.layout.alpha_ready)
    }
}
$result = @{state='failed'; apk_sha256=$build.apk_sha256; installed_sha256=$installedHash; requested_switches=$Switches; test_proximity_keep_awake=[bool]$KeepAwake;
    xr_entry=[bool]$Xr; launch_entry=$(if ($Xr) { 'normal_vr_launcher' } else { 'diagnostic_2d' });
    launch_origin=$(if ($Xr) { 'adb_shell_activity_manager' } else { 'debug_receiver' });
    scope='Paused actual native hardware decode/Godot pair revisions across six profiles and repeated mode changes; no performance, physical tracking or compositor pixel claim'}
try {
    & $adb -s $Serial shell am force-stop $package
    if ($KeepAwake) {
        & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.prox_close | Set-Content "$directory/wake-override.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Test keep-awake request failed' }
    }
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    $result.launch_unix_seconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Xr) {
        & $adb -s $Serial shell am start -n "$package/com.godot.game.GodotAppLauncher" -a android.intent.action.MAIN -c com.oculus.intent.category.VR -c org.khronos.openxr.intent.category.IMMERSIVE_HMD | Set-Content "$directory/launch.txt"
    } else {
        & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_LAUNCH_2D" --es request ('mode_launch_' + [guid]::NewGuid().ToString('N')) | Set-Content "$directory/launch.txt"
    }
    if ($LASTEXITCODE -ne 0) { throw 'Device launch failed' }
    Start-Sleep -Seconds 7
    $receipt = Request 'open' 'open' @('--es','fixture','mp03_frame_identity','--ez','enabled','true','--es','profile','256x144')
    $current = Wait-Report $receipt 'open' { param($r) $r.layout.alpha_ready -and $r.media.frame_counter -ge 4 -and $r.native_status.post_draw_frames -gt 0 }
    $receipt = Request 'pause' 'playing' @('--ez','enabled','false')
    $current = Wait-Report $receipt 'pause' { param($r) $r.native_status.details.paused -eq 'yes' }
    $receipt = Request 'seek' 'seek' @('--ei','position_ms','1000')
    $current = Wait-Report $receipt 'seek' { param($r) $r.native_status.details.paused -eq 'yes' -and $r.media.presentation_identity.pts_us -eq 1000000 }
    & $adb -s $Serial shell dumpsys meminfo $package | Set-Content "$directory/memory-before.txt"
    $profiles = @('256x144','384x216','512x288','256x256','384x384','512x512')
    foreach ($profile in $profiles) {
        $current = Revision "profile_$profile" 'profile' @('--es','profile',$profile) $profile $true $current.media.generation
    }
    $current = Revision 'stress_profile' 'profile' @('--es','profile','256x144') '256x144' $true $current.media.generation
    for ($index=1; $index -le $Switches; $index++) {
        $enabled = $index % 2 -eq 0
        $label = 'switch_' + $index.ToString('D3')
        $current = Revision $label 'alpha' @('--ez','enabled',$enabled.ToString().ToLowerInvariant()) '256x144' $enabled $current.media.generation
        if ($index % 10 -eq 0) {
            $battery = & $adb -s $Serial shell dumpsys battery
            $battery | Set-Content "$directory/$label-battery.txt"
            if (($battery | Out-String) -match 'temperature:\s*(\d+)' -and [int]$Matches[1] -ge 430) { throw 'Battery reached 43 C; stopped the short switch test' }
            $caps = Read-Json 'capabilities_latest.json'
            if ($caps) { $caps | ConvertTo-Json -Depth 35 | Set-Content "$directory/$label-capabilities.json" }
        }
    }
    & $adb -s $Serial shell dumpsys meminfo $package | Set-Content "$directory/memory-after-switches.txt"
    $receipt = Request 'close' 'close'
    Wait-Report $receipt 'close' { param($r) $r.media.session_id -le 0 -and !$r.layout.alpha_enabled } | Out-Null
    & $adb -s $Serial shell dumpsys meminfo $package | Set-Content "$directory/memory-after-close.txt"
    $result.state='passed_scoped_profile_and_mode_trace'
    $result.process=$script:process
    $result.profiles=$profiles
    $result.completed_switches=$Switches
} catch { $result.error=$_.Exception.Message; throw }
finally {
    $appPid=(& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    if ($result.state -eq 'passed_scoped_profile_and_mode_trace' -and
        (Get-Content "$directory/logcat.txt" -Raw) -match '(SHADER ERROR:|SCRIPT ERROR:|shader compilation failed|"event":"mpv_error"|FATAL EXCEPTION:)') {
        $result.state='failed'
        $result.error='App log contains a shader, script, playback or Java crash'
    }
    & $adb -s $Serial shell am force-stop $package
    if ($KeepAwake) {
        & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.automation_disable | Set-Content "$directory/wake-restored.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Normal proximity restoration failed' }
    }
    if (($power | Out-String) -match 'mWakefulness=Asleep') { & $adb -s $Serial shell input keyevent KEYCODE_SLEEP }
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    & $adb -s $Serial shell dumpsys thermalservice | Set-Content "$directory/thermal-after.txt"
    $result | ConvertTo-Json -Depth 8 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'passed_scoped_profile_and_mode_trace') { throw $result.error }
& "$workspace/.venv/Scripts/python.exe" "$workspace/benchmarks/mpv_modes_device.py" $directory
if ($LASTEXITCODE -ne 0) { throw 'Independent profile/mode audit failed' }
