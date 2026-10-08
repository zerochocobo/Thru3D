param([Parameter(Mandatory=$true)][string]$Serial, [switch]$Rvm, [switch]$Controlled, [switch]$RvmVideo, [switch]$Mpv, [switch]$MpvGpu, [switch]$MpvSource, [switch]$WakeForTest,
    [string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }),
    [ValidateSet('c03_sbs_grid','c04_alpha_f180','c04_independent_alpha')]
    [string[]]$Fixtures = @('c03_sbs_grid','c04_alpha_f180','c04_independent_alpha'))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$app = 'com.wapok.thru3d'
$receiver = "$app/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver"
$model = (& $adb -s $Serial shell getprop ro.product.model | Out-String).Trim()
if ($model -notmatch '^Quest\s*3$') { throw "Expected authorized Quest3: $model" }
if (-not $Rvm -and -not $Controlled -and -not $RvmVideo -and -not $Mpv -and -not $MpvGpu -and -not $MpvSource) { throw 'Choose a diagnostic mode including -MpvSource.' }
if ($Controlled -and $RvmVideo) { throw 'Run -Controlled and -RvmVideo in separate evidence runs.' }
$directory = Join-Path $workspace ('artifacts\device\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_automatic')
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$build = Get-Content (Join-Path $workspace 'artifacts\build_manifest.json') -Raw | ConvertFrom-Json
if ($MpvSource -and -not $build.mpv_source_frame_extension) { throw 'Install a SourceFrame Debug build for -MpvSource.' }
$packagePaths = @(& $adb -s $Serial shell pm path $app)
if ($LASTEXITCODE -ne 0 -or $packagePaths.Count -ne 1 -or $packagePaths[0] -notmatch '^package:(/data/app/.+/base\.apk)$') { throw 'Expected one installed base APK.' }
$installedApkPath = $Matches[1]
$deviceHashOutput = (& $adb -s $Serial shell sha256sum $installedApkPath | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $deviceHashOutput -notmatch '^([a-f0-9]{64})\s') { throw 'Cannot verify installed APK identity.' }
$installedHash = $Matches[1]
if ($installedHash -ne $build.apk_sha256) { throw 'Installed APK differs from the local build manifest; install the current build first.' }
& $adb -s $Serial shell dumpsys battery > (Join-Path $directory 'battery-before.txt')
& $adb -s $Serial shell dumpsys thermalservice > (Join-Path $directory 'thermal-before.txt')
function Read-AppJson([string]$Filename) {
    $value = (& $adb -s $Serial exec-out run-as $app cat "files/diagnostics/$Filename" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return $value | ConvertFrom-Json } catch { return $null }
}
function Request([string]$Action, [string[]]$Extra) {
    $key = 'auto_' + [Guid]::NewGuid().ToString('N')
    $output = & $adb -s $Serial shell am broadcast -n $receiver -a "$app.$Action" --es request $key @Extra
    if ($LASTEXITCODE -ne 0) { throw "Broadcast failed: $output" }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $receipt = Read-AppJson "debug_request_$key.json"
        if ($null -ne $receipt) {
            $receipt | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $directory "request_$key.json") -Encoding utf8
            if ($receipt.state -eq 'error' -and $receipt.message -eq 'Running Godot plugin unavailable') {
                # Startup is asynchronous. A completed error did not schedule a
                # native job; retry with a fresh key so no old receipt can win.
                Start-Sleep -Milliseconds 500
                $key = 'auto_' + [Guid]::NewGuid().ToString('N')
                $output = & $adb -s $Serial shell am broadcast -n $receiver -a "$app.$Action" --es request $key @Extra
                if ($LASTEXITCODE -ne 0) { throw "Startup retry broadcast failed: $output" }
                continue
            }
            if ($receipt.state -ne 'accepted') { throw "Request rejected: $($receipt | ConvertTo-Json -Compress)" }
            return $receipt
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'No diagnostic receipt; ensure the Debug Godot plugin is running.'
}
$results = @()
$testState = 'failed'
$failure = $null
$controlledRequest = $null
$numericalFailures = @()
try {
if ($WakeForTest) {
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.prox_close > (Join-Path $directory 'wake-override.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Test proximity override request failed.' }
    & $adb -s $Serial shell input keyevent 224
    $launchReceipt = Request 'DEBUG_LAUNCH' @()
    $launchReceipt | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $directory 'launch.json') -Encoding utf8
}
if ($Rvm) {
    $profiles = (Get-Content (Join-Path $workspace 'models\manifest\rvm_profiles.json') -Raw | ConvertFrom-Json).profiles.key
    foreach ($profile in $profiles) { foreach ($backend in @('cpu','vulkan')) {
        $filename = "rvm_benchmark_${backend}_$profile.json"
        $receipt = Request 'DEBUG_RVM' @('--es','profile',$profile,'--ez','vulkan',($backend -eq 'vulkan').ToString().ToLowerInvariant())
        $deadline = [DateTime]::UtcNow.AddSeconds(180)
        $report = $null
        do {
            $candidate = Read-AppJson $filename
            if ($null -ne $candidate -and $candidate.request_id -eq $receipt.id -and
                $candidate.diagnostic_process -eq $receipt.diagnostic_process) { $report = $candidate; break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) { throw "Benchmark timeout: $profile $backend request=$($receipt.id)" }
        $report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $directory $filename) -Encoding utf8
        if ($report.requested_profile -ne $profile -or $report.requested_vulkan -ne ($backend -eq 'vulkan')) { throw 'Request/backend/profile association mismatch.' }
        $entry = @{ profile = $profile; backend = $backend; request_id = $receipt.id; state = $report.state;
            runtime_bridge = $report.runtime_bridge.state; alpha_max_abs = $report.errors.pha.max_abs; process_ms = $report.validation_process_ms }
        $results += $entry
        $entry | ConvertTo-Json -Compress -Depth 5 | Write-Output
        if ($report.state -ne 'passed' -or $report.runtime_bridge.state -ne 'passed') { throw 'Device numerical/JNI validation failed; inspect report/logcat.' }
    } }
}
if ($Controlled -or $RvmVideo) {
    foreach ($fixture in $Fixtures) {
        $action = if ($RvmVideo) { 'DEBUG_RVM_VIDEO' } else { 'DEBUG_CONTROLLED' }
        $profile = if ($RvmVideo) { '256x144' } else { '256x256' }
        $receipt = Request $action @('--es','fixture',$fixture,'--es','profile',$profile)
        $controlledRequest = $receipt.id
        $deadline = [DateTime]::UtcNow.AddSeconds(45); $report = $null
        do {
            $candidate = Read-AppJson "controlled_session_$($receipt.id).json"
            if ($null -ne $candidate -and $candidate.diagnostic_process -eq $receipt.diagnostic_process -and
                ($candidate.state.state -eq 'ended' -or $null -ne $candidate.state.code)) { $report = $candidate; break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) { throw "Controlled decode timeout: $fixture; inspect focus/GL lifecycle and report" }
        $report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $directory "controlled_$fixture.json") -Encoding utf8
        $entry = @{ fixture = $fixture; session_id = $receipt.id; state = $report.state.state; code = $report.state.code;
            captured = $report.state.captured_frames; dropped = $report.state.dropped_frames;
            last_pts_us = $report.frame.pts_us; source_pts_verified = $report.frame.source_pts_verified;
            immutable_color_frame = $report.frame.immutable_color_frame }
        $results += $entry
        $entry | ConvertTo-Json -Compress -Depth 7 | Write-Output
        if ($report.state.state -ne 'ended' -or -not $report.frame.source_pts_verified -or -not $report.frame.immutable_color_frame -or
            $report.state.captured_frames -lt 1 -or $report.state.dropped_frames -lt 0 -or
            ($report.state.captured_frames + $report.state.dropped_frames) -ne 180 -or $report.state.held_slots -ne 0 -or
            $report.state.position_ms -le 0 -or
            $report.frame.captured_frames -ne $report.state.captured_frames -or
            $report.frame.slot_token -lt 1 -or $report.frame.color_texture_id -lt 1) { throw 'Controlled decode/PTS/slot checks failed.' }
        if ($RvmVideo) {
            $reportPath = Join-Path $directory "controlled_$fixture.json"
            if (-not $report.rvm_probe -or @($report.rvm_pairs).Count -ne 8 -or $report.state.rvm_probe_pairs -ne 8) { throw 'Video RVM probe did not complete eight pairs.' }
            & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\r03_video_probe.py" collect $reportPath --adb $adb --serial $Serial
            if ($LASTEXITCODE -ne 0) { throw 'Video RVM binary evidence collection failed.' }
            & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\r03_video_probe.py" verify-gpu $reportPath
            if ($LASTEXITCODE -ne 0) { throw 'Alpha GPU upload/roundtrip failed.' }
            $entry.alpha_gpu_state = 'passed'
            & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\r03_video_probe.py" verify-rgb $reportPath
            if ($LASTEXITCODE -ne 0) { throw 'Independent full model RGB comparison failed.' }
            $entry.rgb_yuv_state = 'passed'
            & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\r03_video_probe.py" verify $reportPath
            $verificationExit = $LASTEXITCODE
            $numerical = Get-Content (Join-Path $directory "controlled_${fixture}_onnx.json") -Raw | ConvertFrom-Json
            $entry.rvm_pairs = @($report.rvm_pairs).Count
            $entry.alpha_onnx_state = $numerical.state
            $entry.alpha_max_abs = ($numerical.results.max_abs | Measure-Object -Maximum).Maximum
            if ($verificationExit -ne 0) { $numericalFailures += $fixture }
        }
        $cancel = Request 'DEBUG_CANCEL_CONTROLLED' @('--ei','id',([string]$controlledRequest))
        if ($cancel.id -ne $controlledRequest) { throw 'Probe cancellation identity mismatch.' }
        $controlledRequest = $null
    }
}
if ($Mpv) {
    foreach ($fixture in $Fixtures) {
        $receipt = Request 'DEBUG_MPV_CORE' @('--es','fixture',$fixture)
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $report = $null
        do {
            $candidate = Read-AppJson "mpv_core_$($receipt.id).json"
            if ($null -ne $candidate -and $candidate.request_id -eq $receipt.id -and
                $candidate.diagnostic_process -eq $receipt.diagnostic_process) { $report = $candidate; break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) { throw "MPV core diagnostic timeout: $fixture request=$($receipt.id)" }
        $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $directory "mpv_core_$fixture.json") -Encoding utf8
        $results += @{ fixture = $fixture; mpv_state = $report.state; mpv_version = $report.mpv_version;
            width = $report.width; height = $report.height; scope = $report.scope }
        if ($report.fixture -ne $fixture -or $report.state -ne 'passed' -or -not $report.file_loaded -or
            -not $report.video_reconfigured -or -not $report.resumed_after_format_snapshot -or -not $report.ended -or $report.end_reason -ne 0 -or
            $report.playback_error -ne 0 -or $report.hardware_decode -or $report.audio_enabled -or $report.vo -ne 'null') {
            throw "MPV core diagnostic failed: $($report | ConvertTo-Json -Compress)"
        }
        Write-Output "MPV core: $fixture $($report.state) $($report.mpv_version) $($report.width)x$($report.height)"
    }
}
if ($MpvGpu) {
    foreach ($fixture in $Fixtures) { foreach ($hardware in @($false, $true)) {
        $backend = if ($hardware) { 'hardware' } else { 'software' }
        $receipt = Request 'DEBUG_MPV_GPU' @('--es','fixture',$fixture,'--ez','hardware',$hardware.ToString().ToLowerInvariant())
        $deadline = [DateTime]::UtcNow.AddSeconds(60); $report = $null
        do {
            $candidate = Read-AppJson "mpv_gpu_$($receipt.id).json"
            if ($null -ne $candidate -and $candidate.request_id -eq $receipt.id -and
                $candidate.diagnostic_process -eq $receipt.diagnostic_process) { $report = $candidate; break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) { throw "MPV GPU timeout: $fixture $backend" }
        $reportPath = Join-Path $directory "mpv_gpu_$($fixture)_$backend.json"
        $report | ConvertTo-Json -Depth 12 | Set-Content $reportPath -Encoding utf8
        $results += @{ fixture = $fixture; backend = $backend; state = $report.state;
            hwdec_current = $report.hwdec_current; video_render_events = $report.video_render_events }
        $expectedHwdec = if ($hardware) { 'mediacodec' } else { 'no' }
        if ($report.fixture -ne $fixture -or $report.probe_kind -ne 'gpu' -or $report.state -ne 'passed' -or
            $report.requested_hardware -ne $hardware -or $report.hwdec_current -ne $expectedHwdec -or
            -not $report.file_loaded -or -not $report.ended -or $report.end_reason -ne 0 -or
            $report.playback_error -ne 0 -or $report.video_render_events -lt 10 -or
            @($report.first_paused_samples).Count -ne 18 -or $report.source_pts_verified -or
            $report.godot_context_shared -or $report.audio_enabled -or $report.vo -ne 'libmpv' -or
            -not $report.context_disposed) { throw "MPV GPU checks failed: $($report | ConvertTo-Json -Compress -Depth 8)" }
        & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_gpu_probe.py" $reportPath
        if ($LASTEXITCODE -ne 0) { throw "MPV independent pixel comparison failed: $fixture $backend" }
        Write-Output "MPV GPU: $fixture $backend $($report.hwdec_current) $($report.video_render_events) render events"
    } }
}
if ($MpvSource) {
    foreach ($hardware in @($false, $true)) {
        $backend = if ($hardware) { 'hardware' } else { 'software' }
        $receipt = Request 'DEBUG_MPV_SOURCE' @('--ez','hardware',$hardware.ToString().ToLowerInvariant())
        $deadline = [DateTime]::UtcNow.AddSeconds(60); $report = $null
        do {
            $candidate = Read-AppJson "mpv_source_$($receipt.id).json"
            if ($null -ne $candidate -and $candidate.request_id -eq $receipt.id -and
                $candidate.diagnostic_process -eq $receipt.diagnostic_process) { $report = $candidate; break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -eq $report) { throw "MPV source-frame timeout: $backend" }
        $reportPath = Join-Path $directory "mpv_source_$backend.json"
        $report | ConvertTo-Json -Depth 14 | Set-Content $reportPath -Encoding utf8
        $results += @{ fixture = 'mp03_frame_identity'; backend = $backend; state = $report.state;
            hwdec_current = $report.hwdec_current; source_records = @($report.source_records).Count }
        if ($report.requested_hardware -ne $hardware -or $report.probe_kind -ne 'source' -or
            $report.state -ne 'passed') { throw "MPV source-frame native check failed: $backend $($report.detail)" }
        & "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\mpv_source_probe.py" $reportPath
        if ($LASTEXITCODE -ne 0) { throw "MPV source-frame independent identity verification failed: $backend" }
        Write-Output "MPV source: $backend actual=$($report.hwdec_current); 180 source frames, two seeks and paused redraws verified"
    }
}
if ($numericalFailures.Count) { throw "Video RVM strict ONNX comparison failed: $($numericalFailures -join ', '); all selected GPU probes collected." }
$testState = 'passed'
} catch {
    $failure = $_.Exception.Message
    throw
} finally {
if ($null -ne $controlledRequest) {
    try {
        $cancel = Request 'DEBUG_CANCEL_CONTROLLED' @('--ei','id',([string]$controlledRequest))
        $cancel | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $directory 'cancel-on-exit.json') -Encoding utf8
    } catch { Write-Warning "Probe cancellation failed: $($_.Exception.Message)" }
}
if ($WakeForTest) {
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.automation_disable > (Join-Path $directory 'wake-restored.txt')
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Normal proximity restoration failed; restore before leaving the device.' }
}
& $adb -s $Serial shell dumpsys battery > (Join-Path $directory 'battery-after.txt')
& $adb -s $Serial shell dumpsys thermalservice > (Join-Path $directory 'thermal-after.txt')
& $adb -s $Serial logcat -d -v threadtime 'godot:V' 'VRPassthroughPlayer:V' 'QuestMpv:V' 'AndroidRuntime:E' '*:S' > (Join-Path $directory 'logcat.txt')
@{ schema_version = 1; apk_sha256 = $installedHash; device_serial = $Serial;
    scope = $(if ($MpvSource) { 'Numbered source fixture: same-render identity/PTS/pixels, seeks/redraw/final frame verified by the independent host sidecars; Godot/RVM/audio/performance remain separate' }
        else { 'Selected core decode/isolated MPV GLES with decoded-chroma reference or controlled/RVM diagnostics; precise MPV source PTS, Godot sharing, RVM/audio integration and sustained performance not inferred' });
    results = $results; state = $testState; failure = $failure } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $directory 'automatic-results.json') -Encoding utf8
Write-Output "Automatic evidence: $directory"
}
