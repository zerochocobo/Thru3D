param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }),
    [ValidateSet('OfficialRelease','SourceFrame')][string]$Candidate = 'OfficialRelease', [string]$ApkPath = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$apk = if ($ApkPath) { $ApkPath } else { Join-Path $workspace 'artifacts\quest3-player-debug.apk' }
$manifestFile = if ($Candidate -eq 'SourceFrame') { 'source-build.json' } else { 'manifest.json' }
$manifest = Get-Content (Join-Path $workspace ('third_party\mpv\' + $manifestFile)) -Raw | ConvertFrom-Json
$expected = @($manifest.packaged_libraries) + @('libquest_mpv.so')
$destination = Join-Path $workspace 'artifacts\native\mpv'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($apk)
try {
    foreach ($name in $expected) {
        $entry = $zip.GetEntry("lib/arm64-v8a/$name")
        if (-not $entry) { throw "MPV candidate library absent from APK: $name" }
        $target = Join-Path $destination $name
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        $elf = (& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe" -h -l $target | Out-String)
        if ($LASTEXITCODE -ne 0 -or $elf -notmatch 'Machine:\s+AArch64') { throw "MPV ELF ABI failed: $name" }
        $segments = @($elf -split "`n" | Where-Object { $_ -match '^\s*LOAD\s' })
        if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -notmatch '0x4000\s*$' }).Count -gt 0) { throw "MPV ELF 16KB alignment failed: $name" }
        if ($name -ne 'libquest_mpv.so') {
            $record = $manifest.libraries | Where-Object { $_.name -eq $name }
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.sha256) { throw "MPV APK library bytes differ: $name" }
        }
    }
} finally { $zip.Dispose() }
if ($Candidate -eq 'SourceFrame') {
    $frameExports = (& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe" -D (Join-Path $destination 'libmpv.so') | Out-String)
    if ($LASTEXITCODE -ne 0 -or $frameExports -notmatch '(?m)\bT\s+mpv_quest_source_frame_api_version(?:@@?[^\s]+)?\s*$') { throw 'Source-frame handshake export missing from packaged MPV.' }
}
$symbols = (& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe" -D (Join-Path $destination 'libquest_mpv.so') | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'MPV JNI symbol inspection failed.' }
foreach ($symbol in @('Java_org_vrpassthroughplayer_plugin_MpvNative_probe',
    'Java_org_vrpassthroughplayer_plugin_MpvNative_probeGpu')) {
    if ($symbols -notmatch ('(?m)\bT\s+' + [regex]::Escape($symbol) + '\s*$')) { throw "MPV JNI export missing: $symbol" }
}
foreach ($method in @('available','create','acquire','release','setPlaying','setAudio','setSubtitle','subtitleStatus','seek','status','requestFrame','readFrameCode','close','requestClose')) {
    $symbol = 'Java_org_vrpassthroughplayer_plugin_MpvSourceNative_' + $method
    if ($symbols -notmatch ('(?m)\bT\s+' + [regex]::Escape($symbol) + '\s*$')) { throw "MPV source JNI export missing: $symbol" }
}
foreach ($variant in @('debug','release')) {
    $aar = [IO.Compression.ZipFile]::OpenRead((Join-Path $workspace "android\player-plugin\build\outputs\aar\player-plugin-$variant.aar"))
    try {
        foreach ($name in $expected) {
            $present = $null -ne $aar.GetEntry("jni/arm64-v8a/$name")
            if (-not $present) { throw "MPV dependency missing from $variant AAR: $name" }
        }
    } finally { $aar.Dispose() }
}
@{ schema_version = 1; state = 'passed'; candidate = $Candidate; libraries = $expected; debug_only = $false;
    apk_sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant();
    scope = 'Pinned bytes/ARM64/16KB/Debug/Release dependency packaging only; device execution separate' } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $workspace 'artifacts\mpv-build-check.json') -Encoding utf8
Write-Output 'MPV development candidate packaging checks passed.'
