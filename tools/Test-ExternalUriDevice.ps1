param([Parameter(Mandatory=$true)][string]$Serial, [switch]$Install)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
$adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$player='com.wapok.thru3d'
$provider='org.vrpassthroughplayer.urifixture'
$directory=Join-Path $workspace ('artifacts/device/'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_external_uri_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$build=Get-Content "$workspace/artifacts/build_manifest.json" -Raw | ConvertFrom-Json
Copy-Item "$workspace/artifacts/build_manifest.json" $directory
$fixtureApk="$workspace/android/uri-fixture/build/outputs/apk/debug/uri-fixture-debug.apk"
$fixtureHash=(Get-FileHash $fixtureApk -Algorithm SHA256).Hash.ToLowerInvariant()
$playerHash=(Get-FileHash "$workspace/artifacts/quest3-player-debug.apk" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($build.apk_sha256 -ne $playerHash) { throw 'Player APK differs from manifest' }
& $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-before.txt"
& $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-before.txt"
if ($Install) {
    & $adb -s $Serial install -r "$workspace/artifacts/quest3-player-debug.apk" | Set-Content "$directory/player-install.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Player installation failed' }
    & $adb -s $Serial install -r $fixtureApk | Set-Content "$directory/provider-install.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Test provider installation failed' }
}
function Installed-Hash([string]$package) {
    $path=((& $adb -s $Serial shell pm path $package) | Where-Object {$_ -match '/base\.apk$'} | Select-Object -First 1) -replace '^package:',''
    if ($path -notmatch '^/data/app/[A-Za-z0-9_=/+.~\-]+/base\.apk$') { throw "Installed path unavailable: $package" }
    return ((& $adb -s $Serial shell sha256sum $path) -split '\s+')[0]
}
if ((Installed-Hash $player) -ne $playerHash -or (Installed-Hash $provider) -ne $fixtureHash) { throw 'Installed APK bytes differ' }
& $adb -s $Serial shell dumpsys package $player | Set-Content "$directory/player-package.txt"
& $adb -s $Serial shell dumpsys package $provider | Set-Content "$directory/provider-package.txt"
& $adb -s $Serial shell cmd package list packages -U $player | Set-Content "$directory/player-uid.txt"
& $adb -s $Serial shell cmd package list packages -U $provider | Set-Content "$directory/provider-uid.txt"
function Read-Json([string]$package,[string]$file) {
    $text=& $adb -s $Serial shell run-as $package cat "files/diagnostics/$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}
function Provider([string]$label,[string]$operation) {
    $key='provider_'+[guid]::NewGuid().ToString('N')
    & $adb -s $Serial shell am broadcast -n "$provider/.FixtureCommandReceiver" --es request $key --es operation $operation | Set-Content "$directory/$label-broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw "Provider broadcast failed: $label" }
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do {
        $r=Read-Json $provider "$key.json"
        if ($r -and $r.request -eq $key) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $r -or $r.state -ne 'applied' -or $r.operation -ne $operation) { throw "Provider command failed: $label" }
    $r | ConvertTo-Json -Depth 10 | Set-Content "$directory/$label-provider.json"
}
function Player([string]$label,[string]$case,[switch]$Decode) {
    $key='player_'+[guid]::NewGuid().ToString('N')
    $action=if ($Decode) { 'DEBUG_MPV_URI' } else { 'DEBUG_LOCAL_ACCESS' }
    $args=@('-s',$Serial,'shell','am','broadcast','-n',"$player/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",'-a',"$player.$action",'--es','request',$key)
    if (-not $Decode) { $args+=@('--es','case',$case) }
    & $adb @args | Set-Content "$directory/$label-broadcast.txt"
    if ($LASTEXITCODE -ne 0) { throw "Player broadcast failed: $label" }
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do {
        $receipt=Read-Json $player "debug_request_$key.json"
        if ($receipt -and $receipt.request -eq $key) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $receipt -or $receipt.state -ne 'accepted' -or $receipt.id -le 0) { throw "Player request rejected: $label" }
    $receipt | ConvertTo-Json -Depth 10 | Set-Content "$directory/$label-receipt.json"
    $file=if ($Decode) { "mpv_uri_$($receipt.id).json" } else { "local_access_$($receipt.id).json" }
    $deadline=[DateTime]::UtcNow.AddSeconds(35)
    do {
        $r=Read-Json $player $file
        if ($r -and $r.request_id -eq $receipt.id -and $r.diagnostic_process -eq $receipt.diagnostic_process) { break }
        $r=$null
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $r) { throw "Fresh player report absent: $label" }
    $r | ConvertTo-Json -Depth 50 | Set-Content "$directory/$label-report.json"
    Write-Output "Collected $label : $($r.state) / $($r.error)"
}
$result=@{state='failed';apk_sha256=$playerHash;provider_apk_sha256=$fixtureHash;activity_launched=$false;
    scope='Real cross-UID DocumentsProvider grants/revocation/process restarts and native MPV FD decode; picker UI, device reboot, Godot catalog/resume, RVM/XR and audio unverified'}
try {
    & $adb -s $Serial shell am force-stop $player
    Provider 'restore' 'restore'
    Provider 'reset_grants' 'revoke'
    Player 'no_grant' 'external_check'
    Provider 'temporary' 'grant'
    Player 'temporary_check' 'external_check'
    Player 'cannot_persist_temporary' 'external_take'
    Provider 'revoke_temporary' 'revoke'
    Provider 'offer_persistable' 'offer_persistable'
    Player 'offered_check' 'external_check'
    Player 'take_persistable' 'external_take'
    & $adb -s $Serial shell am force-stop $player
    Player 'player_restart' 'external_check'
    & $adb -s $Serial shell am force-stop $provider
    Player 'provider_restart' 'external_check'
    Player 'native_decode' '' -Decode
    Provider 'remove' 'remove'
    Player 'missing_document' 'external_check'
    Provider 'restore_again' 'restore'
    Player 'restored_document' 'external_check'
    Player 'release_persistable' 'external_release'
    Provider 'revoke_released' 'revoke'
    Player 'released_and_revoked' 'external_check'
    Provider 'offer_again' 'offer_persistable'
    Player 'retake' 'external_take'
    Provider 'revoke_persisted' 'revoke'
    Player 'revoked_persisted' 'external_check'
    Provider 'offer_reselected' 'offer_persistable'
    Player 'reselected' 'external_take'
    $result.state='collected_scoped_external_uri_trace'
} catch { $result.error=$_.Exception.Message }
finally {
    $appPid=(& $adb -s $Serial shell pidof $player | Out-String).Trim()
    if ($appPid -match '^\d+$') { & $adb -s $Serial logcat -d --pid=$appPid -v threadtime | Set-Content "$directory/player-logcat.txt" }
    Provider 'cleanup_grants' 'revoke'
    & $adb -s $Serial shell am force-stop $player
    & $adb -s $Serial shell am force-stop $provider
    & $adb -s $Serial shell dumpsys battery | Set-Content "$directory/battery-after.txt"
    & $adb -s $Serial shell dumpsys power | Set-Content "$directory/power-after.txt"
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    Write-Output "Evidence: $directory"
}
if ($result.state -ne 'collected_scoped_external_uri_trace') { throw $result.error }
& "$workspace/.venv/Scripts/python.exe" "$workspace/benchmarks/external_uri_device.py" $directory
if ($LASTEXITCODE -ne 0) {
    $result.state='failed_independent_external_uri_audit'
    $result | ConvertTo-Json -Depth 10 | Set-Content "$directory/result.json"
    throw 'Independent external URI audit failed'
}
