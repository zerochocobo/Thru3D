param([Parameter(Mandatory=$true)][string]$Serial, [string]$Apk='artifacts/quest3-player-seek-hold-signed-debug.apk',
    [string]$Output='artifacts/device/seek-hold/run', [string[]]$Modes=@('normal','alpha','depth'),
    [string]$FixtureOverride='', [int]$Projection=-1)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
$adb=(Get-Command adb -ErrorAction Stop).Source
$package='com.wapok.thru3d'
$directory=Join-Path $workspace $Output
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$apkPath=Join-Path $workspace $Apk
$installed=(( & $adb -s $Serial shell pm path $package) | Where-Object { $_ -match '/base\.apk$' } | Select-Object -First 1) -replace '^package:', ''
if ($installed -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw 'Unexpected installed APK path' }
$installedHash=(( & $adb -s $Serial shell sha256sum $installed) -split '\s+')[0]
if ($installedHash -ne (Get-FileHash $apkPath).Hash.ToLowerInvariant()) { throw 'Test APK differs from installed APK' }
foreach ($fixture in @('mp07_motion_4k','mp05_person_still','mp06_text_subtitles')) {
    $meta=Get-Content "$workspace/tests/fixtures/$fixture.json" -Raw | ConvertFrom-Json
    $local=Join-Path $workspace $meta.file
    if ((Get-FileHash $local).Hash.ToLowerInvariant() -ne $meta.sha256) { throw 'Fixture hash differs' }
    $extension=[IO.Path]::GetExtension($local)
    & $adb -s $Serial push $local "/data/local/tmp/$fixture$extension" | Out-Null
    & $adb -s $Serial shell run-as $package mkdir -p files/fixtures
    & $adb -s $Serial shell run-as $package cp "/data/local/tmp/$fixture$extension" "files/fixtures/$fixture$extension"
    if ($LASTEXITCODE -ne 0) { throw 'Private fixture copy failed' }
}
$script:process=''
function Read-Json([string]$file) {
    $text= & $adb -s $Serial shell run-as $package cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}
