param([Parameter(Mandatory)][string]$Uri, [int]$CueMs = 37500, [ValidateRange(1,8)][int]$Switches = 2, [Parameter(Mandatory=$true)][string]$Serial, [string]$BuildManifest = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$workspace\tools\environment\Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$package = 'com.wapok.thru3d'
$directory = Join-Path $workspace ('artifacts\device\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_smb_subtitles_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$manifestPath = if ($BuildManifest) { $BuildManifest } else { "$workspace/artifacts/build_manifest.json" }
$build = Get-Content $manifestPath -Raw | ConvertFrom-Json
Copy-Item $manifestPath "$directory/build_manifest.json"
$installed = ((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed APK path unavailable' }
$installedHash = ((& $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed APK differs from build' }
$power = & $adb -s $Serial shell dumpsys power
$power | Set-Content "$directory/power-before.txt"
& $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
$script:process = ''
function Read-Json([string]$file) {
    $text = & $adb -s $Serial shell run-as $package cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}
function Request([string]$label, [string]$operation, [string[]]$extras=@()) {
    $key = $label + '_' + [guid]::NewGuid().ToString('N')
    $action = if ($operation -eq 'launch') { 'DEBUG_LAUNCH' } else { 'DEBUG_PLAYER_MPV' }
    $args = @('-s',$Serial,'shell','am','broadcast','-n',"$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",'-a',"$package.$action",'--es','request',$key)
    if ($operation -ne 'launch') { $args += @('--es','operation',$operation) }
    & $adb @args @extras | Set-Content "$directory/$label-broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $label" }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt = Read-Json "debug_request_$key.json"
        if ($receipt) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw "Request rejected: $label" }
    if ($script:process -and $receipt.diagnostic_process -ne $script:process) { throw 'Subtitle process changed' }
    $script:process = $receipt.diagnostic_process
    $receipt | ConvertTo-Json | Set-Content "$directory/$label-receipt.json"
    return $receipt
}
function Wait-Report($receipt, [string]$label, [scriptblock]$condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $report = Read-Json "mpv_player_$($receipt.id).json"
        if ($report -and $report.request_id -eq $receipt.id) {
            $report | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-report.json"
            if ($report.media.state -eq 'failed') { throw "${label}: $($report.media.error)" }
            if ($report.diagnostic_2d) { throw 'Unexpected 2D entry' }
            $commands = @($report.commands | Where-Object { $_.request_key -eq $receipt.request -and $_.request_id -eq $receipt.id })
            # A bound texture can precede its first native post-draw acknowledgement.
            # Collect every active state only after the current owner has drawn it.
            $drawn = $label -eq 'close' -or ($report.native_status.session_id -eq $report.media.session_id -and
                $report.native_status.generation -eq $report.media.generation -and $report.native_status.post_draw_frames -gt 0 -and
                $report.native_status.details.hwdec_current -eq 'mediacodec')
            if ($commands.Count -eq 1 -and $drawn -and (& $condition $report)) { Write-Host "Verified subtitle state: $label"; return $report }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Subtitle state timeout: $label; evidence: $directory"
}
function Seek([string]$label, [int]$position) {
    $receipt = Request $label 'seek' @('--ei','position_ms',"$position")
    return Wait-Report $receipt $label { param($r) $r.native_status.details.paused -eq 'yes' -and $r.media.presentation_identity.pts_us -ge ($position*1000) -and $r.media.presentation_identity.pts_us -lt (($position+34)*1000) }
}
$result = @{state='failed'; apk_sha256=$build.apk_sha256; installed_sha256=$installedHash;
    scope='SMB sidecar cue selection and sustained Alpha/normal frame delivery; no compositor pixel or long-session stability claim'}
try {
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.prox_close | Set-Content "$directory/wake-override.txt"
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    $result.launch_unix_seconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    & $adb -s $Serial shell am start -n "$package/com.godot.game.GodotAppLauncher" -a android.intent.action.MAIN -c com.oculus.intent.category.VR -c org.khronos.openxr.intent.category.IMMERSIVE_HMD | Set-Content "$directory/launch.txt"
    if ($LASTEXITCODE -ne 0) { throw 'External VR launcher failed' }
    $result.launch_entry = 'normal_vr_launcher'
    $result.launch_origin = 'adb_shell_activity_manager'
    Start-Sleep -Seconds 12
    $request = Request 'open' 'open' @('--es','uri',$Uri,'--ez','enabled','false','--es','profile','384x216')
    $opened = Wait-Report $request 'open' { param($r) $r.media.frame_counter -ge 4 -and @($r.native_status.details.subtitle_tracks).Count -gt 0 }
    $tracks = @($opened.native_status.details.subtitle_tracks)
    $track = @($tracks | Where-Object { $_.codec -in @('subrip','ass','ssa','webvtt','text','sami','microdvd','subviewer') })[0].id
    if (!$track) { throw 'No usable text subtitle track' }
    $request = Request 'pause' 'playing' @('--ez','enabled','false')
    Wait-Report $request 'pause' { param($r) $r.native_status.details.paused -eq 'yes' } | Out-Null
    Seek 'seek_cue' $CueMs | Out-Null
    $request = Request 'subtitle' 'subtitle' @('--ei','track_id',"$track")
    Wait-Report $request 'subtitle' { param($r) $r.layout.subtitles.text.Length -gt 0 } | Out-Null
    $request = Request 'play' 'playing' @('--ez','enabled','true')
    Wait-Report $request 'play' { param($r) $r.native_status.details.paused -eq 'no' } | Out-Null
    $request = Request 'alpha' 'alpha' @('--ez','enabled','true')
    Wait-Report $request 'alpha' { param($r) $r.layout.alpha_ready -and $r.media.frame_counter -ge 60 -and $r.layout.subtitles.requested_track -eq $track } | Out-Null
    for ($switch=1; $switch -le $Switches; $switch++) {
        $request = Request "normal_$switch" 'alpha' @('--ez','enabled','false')
        Wait-Report $request "normal_$switch" { param($r) !$r.layout.alpha_enabled -and $r.media.frame_counter -ge 30 } | Out-Null
        $request = Request "alpha_$switch" 'alpha' @('--ez','enabled','true')
        Wait-Report $request "alpha_$switch" { param($r) $r.layout.alpha_ready -and $r.media.frame_counter -ge 120 -and $r.layout.subtitles.requested_track -eq $track } | Out-Null
    }
    $request = Request 'normal' 'alpha' @('--ez','enabled','false')
    Wait-Report $request 'normal' { param($r) !$r.layout.alpha_enabled -and $r.media.frame_counter -ge 30 } | Out-Null
    $request = Request 'close' 'close'
    Wait-Report $request 'close' { param($r) $r.media.session_id -le 0 } | Out-Null
    $result.state = 'passed_scoped_smb_subtitle_alpha_trace'
    $result.tracks = $tracks
    $result.completed_round_trips = $Switches + 1
    $result.process = $script:process
} catch { $result.error = $_.Exception.Message; throw }
finally {
    $appPid = (& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    if ($result.state -eq 'passed_scoped_smb_subtitle_alpha_trace' -and
        (Get-Content "$directory/logcat.txt" -Raw) -match '(SHADER ERROR:|SCRIPT ERROR:|shader compilation failed|"event":"mpv_error"|FATAL EXCEPTION:)') {
        $result.state = 'failed'
        $result.error = 'App log contains a shader, script, playback or Java crash'
    }
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.automation_disable | Set-Content "$directory/wake-restored.txt"
    if (($power | Out-String) -match 'mWakefulness=Asleep') { & $adb -s $Serial shell input keyevent KEYCODE_SLEEP }
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'passed_scoped_smb_subtitle_alpha_trace') { throw $result.error }


