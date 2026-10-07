param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$sourceDirectory = Join-Path $PSScriptRoot 'native_smoke'
$buildDirectory = Join-Path $ToolRoot 'build\native-smoke'
$cmake = Join-Path $env:ANDROID_HOME 'cmake\3.31.6\bin\cmake.exe'
& $cmake -S $sourceDirectory -B $buildDirectory -G Ninja `
    "-DCMAKE_TOOLCHAIN_FILE=$env:ANDROID_NDK_HOME\build\cmake\android.toolchain.cmake" `
    '-DANDROID_ABI=arm64-v8a' '-DANDROID_PLATFORM=android-29' `
    '-DANDROID_STL=c++_shared' '-DCMAKE_BUILD_TYPE=Release' `
    "-Dncnn_DIR=$env:QUEST_NCNN_ROOT\lib\cmake\ncnn"
if ($LASTEXITCODE -ne 0) { throw 'Native smoke configuration failed.' }
& $cmake --build $buildDirectory --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Native smoke build failed.' }
$libraryPath = Join-Path $buildDirectory 'libquest_ncnn_smoke.so'
& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe" -h -d -l $libraryPath
if ($LASTEXITCODE -ne 0) { throw 'ELF inspection failed.' }
Write-Output "Built: $libraryPath"