function Request([string]$label, [string]$operation, [string[]]$extras=@()) {
    $key=$label+'_'+[guid]::NewGuid().ToString('N')
    $args=@('-s',$Serial,'shell','am','broadcast','-n',"$package/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",'-a',"$package.DEBUG_PLAYER_MPV",'--es','request',$key,'--es','operation',$operation)
    & $adb @args @extras | Set-Content "$directory/$label-broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $label" }
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt=Read-Json "debug_request_$key.json"
        if ($receipt) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.request -ne $key) { throw "Request rejected: $label" }
    if ($script:process -and $receipt.diagnostic_process -ne $script:process) { throw 'Test process changed' }
    $script:process=$receipt.diagnostic_process
    $receipt | ConvertTo-Json | Set-Content "$directory/$label-receipt.json"
    return $receipt
}
function Wait-Report($receipt, [string]$label, [scriptblock]$condition) {
    $deadline=[DateTime]::UtcNow.AddSeconds(65)
    do {
        $report=Read-Json "mpv_player_$($receipt.id).json"
        if ($report -and @($report.commands | Where-Object request_key -eq $receipt.request).Count -eq 1) {
            if ($report.media.state -eq 'failed') { throw "Player failed at $label" }
            if (& $condition $report) {
                $report | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-report.json"
                return $report
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $report | ConvertTo-Json -Depth 40 | Set-Content "$directory/$label-timeout.json"
    throw "Report timeout: $label"
}
function Seek([string]$label, [int]$target, [int]$delay=0) {
    return Request $label seek @('--ei','position_ms',"$target",'--ei','hold_seek_ms',"$delay")
}
function Target($receipt, [string]$label, [int]$position) {
    return Wait-Report $receipt $label { param($r)
        $r.layout.frame_hold.visible -and -not $r.layout.frame_hold.frozen -and
        $r.media.presentation_identity.pts_us -ge ($position*1000) -and
        $r.media.presentation_identity.pts_us -lt (($position+34)*1000) }
}
function Pixels([string]$label, [bool]$frozen=$false) {
    $receipt=Request $label $(if ($frozen) { 'hold_pixels' } else { 'pixels' })
    $report=Wait-Report $receipt $label { param($r) $r.pixel_probe.state -eq 'captured' -and $r.pixel_probe.request_key -eq $receipt.request }
    foreach ($entry in $report.pixel_probe.images) {
        $psi=[Diagnostics.ProcessStartInfo]::new($adb)
        $psi.Arguments="-s $Serial exec-out run-as $package cat files/diagnostics/$($entry.file)"
        $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true
        $p=[Diagnostics.Process]::Start($psi)
        $file=[IO.File]::Create("$directory/$($entry.file)")
        try { $p.StandardOutput.BaseStream.CopyTo($file); $p.WaitForExit() } finally { $file.Dispose() }
        if ($p.ExitCode -ne 0) { throw 'Pixel export failed' }
    }
    return $report
}
$result=@{state='failed'; apk_sha256=$installedHash; modes=@(); scope='Quest MPV/owner-frame state and production shader SubViewport pixels; manual headset controller feel and compositor pixels not inferred'}
try {
    & $adb -s $Serial shell am force-stop $package
    & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    & $adb -s $Serial shell am start -n "$package/com.godot.game.GodotAppLauncher" -a android.intent.action.MAIN -c com.oculus.intent.category.VR -c org.khronos.openxr.intent.category.IMMERSIVE_HMD | Set-Content "$directory/launch.txt"
    Start-Sleep -Seconds 7
    foreach ($mode in $Modes) {
        $fixture=if ($FixtureOverride) { $FixtureOverride } elseif ($mode -eq 'normal') { 'mp07_motion_4k' } else { 'mp05_person_still' }
        $request=Request "$mode-open" open @('--es','fixture',$fixture,'--ez','enabled',$(if ($mode -eq 'alpha') { 'true' } else { 'false' }),
            '--ez','depth',$(if ($mode -eq 'depth') { 'true' } else { 'false' }), '--ez','stereo',$(if ($mode -eq 'depth') { 'false' } else { 'true' }),
            '--es','profile','256x144','--ez','benchmark',$(if ($Projection -ge 0) { 'true' } else { 'false' }),
            '--ei','projection',"$([Math]::Max(0,$Projection))")
        Wait-Report $request "$mode-open" { param($r) $r.media.frame_counter -ge 2 -and
            ($mode -ne 'alpha' -or $r.layout.alpha_ready) -and ($mode -ne 'depth' -or $r.layout.depth_enabled) } | Out-Null
        $request=Request "$mode-pause" playing @('--ez','enabled','false')
        Wait-Report $request "$mode-pause" { param($r) $r.native_status.details.paused -eq 'yes' } | Out-Null
        Target (Seek "$mode-reference" 1000) "$mode-reference" 1000 | Out-Null
        $before=Pixels "$mode-before"
        $seek=Seek "$mode-seek" 3000 20000
        $held=Wait-Report $seek "$mode-held" { param($r) $r.layout.frame_hold.visible -and $r.layout.frame_hold.frozen }
        if ($held.layout.frame_hold.pts_us -ne $before.media.presentation_identity.pts_us) { throw 'Frozen source differs from displayed reference' }
        $during=Pixels "$mode-during" $true
        $target=Target (Request "$mode-target-observe" observe) "$mode-target" 3000
        if ($target.native_status.details.paused -ne 'yes') { throw 'Paused seek resumed unexpectedly' }
        if ($target.media.presentation_identity.source_epoch -le $before.media.presentation_identity.source_epoch) { throw 'Seek reused stale source epoch' }
        $rapid=Seek "$mode-rapid1" 1000 1200
        Wait-Report $rapid "$mode-rapid-held" { param($r) $r.layout.frame_hold.frozen } | Out-Null
        Seek "$mode-rapid2" 4000 1200 | Out-Null
        $final=Seek "$mode-rapid3" 2000
        Target $final "$mode-rapid-target" 2000 | Out-Null
        $request=Request "$mode-play" playing @('--ez','enabled','true')
        $playing=Wait-Report $request "$mode-play" { param($r) $r.media.presentation_identity.pts_us -gt 2500000 -and $r.layout.frame_hold.visible }
        $request=Seek "$mode-playing-seek" 1000
        Wait-Report $request "$mode-playing-target" { param($r) $r.media.session_id -gt $playing.media.session_id -and
            -not $r.layout.frame_hold.frozen -and $r.layout.frame_hold.visible -and
            $r.layout.playback_control.state -eq 'idle' -and $r.media.presentation_identity.pts_us -gt 1000000 -and
            $r.native_status.details.paused -eq 'no' } | Out-Null
        $closeSeek=Seek "$mode-close-seek" 3000 30000
        Wait-Report $closeSeek "$mode-close-held" { param($r) $r.layout.frame_hold.frozen } | Out-Null
        $request=Request "$mode-close" close
        # Benchmark reports are rate limited. Once the host is closed there are
        # no more native state callbacks to refresh a throttled command receipt.
        Start-Sleep -Milliseconds 350
        $request=Request "$mode-close-observe" observe
        Wait-Report $request "$mode-close" { param($r) $r.media.session_id -le 0 -and -not $r.layout.frame_hold.visible -and -not $r.layout.frame_hold.frozen } | Out-Null
        $result.modes+=@{mode=$mode; reference_request=$before.request_id; frozen_request=$during.request_id;
            freeze_copy_us=$held.layout.frame_hold.freeze_copy_us; rgba_source_size=$before.media.format; paused_seek=$true; rapid_seek=$true; playing_seek=$true}
        Write-Output "Completed device seek mode: $mode"
    }
    $result.state='passed_state_trace_pending_independent_pixel_audit'
} finally {
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    & $adb -s $Serial logcat -d -t 3500 | Set-Content "$directory/logcat.txt"
    Write-Output "Seek hold evidence: $directory"
}
