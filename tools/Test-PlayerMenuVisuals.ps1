param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output=Join-Path $workspace 'artifacts/ui-polish'
$sourceHashes=@{}
foreach ($file in Get-ChildItem "$workspace/app/godot/scripts","$workspace/app/godot/shaders","$workspace/app/godot/tests" -File) {
    $relative=[IO.Path]::GetRelativePath($workspace,$file.FullName).Replace('\','/')
    $sourceHashes[$relative]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
foreach ($case in @(
    @{name='player';script='render_player_menu.gd';variable='QUEST_PLAYER_MENU_PREVIEW_DIR'},
    @{name='library';script='render_recent_menu.gd';variable='QUEST_RECENT_PREVIEW_DIR'},
    @{name='entry';script='render_main_ui.gd';variable='QUEST_MAIN_UI_PREVIEW_DIR'})) {
    $destination=Join-Path $output $case.name
    [Environment]::SetEnvironmentVariable($case.variable,$destination,'Process')
    $stdout=Join-Path $output ($case.name+'-stdout.log')
    $stderr=Join-Path $output ($case.name+'-stderr.log')
    $arguments=@('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3',
        '--path',"$workspace/app/godot",'--script',('res://tests/'+$case.script))
    $process=Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(60000)) { throw "Render remains active: PID $($process.Id); inspect before retrying" }
    if ($process.ExitCode -ne 0) { throw "Render failed: $($case.name)" }
    $log=(Get-Content $stdout -Raw)+(Get-Content $stderr -Raw)
    if ($log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw "Render errors: $($case.name)" }
    $report=Get-Content "$destination/verification.json" -Raw | ConvertFrom-Json
    if ($report.state -ne 'passed' -or $report.failures.Count -ne 0) { throw "Visual guard failed: $($case.name)" }
}
foreach ($path in $sourceHashes.Keys) {
    if ((Get-FileHash "$workspace/$path" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHashes[$path]) { throw "Source changed during render: $path" }
}
@{state='passed';source_sha256=$sourceHashes;scope='Actual Godot entry scene and production menus with supplied stress states on desktop NVIDIA OpenGL; Quest binocular pixels/physical pointing not verified';
    physical_quest_verified=$false;binocular_XR_verified=$false} | ConvertTo-Json -Depth 6 | Set-Content "$output/verification.json" -Encoding utf8
Write-Output 'Production menu visuals and entry scene: passed'
