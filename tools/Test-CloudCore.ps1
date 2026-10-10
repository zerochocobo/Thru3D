param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
& "$PSScriptRoot\environment\Prepare-OpenList.ps1" -ToolRoot $ToolRoot
$cache = Join-Path $workspace '.cache\openlist'
$source = Join-Path $cache 'OpenList-2bdf16d5967d0a403f67d809efd5a418b8f5bd30'
Get-ChildItem "$workspace\cloud\openlist" -Filter '*_test.go' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination "$source\cloudcore\$($_.Name)" -Force
}
$env:GOROOT = "$cache\go"
$env:GOPATH = "$cache\gopath"
$env:GOMODCACHE = "$cache\modules"
$env:GOCACHE = "$cache\go-build"
$env:GOTOOLCHAIN = 'local'
$env:CGO_ENABLED = '0'
& "$cache\go\bin\go.exe" -C $source test -mod=mod -timeout 180s ./cloudcore -v
if ($LASTEXITCODE) { throw 'Cloud core integration test failed.' }
