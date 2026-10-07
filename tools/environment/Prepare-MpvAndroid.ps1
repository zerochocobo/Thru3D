param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }),
    [ValidateSet('OfficialRelease','SourceFrame')][string]$Candidate = 'OfficialRelease')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($Candidate -eq 'SourceFrame') {
    $sourceManifestPath = Join-Path $workspace 'third_party\mpv\source-build.json'
    if (-not (Test-Path -LiteralPath $sourceManifestPath)) { throw 'Compile and export the source-frame candidate first.' }
    $sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
    $patch = Get-Content (Join-Path $workspace 'native\mpv\patches\source-frame-manifest.json') -Raw | ConvertFrom-Json
    if ($sourceManifest.candidate -ne 'source-frame' -or $sourceManifest.api_version -ne 1 -or
        $sourceManifest.patch_sha256 -ne $patch.patch_sha256 -or
        $sourceManifest.source_lock_sha256 -ne (Get-FileHash (Join-Path $workspace 'third_party\mpv\source-lock.json')).Hash.ToLowerInvariant() -or
        $sourceManifest.private_header_sha256 -ne (Get-FileHash (Join-Path $workspace 'native\mpv\include\mpv\quest_frame.h')).Hash.ToLowerInvariant()) {
        throw 'Source-frame candidate inputs differ from the current locked source/ABI.'
    }
    $sourceDirectory = Join-Path $ToolRoot 'mpv\source-frame\arm64-v8a'
    $expectedNames = @('libmpv.so','libavcodec.so','libavdevice.so','libavfilter.so','libavformat.so','libavutil.so','libswresample.so','libswscale.so')
    if ((@($sourceManifest.packaged_libraries | Sort-Object) -join ',') -ne (@($expectedNames | Sort-Object) -join ',') -or
        @($sourceManifest.libraries).Count -ne 8) { throw 'Unexpected source-frame library set.' }
    foreach ($name in $expectedNames) {
        $records = @($sourceManifest.libraries | Where-Object name -eq $name)
        $path = Join-Path $sourceDirectory $name
        if ($records.Count -ne 1 -or -not (Test-Path -LiteralPath $path) -or
            (Get-Item -LiteralPath $path).Length -ne $records[0].bytes -or
            (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $records[0].sha256) { throw "Source candidate bytes differ: $name" }
    }
    $destination = Join-Path $workspace 'android\player-plugin\src\main\jniLibs\arm64-v8a'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    foreach ($name in $expectedNames) { Copy-Item -LiteralPath (Join-Path $sourceDirectory $name) -Destination (Join-Path $destination $name) -Force }

    $legacyDirectory = Join-Path $workspace 'android\player-plugin\src\debug\jniLibs\arm64-v8a'
    foreach ($record in $sourceManifest.libraries) {
        $legacy = Join-Path $legacyDirectory $record.name
        if (Test-Path -LiteralPath $legacy) {
            if ((Get-FileHash -LiteralPath $legacy).Hash.ToLowerInvariant() -ne $record.sha256) { throw "Unrecognized legacy MPV file: $($record.name)" }
            Remove-Item -LiteralPath $legacy
        }
    }
    Write-Output 'Source-frame ARM64 MPV candidate prepared; eight verified libraries, Debug and Release.'
    return
}
$manifest = Get-Content (Join-Path $workspace 'third_party\mpv\manifest.json') -Raw | ConvertFrom-Json
$directory = Join-Path $ToolRoot 'mpv\2026-09-17'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$apk = Join-Path $directory 'app-default-arm64-v8a-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
    $temporary = $apk + '.download'
    & curl.exe -L --fail --retry 3 --connect-timeout 15 --max-time 180 -o $temporary $manifest.source_url
    if ($LASTEXITCODE -ne 0) { throw 'Official mpv Android dependency download failed.' }
    if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.apk_sha256) { throw 'mpv Android release SHA256 differs from the pinned asset.' }
    Move-Item -LiteralPath $temporary -Destination $apk
}
if ((Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.apk_sha256) { throw 'Cached mpv Android release SHA256 differs.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($apk)
$destination = Join-Path $workspace 'android\player-plugin\src\main\jniLibs\arm64-v8a'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
try {
    foreach ($name in $manifest.packaged_libraries) {
        if ($name -notmatch '^lib[a-z0-9]+\.so$') { throw 'Unexpected mpv dependency name.' }
        $record = @($manifest.libraries | Where-Object { $_.name -eq $name })
        if ($record.Count -ne 1) { throw 'Ambiguous mpv dependency manifest.' }
        $entry = $archive.GetEntry("lib/arm64-v8a/$name")
        if (-not $entry -or $entry.Length -ne $record[0].bytes) { throw "mpv dependency missing: $name" }
        $target = Join-Path $destination $name
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record[0].sha256) { throw "mpv dependency SHA256 differs: $name" }
    }
} finally { $archive.Dispose() }
foreach ($header in $manifest.headers) {
    $path = Join-Path $workspace ('native\mpv\include\mpv\' + $header.file)
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $header.sha256) { throw 'mpv header differs from pinned revision.' }
}

    $legacyDirectory = Join-Path $workspace 'android\player-plugin\src\debug\jniLibs\arm64-v8a'
    foreach ($record in $manifest.libraries) {
        $legacy = Join-Path $legacyDirectory $record.name
        if (Test-Path -LiteralPath $legacy) {
            if ((Get-FileHash -LiteralPath $legacy).Hash.ToLowerInvariant() -ne $record.sha256) { throw "Unrecognized legacy MPV file: $($record.name)" }
            Remove-Item -LiteralPath $legacy
        }
    }
Write-Output 'Pinned mpv Android development candidate prepared; eight libraries, Debug and Release.'
