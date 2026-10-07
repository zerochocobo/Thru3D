param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = Join-Path $ToolRoot 'jdk/jdk-17.0.20.1+1'
$env:ANDROID_HOME = Join-Path $ToolRoot 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_NDK_HOME = Join-Path $env:ANDROID_HOME 'ndk/29.0.14206865'
$env:GRADLE_USER_HOME = Join-Path $ToolRoot 'gradle-cache'
$env:ANDROID_USER_HOME = Join-Path $ToolRoot 'android-user'
$env:TEMP = Join-Path $ToolRoot 'tmp'
$env:TMP = $env:TEMP
$env:QUEST_NCNN_ROOT = Join-Path $ToolRoot 'ncnn/20260526/ncnn-20260526-android-vulkan/arm64-v8a'
$env:QUEST_NCNN_TOOLS = Join-Path $ToolRoot 'ncnn/20260526-windows/ncnn-20260526-windows-vs2022/x64/bin'
$env:QUEST_MPV_ROOT = Join-Path $ToolRoot 'mpv/2026-09-17'
$env:QUEST_MNN_SOURCE = Join-Path $ToolRoot 'mnn/source-3.6.1-vrpp'
$env:QUEST_MNN_LIB = Join-Path $ToolRoot 'mnn/build-android-arm64-lib-vrpp/libMNN.a'
if (-not $env:GODOT_EXE) {
    $godotCommand = Get-Command godot -ErrorAction SilentlyContinue
    if ($godotCommand) { $env:GODOT_EXE = $godotCommand.Source }
    else { throw 'Set GODOT_EXE to the Godot executable. See docs/BUILD.md.' }
}
$toolPaths = @((Join-Path $env:JAVA_HOME 'bin'), (Join-Path $env:ANDROID_HOME 'platform-tools'),
    (Join-Path $env:ANDROID_HOME 'cmdline-tools/latest/bin'), (Join-Path $env:ANDROID_HOME 'cmake/3.31.6/bin'))
if (Test-Path -LiteralPath $env:QUEST_NCNN_TOOLS) { $toolPaths += $env:QUEST_NCNN_TOOLS }
foreach ($path in @($env:JAVA_HOME, $env:ANDROID_HOME, $env:ANDROID_NDK_HOME, $env:QUEST_NCNN_ROOT, $env:GODOT_EXE, $env:QUEST_MNN_SOURCE, $env:QUEST_MNN_LIB)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing tool/dependency: $path. See docs/BUILD.md." }
}
foreach ($path in @($env:GRADLE_USER_HOME, $env:ANDROID_USER_HOME, $env:TEMP)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
$env:Path = ($toolPaths + @($env:Path -split ';' | Where-Object { $_ -and $_ -notin $toolPaths })) -join ';'
Write-Output 'Thru3D Android environment active.'
