param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'artifacts\mpv-subtitles-host'
$build = Join-Path $workspace 'build\native-mpv-json'
& "$ToolRoot\android-sdk\cmake\3.31.6\bin\cmake.exe" -S "$workspace\benchmarks\native_mpv_json" -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Native JSON configuration failed.' }
& "$ToolRoot\android-sdk\cmake\3.31.6\bin\cmake.exe" --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Native JSON compilation failed.' }
& "$workspace\.venv\Scripts\python.exe" "$workspace\benchmarks\native_mpv_json\verify.py" --executable "$build\Release\mpv_json_oracle.exe" --output "$output\json"
if ($LASTEXITCODE -ne 0) { throw 'Independent native JSON oracle failed.' }
& "$workspace\.venv\Scripts\python.exe" "$workspace\tools\media\generate_mp06_subtitle_fixture.py"
if ($LASTEXITCODE -ne 0) { throw 'Subtitle fixture mux/timing verification failed.' }
$env:QUEST_SUBTITLE_PREVIEW_DIR = Join-Path $output 'render'
$stdout = Join-Path $workspace 'artifacts\logs\mpv-subtitles-render.log'
$stderr = Join-Path $workspace 'artifacts\logs\mpv-subtitles-render-errors.log'
$arguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3',
    '--path',"$workspace\app\godot",'--script','res://tests/render_mpv_subtitles.gd')
$process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $process.WaitForExit(60000)) { throw "Subtitle renderer remains active (PID $($process.Id)); inspect before retrying." }
if ($process.ExitCode -ne 0) { throw 'Subtitle desktop rendering failed.' }
$log = (Get-Content $stdout -Raw) + (Get-Content $stderr -Raw)
if ($log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Subtitle renderer reported errors.' }
$render = Get-Content (Join-Path $env:QUEST_SUBTITLE_PREVIEW_DIR 'verification.json') -Raw | ConvertFrom-Json
if ($render.state -ne 'passed' -or $render.caption_white_pixels[0] -lt 100 -or $render.caption_white_pixels[1] -lt 100 -or $render.caption_white_pixels[2] -ne 0) { throw 'Caption pixel evidence incomplete.' }
$env:PROJECTED_SUBTITLE_OUTPUT = Join-Path $output 'projected'
$arguments[-1] = 'res://tests/render_projected_subtitles.gd'
$stdout = Join-Path $workspace 'artifacts\logs\projected-subtitles-render.log'
$stderr = Join-Path $workspace 'artifacts\logs\projected-subtitles-render-errors.log'
$process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $process.WaitForExit(60000)) { throw "Projected subtitle renderer remains active (PID $($process.Id)); inspect before retrying." }
if ($process.ExitCode -ne 0) { throw 'Projected subtitle rendering failed.' }
$log = (Get-Content $stdout -Raw) + (Get-Content $stderr -Raw)
if ($log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Projected subtitle renderer reported errors.' }
$render = Get-Content (Join-Path $env:PROJECTED_SUBTITLE_OUTPUT 'verification.json') -Raw | ConvertFrom-Json
if ($render.state -ne 'passed' -or $render.samples.Count -ne 9 -or $render.motion_samples.Count -ne 18) { throw 'Projected caption pixel evidence incomplete.' }
Write-Output 'MPV subtitle native JSON/fixture mux/flat and three immersive projection rendering checks passed. Quest execution pending.'
