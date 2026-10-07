param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [string]$ApkPath = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$apk = if ($ApkPath) { $ApkPath } else { Join-Path $workspace 'artifacts\quest3-player-debug.apk' }
$nativeDirectory = Join-Path $workspace 'artifacts\native'
$logDirectory = Join-Path $workspace 'artifacts\logs'
New-Item -ItemType Directory -Force -Path $nativeDirectory, $logDirectory | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($apk)
try {
    $entry = $archive.GetEntry('lib/arm64-v8a/libquest_render_bridge.so')
    if (-not $entry) { throw 'APK lacks render bridge native library.' }
    $library = Join-Path $nativeDirectory 'libquest_render_bridge.so'
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $library, $true)
} finally { $archive.Dispose() }
& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe" -h -d -l $library 2>&1 | Out-File (Join-Path $logDirectory 'r02-elf.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Render bridge ELF inspection failed.' }
$elf = Get-Content (Join-Path $logDirectory 'r02-elf.log') -Raw
if ($elf -notmatch 'Machine:\s+AArch64') { throw 'Render bridge must be ARM64.' }
$segments = @($elf -split "`n" | Where-Object { $_ -match '^\s*LOAD\s' })
if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -notmatch '0x4000\s*$' }).Count -gt 0) { throw 'Render bridge ELF alignment differs from 16KB.' }
& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe" -D $library 2>&1 | Out-File (Join-Path $logDirectory 'r02-symbols.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Render bridge symbol inspection failed.' }
$symbols = Get-Content (Join-Path $logDirectory 'r02-symbols.log') -Raw
foreach ($method in @('createLayout','oesTexture','capture','captureTexture','ready','texture','readInputs','retire','retired','close','abandon','uploadAlpha','alphaReady','alphaTexture','readAlpha')) {
    if (-not $symbols.Contains("Java_org_vrpassthroughplayer_plugin_RenderBridgeNative_$method")) { throw "Missing JNI: $method" }
}
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex packages --defined-only $apk 2>&1 | Out-File (Join-Path $logDirectory 'r02-dex-packages.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Render bridge DEX inspection failed.' }
$classes = Get-Content (Join-Path $logDirectory 'r02-dex-packages.log') -Raw
foreach ($name in @('ControlledVideoBridge','DecodedFrameGate','RenderBridgeNative')) {
    if ($classes -notmatch ('(?m)\sorg\.vrpassthroughplayer\.plugin\.' + $name + '\r?$')) { throw "Missing controlled decoder class $name" }
}
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method 'request_controlled_probe(Ljava/lang/String;IZLjava/lang/String;)I' $apk 2>&1 | Out-File (Join-Path $logDirectory 'r02-probe-method.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Controlled probe method inspection failed.' }
$method = Get-Content (Join-Path $logDirectory 'r02-probe-method.log') -Raw
if (-not $method.Contains('.method public final request_controlled_probe(Ljava/lang/String;IZLjava/lang/String;)I') -or -not $method.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;')) { throw 'Controlled probe Godot binding differs.' }
foreach ($variant in @('debug','release')) {
    $aar = [IO.Compression.ZipFile]::OpenRead((Join-Path $workspace "android\player-plugin\build\outputs\aar\player-plugin-$variant.aar"))
    try {
        $reader = [IO.StreamReader]::new($aar.GetEntry('AndroidManifest.xml').Open())
        try { $manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $memory = [IO.MemoryStream]::new()
        $jarStream = $aar.GetEntry('classes.jar').Open()
        try { $jarStream.CopyTo($memory) } finally { $jarStream.Dispose() }
        $memory.Position = 0
        $jar = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
        try {
            $receiverPresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/DebugDiagnosticsReceiver.class')
            $flatDiagnosticPresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/MpvDiagnosticActivity.class')
            $accessProviderPresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/LocalAccessTestProvider.class')
            $accessProbePresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/LocalAccessProbe.class')
            $selectionProbePresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/LocalSelectionProbe.class')
            $rvmProbePresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/RvmStandaloneProbe.class')
            $rvmResidentNativePresent = $null -ne $jar.GetEntry('org/vrpassthroughplayer/plugin/RvmResidentValidationNative.class')
        }
        finally { $jar.Dispose(); $memory.Dispose() }
        if ($variant -eq 'debug') {
            if (-not $receiverPresent -or -not $flatDiagnosticPresent -or -not $accessProviderPresent -or -not $accessProbePresent -or -not $selectionProbePresent -or -not $rvmProbePresent -or -not $rvmResidentNativePresent -or -not $manifest.Contains('DEBUG_RVM_STANDALONE') -or -not $manifest.Contains('android.permission.DUMP')) { throw 'Debug diagnostic declaration missing.' }
        } elseif ($receiverPresent -or $flatDiagnosticPresent -or $accessProviderPresent -or $accessProbePresent -or $selectionProbePresent -or $rvmProbePresent -or $rvmResidentNativePresent -or $manifest.Contains('DEBUG_RVM_STANDALONE') -or $manifest.Contains('LocalAccessTestProvider') -or $manifest.Contains('DEBUG_LOCAL_ACCESS') -or $manifest.Contains('DEBUG_LOCAL_SELECTION') -or $manifest.Contains('DEBUG_MPV_URI') -or $manifest.Contains('DebugDiagnosticsReceiver') -or $manifest.Contains('MpvDiagnosticActivity') -or
            $manifest.Contains('HAND_TRACKING') -or $manifest.Contains('oculus.software.handtracking')) {
            throw 'Development receiver/input declarations leaked into Release AAR.'
        }
        # Hand declarations belong to the selected vendor APK, checked by Build-Player.
        # Neither shared AAR may force Meta permissions into a PICO export.
        if ($manifest.Contains('com.oculus.permission.HAND_TRACKING') -or $manifest.Contains('oculus.software.handtracking')) {
            throw 'Shared player AAR contains vendor-specific hand tracking declarations.'
        }
    } finally { $aar.Dispose() }
}
@{ schema_version = 1; state = 'passed'; scope = 'APK packaging/ELF/DEX; device execution not inferred';
    apk_sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant(); jni_exports = 15;
    debug_only_receiver_input_checks = 'passed' } |
    ConvertTo-Json | Set-Content (Join-Path $workspace 'artifacts\r02-build-check.json') -Encoding utf8
Write-Output 'R02 render bridge packaging checks passed.'
