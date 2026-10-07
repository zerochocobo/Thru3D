param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$projectDirectory = Join-Path $ToolRoot 'build\godot-smoke'
$artifactDirectory = Join-Path $ToolRoot 'artifacts'
$logDirectory = Join-Path $ToolRoot 'logs'
foreach ($directory in @($projectDirectory, $artifactDirectory, $logDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
Copy-Item -Path "$PSScriptRoot\smoke_project\*" -Destination $projectDirectory -Recurse -Force
Copy-Item -LiteralPath (Join-Path $ToolRoot 'openxr-vendors\5.1.0\asset\addons') -Destination $projectDirectory -Recurse -Force
# This fixed Godot/Vendors combination can crash on immediate cold-import exit.
# Give the editor its already-tested initialization loop before exporting.
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --editor --quit-after 600 2>&1 | Out-File -LiteralPath (Join-Path $logDirectory 'godot-smoke-import.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Godot smoke import failed; inspect godot-smoke-import.log.' }
if (Select-String -LiteralPath (Join-Path $logDirectory 'godot-smoke-import.log') -Pattern 'SCRIPT ERROR|SHADER ERROR|^ERROR:' -Quiet) {
    throw 'Godot smoke import contains errors; inspect godot-smoke-import.log.'
}
$apkPath = Join-Path $artifactDirectory 'quest3-environment-smoke.apk'
$exportArguments = @('--headless', '--xr-mode', 'off', '--path', $projectDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $projectDirectory 'android\build\build.gradle'))) {
    $exportArguments += '--install-android-build-template'
}
$exportArguments += @('--export-debug', 'Quest 3 Environment', $apkPath)
& $env:GODOT_EXE @exportArguments 2>&1 | Out-File -LiteralPath (Join-Path $logDirectory 'godot-smoke-export.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Godot smoke export failed; inspect godot-smoke-export.log.' }
if (Select-String -LiteralPath (Join-Path $logDirectory 'godot-smoke-export.log') -Pattern 'SCRIPT ERROR|SHADER ERROR|^ERROR:' -Quiet) {
    throw 'Godot smoke export contains errors; inspect godot-smoke-export.log.'
}
if (-not (Test-Path -LiteralPath $apkPath)) { throw 'Godot did not produce the APK.' }
& "$env:ANDROID_HOME\build-tools\36.1.0\apksigner.bat" verify --verbose $apkPath
if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
& "$env:ANDROID_HOME\build-tools\36.1.0\zipalign.exe" -c -P 16 -v 4 $apkPath *> (Join-Path $logDirectory 'godot-smoke-zipalign.log')
if ($LASTEXITCODE -ne 0) { throw 'APK alignment verification failed.' }
Get-FileHash -LiteralPath $apkPath -Algorithm SHA256
Write-Output "Built environment smoke APK: $apkPath"
