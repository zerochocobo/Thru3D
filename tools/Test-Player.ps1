param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$RenderPreview)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$projectDirectory = Join-Path $workspace 'app\godot'
$logDirectory = Join-Path $workspace 'artifacts\logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_input_visuals.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'input-visuals-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'input-visuals-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Input model visibility regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_i18n.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'i18n-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'i18n-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'UI localization regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_hand_pointer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'hand-pointer-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'hand-pointer-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Hand pointer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c01_c02.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'Host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c03_media.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'c03-host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'C03 host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'c03-host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C03 host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c04_layout.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'c04-host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'C04 host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'c04-host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C04 host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c05_playback.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'c05-host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'C05 host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'c05-host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C05 host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_end.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-end-host.log')
if ($LASTEXITCODE -ne 0) { throw 'MPV EOF host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'mpv-end-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV EOF host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_seek_hold.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-seek-hold-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'mpv-seek-hold-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV seek hold regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_audio.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-audio-host.log')
if ($LASTEXITCODE -ne 0) { throw 'MPV audio host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'mpv-audio-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV audio host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_subtitles.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-subtitles-host.log')
if ($LASTEXITCODE -ne 0) { throw 'MPV subtitle host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'mpv-subtitles-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV subtitle host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_mode_memory.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-mode-memory-host.log')
if ($LASTEXITCODE -ne 0) { throw 'File mode memory host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'file-mode-memory-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'File mode memory host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_player_sticks.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'player-sticks-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Player stick host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'player-sticks-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Player stick host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_recent_files.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'recent-files-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Recent files host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'recent-files-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Recent files host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_recent_pointer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'recent-pointer-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Recent pointer host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'recent-pointer-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Recent pointer host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_color_grade.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'color-grade-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'color-grade-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Color grading controls failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_color_grade.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'color-grade-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'color-grade-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Color grading pixels failed.' }
# Library pictures render a frame, so this one needs a renderer.
& $env:GODOT_EXE --xr-mode off --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/test_thumbnails.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'thumbnails-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Library picture host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'thumbnails-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Library picture host regression reported runtime errors.' }
# 2D->3D per-eye parallax from the near map (desktop OpenGL; XR multiview not covered).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_depth_parallax.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'depth-parallax-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Depth parallax render regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_menu.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-menu-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Library menu host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_cloud_pagination.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'cloud-pagination-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'cloud-pagination-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Cloud pagination regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_servers.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'media-servers-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'media-servers-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Media server host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_cloud_accounts.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'cloud-accounts-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'cloud-accounts-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Cloud account management regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_naming.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'media-naming-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Media naming host regression failed.' }
# Alpha-packed fisheye files decoded by the MPV pair shader (desktop OpenGL).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_packed_alpha_pair.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'packed-alpha-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Packed alpha render regression failed.' }
# Top-bottom eyes and fisheye lens angles in the MPV pair shader (desktop OpenGL).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_layout_lens.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'layout-lens-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Layout and lens render regression failed.' }
# Flat screen curved round the eyes, with a corner bracket (desktop OpenGL).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_screen_curve.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'screen-curve-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Screen curve render regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_player_menu.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'player-menu-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Player menu host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'player-menu-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Player menu host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_bookmarks.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'bookmarks-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'bookmarks-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Bookmark storage and pointer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_flat_screen_controls.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'flat-screen-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'flat-screen-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Flat screen controls regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 2500 --script res://tests/test_photos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photos-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photos-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo host regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 2500 --script res://tests/render_photos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photos-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photos-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo render regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 3000 --script res://tests/test_background.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'background-test.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'background-test.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Application background regression failed.' }
if ($RenderPreview) {
    $env:QUEST_PREVIEW_PATH = Join-Path $workspace 'artifacts\calibration-preview.png'
    $stdoutPath = Join-Path $logDirectory 'preview-render.log'
    $stderrPath = Join-Path $logDirectory 'preview-render-errors.log'
    $arguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_calibration.gd')
    $process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not $process.WaitForExit(60000)) { throw "Preview process remains active (PID $($process.Id)); inspect it before retrying." }
    if ($process.ExitCode -ne 0) { throw 'OpenGL preview process failed.' }
    $renderLog = (Get-Content $stdoutPath -Raw) + (Get-Content $stderrPath -Raw)
    if ($renderLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'OpenGL preview reported errors.' }
    if (-not (Test-Path -LiteralPath $env:QUEST_PREVIEW_PATH)) { throw 'OpenGL preview did not produce an image.' }
    Write-Output "Preview: $env:QUEST_PREVIEW_PATH"
    $env:QUEST_VIDEO_UV_PATH = Join-Path $workspace 'artifacts\video-uv-preview.png'
    $uvStdout = Join-Path $logDirectory 'video-uv-render.log'
    $uvStderr = Join-Path $logDirectory 'video-uv-render-errors.log'
    $uvArguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_video_uv.gd')
    $uvProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $uvArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $uvStdout -RedirectStandardError $uvStderr
    if (-not $uvProcess.WaitForExit(60000)) { throw "Video UV render remains active (PID $($uvProcess.Id)); inspect it before retrying." }
    if ($uvProcess.ExitCode -ne 0) { throw 'C03 video UV render failed.' }
    $uvLog = (Get-Content $uvStdout -Raw) + (Get-Content $uvStderr -Raw)
    if ($uvLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C03 video UV render reported errors.' }
    if (-not (Test-Path -LiteralPath $env:QUEST_VIDEO_UV_PATH)) { throw 'C03 video UV render did not produce an image.' }
    Write-Output "Video UV preview: $env:QUEST_VIDEO_UV_PATH"
    $env:QUEST_C04_ALPHA_PATH = Join-Path $workspace 'artifacts\c04-alpha-preview.png'
    $alphaStdout = Join-Path $logDirectory 'c04-render.log'
    $alphaStderr = Join-Path $logDirectory 'c04-render-errors.log'
    $alphaArguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_c04_alpha.gd')
    $alphaProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $alphaArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $alphaStdout -RedirectStandardError $alphaStderr
    if (-not $alphaProcess.WaitForExit(60000)) { throw "C04 render remains active (PID $($alphaProcess.Id)); inspect it before retrying." }
    if ($alphaProcess.ExitCode -ne 0) { throw 'C04 render failed.' }
    $alphaLog = (Get-Content $alphaStdout -Raw) + (Get-Content $alphaStderr -Raw)
    if ($alphaLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C04 render reported errors.' }
    if (-not (Test-Path -LiteralPath $env:QUEST_C04_ALPHA_PATH)) { throw 'C04 render did not produce an image.' }
    Write-Output "C04 Alpha preview: $env:QUEST_C04_ALPHA_PATH"
    $env:QUEST_R03_PAIR_PATH = Join-Path $workspace 'artifacts\r03-pair-render.json'
    $pairStdout = Join-Path $logDirectory 'r03-pair-render.log'
    $pairStderr = Join-Path $logDirectory 'r03-pair-render-errors.log'
    $pairArguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_r03_pair.gd')
    $pairProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $pairArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $pairStdout -RedirectStandardError $pairStderr
    if (-not $pairProcess.WaitForExit(60000)) { throw "R03 pair render remains active (PID $($pairProcess.Id)); inspect it before retrying." }
    if ($pairProcess.ExitCode -ne 0) { throw 'R03 native pair render failed.' }
    $pairLog = (Get-Content $pairStdout -Raw) + (Get-Content $pairStderr -Raw)
    if ($pairLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'R03 native pair render reported errors.' }
    $pairReport = Get-Content $env:QUEST_R03_PAIR_PATH -Raw | ConvertFrom-Json
    if ($pairReport.state -ne 'passed' -or $pairReport.samples.Count -ne 288 -or $pairReport.borrow_cycles -ne 3) { throw 'R03 pair render evidence incomplete.' }
    Write-Output "R03 native pair render: $env:QUEST_R03_PAIR_PATH"
}

& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_display_quality.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'display-quality-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'display-quality-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Display quality settings failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_sharpness.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'sharpness-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'sharpness-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Sharpness pixels failed.' }
