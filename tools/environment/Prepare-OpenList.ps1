param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$Force)
$ErrorActionPreference = 'Stop'
# All callers, including Test-CloudCore and other chat builds, share one output.
$coreBuildMutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-OpenList')
$coreBuildLockHeld = $false
$pendingOutput = $null
try {
    try { $coreBuildLockHeld = $coreBuildMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $coreBuildLockHeld = $true }
    if (!$coreBuildLockHeld) {
        Write-Output 'Waiting for the active OpenList binding to finish...'
        try { $coreBuildLockHeld = $coreBuildMutex.WaitOne() }
        catch [Threading.AbandonedMutexException] { $coreBuildLockHeld = $true }
    }
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cache = Join-Path $workspace '.cache\openlist'
$revision = '2bdf16d5967d0a403f67d809efd5a418b8f5bd30' # OpenList v4.2.6
$mobileVersion = 'v0.0.0-20260908204917-8b95e45f8d3e'
$source = Join-Path $cache "OpenList-$revision"
$output = Join-Path $workspace 'app\godot\addons\quest_player\bin\cloudcore.aar'
$adapters = @(Get-ChildItem (Join-Path $workspace 'cloud\openlist') -Filter '*.go' | Where-Object { $_.Name -notlike '*_test.go' } | Sort-Object Name)
$adapterHashes = ($adapters | ForEach-Object { "$($_.Name):$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }) -join '/'
$fingerprint = "$revision/$mobileVersion/$adapterHashes/$((Get-FileHash $PSCommandPath -Algorithm SHA256).Hash)"
$stamp = Join-Path $cache 'build.stamp'
if (!$Force -and (Test-Path $output) -and (Test-Path $stamp) -and (Get-Content $stamp -Raw).Trim() -eq $fingerprint) { return }
New-Item -ItemType Directory -Force $cache, (Split-Path $output) | Out-Null
function Fetch-Verified([string]$Url, [string]$Path, [string]$Sha) {
    if (!(Test-Path $Path)) { Invoke-WebRequest $Url -OutFile $Path }
    if ((Get-FileHash $Path -Algorithm SHA256).Hash -ne $Sha) { throw "Dependency checksum mismatch: $Path" }
}
Fetch-Verified 'https://go.dev/dl/go1.27.1.windows-amd64.zip' (Join-Path $cache 'go.zip') 'a3911b5e0e1b1053f25ed0675f4c1c6aad1e2bfcf253df2b9be4caabd2edd95d'
if (!(Test-Path "$cache\go\bin\go.exe")) { Expand-Archive "$cache\go.zip" $cache }
Fetch-Verified "https://codeload.github.com/OpenListTeam/OpenList/zip/$revision" (Join-Path $cache 'openlist.zip') '7276424f72a2a5b78ec754a9559bdee25d4e32610b2d9321f17496e31768bad7'
if (!(Test-Path $source)) { Expand-Archive "$cache\openlist.zip" $cache }
. "$PSScriptRoot\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$env:PATH = "$cache\go\bin;$cache\gobin;$env:PATH"
$env:GOROOT = "$cache\go"
$env:GOPATH = "$cache\gopath"
$env:GOMODCACHE = "$cache\modules"
$env:GOCACHE = "$cache\go-build"
$env:GOBIN = "$cache\gobin"
$env:GOTOOLCHAIN = 'local'
# Activate-QuestEnvironment sets ANDROID_NDK_HOME for the pinned NDK.
$env:GOFLAGS = '-mod=mod'
New-Item -ItemType Directory -Force "$source\cloudcore", "$source\public\dist" | Out-Null
foreach ($adapter in $adapters) { Copy-Item -LiteralPath $adapter.FullName -Destination "$source\cloudcore\$($adapter.Name)" -Force }
$storageModel = Join-Path $source 'internal\model\storage.go'
$modelText = Get-Content $storageModel -Raw
$originalTag = 'json:"addition" gorm:"type:text"'
$encryptedTag = 'json:"addition" gorm:"type:text;serializer:vrpp_secret"'
if (!$modelText.Contains($originalTag) -and !$modelText.Contains($encryptedTag)) { throw 'OpenList credential field changed; review the adapter.' }
[IO.File]::WriteAllText($storageModel, $modelText.Replace($originalTag, $encryptedTag))
# Only JNI management and a stream router are used; upstream's web assets are not packaged.
Set-Content "$source\public\dist\index.html" '<!doctype html><title>VR Player Cloud</title>' -Encoding utf8
Push-Location $source
try {
    & go install "golang.org/x/mobile/cmd/gomobile@$mobileVersion"
    if ($LASTEXITCODE) { throw 'gomobile installation failed' }
    & go install "golang.org/x/mobile/cmd/gobind@$mobileVersion"
    if ($LASTEXITCODE) { throw 'gobind installation failed' }
    & go mod edit "-require=golang.org/x/mobile@$mobileVersion"
    $pendingOutput = Join-Path $cache ('cloudcore-' + [Guid]::NewGuid().ToString('N') + '.aar')
    & gomobile bind -target=android/arm64 -androidapi 29 -javapkg org.vrpassthroughplayer -ldflags '-s -w -extldflags=-Wl,-z,max-page-size=16384' -o $pendingOutput ./cloudcore
    if ($LASTEXITCODE) { throw 'OpenList Android binding failed' }
    # Read every entry before publishing; a failed/partial archive must not be stamped.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($pendingOutput)
    try {
        if (!$archive.GetEntry('jni/arm64-v8a/libgojni.so') -or !$archive.GetEntry('classes.jar')) {
            throw 'OpenList binding is missing its Android library or JNI classes.'
        }
        foreach ($entry in $archive.Entries) {
            $stream = $entry.Open()
            try { $stream.CopyTo([IO.Stream]::Null) } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    if (Test-Path -LiteralPath $output) { [IO.File]::Replace($pendingOutput, $output, [NullString]::Value) }
    else { [IO.File]::Move($pendingOutput, $output) }
    $pendingOutput = $null
    Set-Content $stamp $fingerprint -Encoding ascii
} finally { Pop-Location }

} finally {
    if ($pendingOutput -and (Test-Path -LiteralPath $pendingOutput)) {
        $resolvedPending = [IO.Path]::GetFullPath($pendingOutput)
        $resolvedCache = [IO.Path]::GetFullPath($cache).TrimEnd('\') + '\'
        if (!$resolvedPending.StartsWith($resolvedCache, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove an OpenList temporary file outside its cache.'
        }
        Remove-Item -LiteralPath $resolvedPending -Force
    }
    if ($coreBuildLockHeld) { $coreBuildMutex.ReleaseMutex() }
    $coreBuildMutex.Dispose()
}
