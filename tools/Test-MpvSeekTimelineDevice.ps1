param([Parameter(Mandatory=$true)][string]$Serial, [string]$Apk='artifacts/quest3-player-slider-target-signed-debug.apk',
    [string]$Output='artifacts/device/seek-timeline')
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
$directory=Join-Path $workspace $Output
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$adb=(Get-Command adb -ErrorAction Stop).Source
$package='com.wapok.thru3d'
$installed=(( & $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Unexpected APK path' }
$sha=(( & $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($sha -ne (Get-FileHash (Join-Path $workspace $Apk)).Hash.ToLowerInvariant()) { throw 'Installed test APK differs' }
$fixture=Get-Content "$workspace/tests/fixtures/mp07_motion_4k.json" -Raw | ConvertFrom-Json
$path=Join-Path $workspace $fixture.file
if ((Get-FileHash $path).Hash.ToLowerInvariant() -ne $fixture.sha256) { throw 'Fixture hash differs' }
& $adb -s $Serial push $path /data/local/tmp/mp07_motion_4k.mp4 | Out-Null
& $adb -s $Serial shell run-as $package mkdir -p files/fixtures
& $adb -s $Serial shell run-as $package cp /data/local/tmp/mp07_motion_4k.mp4 files/fixtures/mp07_motion_4k.mp4
if ($LASTEXITCODE -ne 0) { throw 'Private fixture copy failed' }
$script:process=''
function Read-Json([string]$file) {
    $text= & $adb -s $Serial shell run-as $package cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}
function Request([string]$label,[string]$operation,[string[]]$extras=@()) {
    if ($operation -in @('open','seek')) { $extras += @('--es','seek_mode','exact') }
    $key=$label+'_'+[guid]::NewGuid().ToString('N')
    & $adb -s $Serial shell am broadcast -n "$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver" -a "$package.DEBUG_PLAYER_MPV" --es request $key --es operation $operation @extras | Set-Content "$directory/$label-broadcast.txt"
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt=Read-Json "debug_request_$key.json"
        if ($receipt) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw "Rejected request: $label" }
    if ($script:process -and $receipt.diagnostic_process -ne $script:process) { throw 'Test process changed' }
    $script:process=$receipt.diagnostic_process
    $receipt | ConvertTo-Json | Set-Content "$directory/$label-receipt.json"
    return $receipt
}
function Wait-Report($receipt,[string]$label,[scriptblock]$predicate) {
    $deadline=[DateTime]::UtcNow.AddSeconds(45)
    do {
        $r=Read-Json "mpv_player_$($receipt.id).json"
        if ($r -and @($r.commands | Where-Object request_key -eq $receipt.request).Count -eq 1) {
            if ($r.media.state -eq 'failed') { throw 'Player failed' }
            if (& $predicate $r) {
                $r | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-report.json"
                return $r
            }
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    $r | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-timeout.json"
    throw "Report timeout: $label"
}
function At-Target($r,[int]$target) {
    $menu=$r.player_menu_progress
    $expected=-[double]$menu.bar_width/2+[double]$menu.bar_width*$target/[double]$menu.duration_ms
    return $menu.visible -and $menu.position_ms -eq $target -and $menu.preview_ms -eq -1 -and
        [Math]::Abs([double]$menu.thumb_x-$expected) -lt 0.0001
}
$result=@{state='failed';apk_sha256=$sha;fixture_sha256=$fixture.sha256}
try {
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    & $adb -s $Serial shell am start -n "$package/com.godot.game.GodotAppLauncher" -a android.intent.action.MAIN -c com.oculus.intent.category.VR -c org.khronos.openxr.intent.category.IMMERSIVE_HMD | Set-Content "$directory/launch.txt"
    Start-Sleep -Seconds 6
    $receipt=Request open open @('--es','fixture','mp07_motion_4k','--ez','enabled','false','--es','profile','256x144')
    Wait-Report $receipt open { param($r) $r.media.frame_counter -ge 2 } | Out-Null
    $receipt=Request pause playing @('--ez','enabled','false')
    Wait-Report $receipt pause { param($r) $r.native_status.details.paused -eq 'yes' } | Out-Null
    $receipt=Request reference seek @('--ei','position_ms','1000')
    Wait-Report $receipt reference { param($r) $r.media.presentation_identity.pts_us -eq 1000000 } | Out-Null
    $receipt=Request menu player_menu
    Wait-Report $receipt menu { param($r) At-Target $r 1000 } | Out-Null
    $receipt=Request target seek @('--ei','position_ms','3000','--ei','hold_seek_ms','6500')
    $held=Wait-Report $receipt held { param($r) (At-Target $r 3000) -and $r.layout.frame_hold.frozen -and
        $r.layout.playback_control.observed_position_ms -eq 1000 -and $r.player_menu_progress.elapsed -eq '00:03' }
    Start-Sleep -Milliseconds 1800
    $receipt=Request stable observe
    Wait-Report $receipt stable { param($r) (At-Target $r 3000) -and $r.layout.frame_hold.frozen -and
        $r.layout.playback_control.observed_position_ms -eq 1000 } | Out-Null
    $receipt=Request latest seek @('--ei','position_ms','2000','--ei','hold_seek_ms','4500')
    Wait-Report $receipt latest-held { param($r) (At-Target $r 2000) -and $r.layout.frame_hold.frozen -and $r.player_menu_progress.elapsed -eq '00:02' } | Out-Null
    Wait-Report $receipt completed { param($r) (At-Target $r 2000) -and -not $r.layout.frame_hold.frozen -and
        $r.layout.playback_control.state -eq 'idle' -and $r.media.presentation_identity.pts_us -eq 2000000 } | Out-Null
    # The paused hold outlasts the controls' hide timer. Reopen them like a user
    # before resuming; otherwise the stale inactivity deadline hides them at once.
    $receipt=Request reset-menu display_menu
    Wait-Report $receipt reset-menu { param($r) -not $r.player_menu_progress.visible } | Out-Null
    $receipt=Request reopen-menu player_menu
    Wait-Report $receipt reopen-menu { param($r) At-Target $r 2000 } | Out-Null
    $receipt=Request resume playing @('--ez','enabled','true')
    Wait-Report $receipt resumed { param($r) $r.player_menu_progress.position_ms -gt 2300 -and
        $r.player_menu_progress.position_ms -eq $r.layout.playback_control.observed_position_ms } | Out-Null
    $receipt=Request close close
    Wait-Report $receipt closed { param($r) $r.media.session_id -le 0 -and -not $r.layout.frame_hold.visible } | Out-Null
    $result.state='passed_actual_player_menu_target_hold'
    $result.diagnostic_process=$script:process
    $result.scope='Normal VR entry; actual player-menu text/thumb geometry and MPV timeline; physical trigger feel/compositor pixels not inferred'
} finally {
    $result | ConvertTo-Json | Set-Content "$directory/result.json"
    & $adb -s $Serial logcat -d -t 1500 | Set-Content "$directory/logcat.txt"
    Write-Output "Timeline evidence: $directory"
}
