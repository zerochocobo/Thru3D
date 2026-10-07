# Host build and run of the 2D->3D near-map stabilizer test (MSVC Build Tools).
# -Cli builds build\depth-stabilizer-test\depth_stabilizer_cli.exe (offline sequences) instead of testing.
param([switch]$Cli)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$out = Join-Path $workspace 'build\depth-stabilizer-test'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$main = if ($Cli) { 'depth_stabilizer_cli' } else { 'depth_stabilizer_test' }
$sources = "`"$workspace\tests\native\$main.cpp`" `"$workspace\native\rvm\depth_stabilizer.cpp`""
# vcvars prints a harmless vswhere notice on stderr; only the exit code decides.
$ErrorActionPreference = 'Continue'
cmd /c "`"$vcvars`" >nul 2>nul && cl /nologo /std:c++17 /O2 /EHsc /W4 /Fo`"$out\\`" /Fe`"$out\$main.exe`" $sources"
if ($LASTEXITCODE -ne 0) { throw "$main build failed." }
$ErrorActionPreference = 'Stop'
if ($Cli) { Write-Output "Built $out\$main.exe"; exit 0 }
& "$out\$main.exe"
if ($LASTEXITCODE -ne 0) { throw 'Depth stabilizer test failed.' }
