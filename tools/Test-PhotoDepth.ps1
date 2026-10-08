$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$out = Join-Path $workspace 'build\photo-depth-test'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$sources = "`"$workspace\tests\native\photo_depth_test.cpp`" `"$workspace\native\rvm\photo_depth.cpp`""
$ErrorActionPreference = 'Continue'
cmd /c "`"$vcvars`" >nul 2>nul && cl /nologo /std:c++17 /O2 /EHsc /W4 /Fo`"$out\\`" /Fe`"$out\photo_depth_test.exe`" $sources"
if ($LASTEXITCODE -ne 0) { throw 'Photo depth test build failed.' }
$ErrorActionPreference = 'Stop'
& "$out\photo_depth_test.exe"
if ($LASTEXITCODE -ne 0) { throw 'Photo depth test failed.' }
