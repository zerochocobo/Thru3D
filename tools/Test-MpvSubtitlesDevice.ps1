param([Parameter(Mandatory=$true)][string]$Serial, [string]$BuildManifest = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1"
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$package = 'com.wapok.thru3d'
$directory = Join-Path $workspace ('artifacts\device\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_subtitles_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$manifestPath = if ($BuildManifest) { $BuildManifest } else { "$workspace\artifacts\build_manifest.json" }
$build = Get-Content $manifestPath -Raw | ConvertFrom-Json
Copy-Item $manifestPath "$directory/build_manifest.json"
$installed = ((& $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Installed APK path unavailable' }
$installedHash = ((& $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed subtitle test APK differs' }
$fixture = Get-Content "$workspace\tests\fixtures\mp06_text_subtitles.json" -Raw | ConvertFrom-Json
$fixturePath = Join-Path $workspace $fixture.file
if ((Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fixture.sha256) { throw 'Fixture bytes differ' }
Copy-Item "$workspace\tests\fixtures\mp06_text_subtitles.json" $directory
& $adb -s $Serial push $fixturePath /data/local/tmp/mp06_text_subtitles.mkv | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Fixture upload failed' }
& $adb -s $Serial shell run-as $package mkdir -p files/fixtures
& $adb -s $Serial shell run-as $package cp /data/local/tmp/mp06_text_subtitles.mkv files/fixtures/mp06_text_subtitles.mkv
if ($LASTEXITCODE -ne 0) { throw 'Private fixture copy failed' }
$copiedHash = ((& $adb -s $Serial shell run-as $package sha256sum files/fixtures/mp06_text_subtitles.mkv) -split '\s+')[0]
if ($copiedHash -ne $fixture.sha256) { throw 'Device fixture bytes differ' }
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
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
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
function Cue([string]$label, [int]$track, [string]$text) {
    $receipt = Request $label 'subtitle' @('--ei','track_id',"$track")
    return Wait-Report $receipt $label { param($r)
        $current = @($r.commands | Where-Object request_key -eq $receipt.request)[0]
        $cue = $r.layout.subtitles.cue
        $current.accepted -and $r.layout.subtitles.text -eq $text -and
            ($track -eq 0 -or ($cue.session_id -eq $r.media.session_id -and $cue.generation -eq $r.media.generation -and
            $cue.mpv_source_handle -eq $r.pairs[-1].mpv_source_handle -and $cue.source_epoch -eq $r.media.presentation_identity.source_epoch -and
            $cue.command_id -ge $cue.required_command_id -and [int]$cue.track_id -eq $track -and
            [double]$cue.position_seconds -ge [double]$cue.start_seconds -and [double]$cue.position_seconds -lt [double]$cue.end_seconds))
    }
}
$result = @{state='failed'; apk_sha256=$build.apk_sha256; installed_sha256=$installedHash; fixture_sha256=$copiedHash;
    scope='Actual Quest native MPV text decoding/clock observations and Godot state; compositor glyph pixels, physical head tracking and exact AV/subtitle sync unverified'}
try {
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    $result.launch_unix_seconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    & $adb -s $Serial shell am start -n "$package/com.godot.game.GodotAppLauncher" -a android.intent.action.MAIN -c com.oculus.intent.category.VR -c org.khronos.openxr.intent.category.IMMERSIVE_HMD | Set-Content "$directory/launch.txt"
    if ($LASTEXITCODE -ne 0) { throw 'External VR launcher failed' }
    $result.launch_entry = 'normal_vr_launcher'
    $result.launch_origin = 'adb_shell_activity_manager'
    Start-Sleep -Seconds 7
    $request = Request 'open' 'open' @('--es','fixture','mp06_text_subtitles','--ez','enabled','false','--es','profile','256x144')
    $opened = Wait-Report $request 'open' { param($r) $r.media.frame_counter -ge 4 -and @($r.native_status.details.subtitle_tracks).Count -eq 3 }
    $tracks = @($opened.native_status.details.subtitle_tracks)
    $english = @($tracks | Where-Object { $_.title -eq 'Text track 1' })[0].id
    $chinese = @($tracks | Where-Object { $_.title -eq 'Text track 2' })[0].id
    $styled = @($tracks | Where-Object { $_.title -eq 'Text track 3' })[0].id
    if (-not $english -or -not $chinese -or -not $styled) { throw 'Actual named subtitle tracks missing' }
    $request = Request 'pause' 'playing' @('--ez','enabled','false')
    Wait-Report $request 'pause' { param($r) $r.native_status.details.paused -eq 'yes' } | Out-Null
    Seek 'seek_first' 1000 | Out-Null
    Cue 'english' $english 'Track A: first cue' | Out-Null
    Cue 'chinese' $chinese '中文字幕 😀' | Out-Null
    Cue 'styled' $styled "Track C: styled`nPlain text overlay" | Out-Null
    Cue 'off' 0 '' | Out-Null
    Cue 'restore_chinese' $chinese '中文字幕 😀' | Out-Null
    Seek 'gap' 1700 | Out-Null
    $request = Request 'gap_check' 'playing' @('--ez','enabled','false')
    Wait-Report $request 'gap_check' { param($r) $r.layout.subtitles.text -eq '' -and [double]$r.native_status.details.position_seconds -ge 1.7 } | Out-Null
    Seek 'seek_second' 2500 | Out-Null
    Cue 'second_chinese' $chinese "第二条字幕`n第二行" | Out-Null
    $request = Request 'alpha' 'alpha' @('--ez','enabled','true')
    Wait-Report $request 'alpha' { param($r) $r.layout.alpha_ready -and $r.layout.subtitles.text -eq "第二条字幕`n第二行" -and $r.layout.subtitles.cue.generation -eq $r.media.generation } | Out-Null
    # A paused first frame does not exercise later slot/scout allocations or
    # caption atlas updates. Keep subtitles selected while Alpha advances.
    $request = Request 'alpha_play' 'playing' @('--ez','enabled','true')
    Wait-Report $request 'alpha_play' { param($r) $r.layout.alpha_ready -and $r.media.frame_counter -ge 12 -and $r.layout.subtitles.requested_track -eq $chinese } | Out-Null
    $request = Request 'alpha_pause' 'playing' @('--ez','enabled','false')
    Wait-Report $request 'alpha_pause' { param($r) $r.native_status.details.paused -eq 'yes' } | Out-Null
    Seek 'alpha_back' 2500 | Out-Null
    $request = Request 'normal' 'alpha' @('--ez','enabled','false')
    Wait-Report $request 'normal' { param($r) !$r.layout.alpha_enabled -and $r.layout.subtitles.text -eq "第二条字幕`n第二行" -and $r.layout.subtitles.cue.generation -eq $r.media.generation } | Out-Null
    $request = Request 'close' 'close'
    Wait-Report $request 'close' { param($r) $r.media.session_id -le 0 -and $r.layout.subtitles.text -eq '' } | Out-Null
    $result.state = 'passed_scoped_subtitle_trace'
    $result.tracks = $tracks
    $result.process = $script:process
} catch { $result.error = $_.Exception.Message; throw }
finally {
    $appPid = (& $adb -s $Serial shell pidof $package | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/logcat.txt" }
    if ($result.state -eq 'passed_scoped_subtitle_trace' -and
        (Get-Content "$directory/logcat.txt" -Raw) -match '(SHADER ERROR:|SCRIPT ERROR:|shader compilation failed|"event":"mpv_error"|FATAL EXCEPTION:)') {
        $result.state = 'failed'
        $result.error = 'App log contains a shader, script, playback or Java crash'
    }
    & $adb -s $Serial shell am force-stop $package
    if (($power | Out-String) -match 'mWakefulness=Asleep') { & $adb -s $Serial shell input keyevent KEYCODE_SLEEP }
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'passed_scoped_subtitle_trace') { throw $result.error }
& "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_subtitles_device.py" $directory
if ($LASTEXITCODE -ne 0) {
    $result.state = 'failed_independent_subtitle_audit'
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    throw 'Independent subtitle device audit failed'
}
