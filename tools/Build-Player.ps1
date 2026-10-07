param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }),
    [ValidateSet('OfficialRelease','SourceFrame')][string]$MpvCandidate = 'SourceFrame',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*\.apk$')][string]$ApkName = '',
    [ValidateSet('Quest','Pico')][string]$XrVendor = 'Quest',
    [ValidateSet('Debug','Release')][string]$BuildType = 'Debug',
    # Only to deploy while unrelated work-in-progress unit tests do not compile.
    [switch]$SkipUnitTests,
    # Dedicated device diagnostics only; normal Debug APKs contain no test media/oracles.
    [switch]$IncludeDiagnostics,
    # Version-matched assets imported with tools/Import-ModelAssets.ps1.
    [switch]$UsePreparedModelAssets)
$ErrorActionPreference = 'Stop'
if (-not $ApkName) {
    $ApkName = if ($BuildType -eq 'Release') {
        if ($XrVendor -eq 'Pico') { 'Thru3D-PICO4-release.apk' } else { 'Thru3D-Quest3-release.apk' }
    } else {
        if ($XrVendor -eq 'Pico') { 'pico4-player-debug.apk' } else { 'quest3-player-debug.apk' }
    }
}
$exportPreset = if ($XrVendor -eq 'Pico') { 'PICO 4' } else { 'Quest 3' }
$applicationId = 'com.wapok.thru3d'
function Convert-HexString([byte[]]$Bytes) { -join ($Bytes | ForEach-Object { $_.ToString('X2') }) }
$workspace = Split-Path -Parent $PSScriptRoot
# Gradle outputs, Godot's import cache and evidence paths belong to one checkout.
# Concurrent builds can otherwise package another run's plugin or overwrite its tests.
$buildMutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-Build')
$buildLockHeld = $false
$originalExportPresets = $null
$originalSigningEnvironment = @{}
foreach ($key in @('GODOT_ANDROID_KEYSTORE_RELEASE_PATH','GODOT_ANDROID_KEYSTORE_RELEASE_USER','GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD')) {
    $originalSigningEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
$exportPresetsPath = Join-Path $workspace 'app\godot\export_presets.cfg'
try {
    try { $buildLockHeld = $buildMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $buildLockHeld = $true }
    if (-not $buildLockHeld) {
        Write-Output 'Waiting for the active player build to finish...'
        try { $buildLockHeld = $buildMutex.WaitOne() }
        catch [Threading.AbandonedMutexException] { $buildLockHeld = $true }
    }
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
if ($BuildType -eq 'Release') {
    if ($IncludeDiagnostics) { throw 'Distribution Release builds cannot include diagnostic models/media.' }
    & "$PSScriptRoot\environment\Prepare-ReleaseSigning.ps1" -ToolRoot $ToolRoot
}
$projectDirectory = Join-Path $workspace 'app\godot'
$appVersion = [regex]::Match((Get-Content (Join-Path $projectDirectory 'project.godot') -Raw), '(?m)^config/version="([^"]+)"').Groups[1].Value
if ($IncludeDiagnostics) {
    $originalExportPresets = [IO.File]::ReadAllBytes($exportPresetsPath)
    $diagnosticPresets = [Text.Encoding]::UTF8.GetString($originalExportPresets).Replace('exclude_filter="tests/*,media/*"', 'exclude_filter="tests/*"').Replace('include_filter="i18n/*.json,', 'include_filter="media/*.mp4,i18n/*.json,')
    [IO.File]::WriteAllText($exportPresetsPath, $diagnosticPresets, [Text.UTF8Encoding]::new($false))
}
$artifactDirectory = Join-Path $workspace 'artifacts'
$logDirectory = Join-Path $artifactDirectory 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$engineVersion = (& $env:GODOT_EXE --headless --version 2>&1 | Out-String).Trim()
if ($engineVersion -ne '4.7.2.stable.official.ed1daf0bf') { throw "Godot differs from the locked version: $engineVersion" }
if ($UsePreparedModelAssets) {
    if ($IncludeDiagnostics) { throw 'Prepared runtime assets do not include full diagnostics.' }
    & "$workspace/tools/Import-ModelAssets.ps1" -VerifyOnly
} else {
    & "$workspace\tools\models\Prepare-RvmCandidate.ps1" -ToolRoot $ToolRoot
}
& "$workspace\tools\environment\Prepare-MpvAndroid.ps1" -ToolRoot $ToolRoot -Candidate $MpvCandidate

# Extract the Java API from the matching official template, not a second engine dependency.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$apiDirectory = Join-Path $ToolRoot 'godot-android-api\4.7.2'
$godotApi = Join-Path $apiDirectory 'godot-lib.template_debug.aar'
if (-not (Test-Path -LiteralPath $godotApi)) {
    New-Item -ItemType Directory -Path $apiDirectory -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $ToolRoot 'godot-templates\4.7.2.stable\android_source.zip'))
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq 'libs/debug/godot-lib.template_debug.aar' } | Select-Object -First 1
        if (-not $entry) { throw 'Godot Android Java API was not found in the template.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $godotApi, $false)
    } finally { $archive.Dispose() }
}
# A cold Gradle daemon prints an SDK XML warning on stderr; only the exit code decides.
$ErrorActionPreference = 'Continue'
& "$workspace\android\gradlew.bat" -p "$workspace\android" "-PgodotAarPath=$godotApi" "-PincludeDiagnostics=$($IncludeDiagnostics.IsPresent.ToString().ToLowerInvariant())" :player-plugin:assembleDebug :player-plugin:assembleRelease $(if ($SkipUnitTests) { @() } else { @(':player-plugin:testDebugUnitTest') }) --console=plain 2>&1 | Out-File (Join-Path $logDirectory 'plugin-build.log') -Encoding utf8
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw 'Android plugin build failed; inspect artifacts/logs/plugin-build.log.' }
$pluginDirectory = Join-Path $projectDirectory 'addons\quest_player\bin'
New-Item -ItemType Directory -Path $pluginDirectory -Force | Out-Null
foreach ($variant in @('debug','release')) {
    Copy-Item -LiteralPath "$workspace\android\player-plugin\build\outputs\aar\player-plugin-$variant.aar" -Destination $pluginDirectory -Force
}
$vendorsDirectory = Join-Path $projectDirectory 'addons\godotopenxrvendors'
if (-not (Test-Path -LiteralPath $vendorsDirectory)) {
    Copy-Item -LiteralPath (Join-Path $ToolRoot 'openxr-vendors\5.1.0\asset\addons\godotopenxrvendors') -Destination (Split-Path $vendorsDirectory) -Recurse
}

# With this fixed Godot/Vendors pair, immediate --import exit crashes on a fresh
# extension scan. Let the editor finish its background metadata work before exit.
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --editor --quit-after 600 2>&1 | Out-File (Join-Path $logDirectory 'godot-import.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Godot import failed; inspect artifacts/logs/godot-import.log.' }
if ((Get-Content (Join-Path $logDirectory 'godot-import.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Godot import reported errors.' }
$apkPath = Join-Path $artifactDirectory $ApkName
$exportArguments = @('--headless','--xr-mode','off','--path',$projectDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $projectDirectory 'android\build\build.gradle'))) { $exportArguments += '--install-android-build-template' }
$exportArguments += @($(if ($BuildType -eq 'Release') { '--export-release' } else { '--export-debug' }),$exportPreset,$apkPath)
& $env:GODOT_EXE @exportArguments 2>&1 | Out-File (Join-Path $logDirectory 'godot-export.log') -Encoding utf8
$exportExitCode = $LASTEXITCODE
if ($BuildType -eq 'Release' -and $env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD) {
    $exportLogPath = Join-Path $logDirectory 'godot-export.log'
    $redactedExportLog = [IO.File]::ReadAllText($exportLogPath).Replace($env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD, '<redacted>')
    [IO.File]::WriteAllText($exportLogPath, $redactedExportLog, [Text.UTF8Encoding]::new($false))
}
if ($exportExitCode -ne 0) { throw 'APK export failed; inspect artifacts/logs/godot-export.log.' }
if ((Get-Content (Join-Path $logDirectory 'godot-export.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Godot export reported errors.' }
& "$env:ANDROID_HOME\build-tools\36.1.0\apksigner.bat" verify --verbose $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'apk-signature.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK signature validation failed.' }
& "$env:ANDROID_HOME\build-tools\36.1.0\apksigner.bat" verify --print-certs $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'apk-signer-certificate.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK signer certificate inspection failed.' }
& "$env:ANDROID_HOME\build-tools\36.1.0\zipalign.exe" -c -P 16 -v 4 $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'apk-alignment.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK alignment validation failed.' }
& "$env:ANDROID_HOME\build-tools\36.1.0\aapt2.exe" dump xmltree $apkPath --file AndroidManifest.xml 2>&1 | Out-File (Join-Path $logDirectory 'apk-manifest.txt') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK manifest inspection failed.' }
$manifestText = Get-Content (Join-Path $logDirectory 'apk-manifest.txt') -Raw
if ($BuildType -eq 'Release' -and ($manifestText -match 'android:debuggable[^\r\n]*=true' -or $manifestText -match 'DebugDiagnosticsReceiver|MpvDiagnosticActivity|LocalAccessTestProvider|DEBUG_RVM_STANDALONE')) {
    throw 'Distribution APK contains debugging or diagnostic entry points.'
}
$manifestLines = $manifestText -split "`n"
$headFeature = @($manifestLines | Select-String 'android\.hardware\.vr\.headtracking')
if ($headFeature.Count -ne 1) { throw 'Expected exactly one headtracking feature.' }
$headFeatureIndex = $headFeature[0].LineNumber - 1
$headFeatureBlock = $manifestLines[$headFeatureIndex..($headFeatureIndex + 3)] -join "`n"
if ($headFeatureBlock -notmatch 'android:required[^\r\n]*=true') { throw 'Immersive Quest APK must require 6DoF headtracking hardware.' }
$vendorManifest = if ($XrVendor -eq 'Pico') { @('handtracking', 'Hand_Tracking_HighFrequency', 'pvr.app.type', 'pxr.sdk.version_code') } else { @('com.oculus.feature.PASSTHROUGH', 'com.oculus.permission.HAND_TRACKING', 'oculus.software.handtracking') }
foreach ($expected in (@('org.vrpassthroughplayer.plugin.QuestPlayerPlugin','org.khronos.openxr.intent.category.IMMERSIVE_HMD', $applicationId) + $vendorManifest)) {
    if (-not $manifestText.Contains($expected)) { throw "APK manifest is missing: $expected" }
}
if ($XrVendor -eq 'Pico' -and $manifestText.Contains('com.oculus.permission.HAND_TRACKING')) { throw 'PICO APK contains Meta hand tracking configuration.' }
if ($XrVendor -eq 'Quest' -and $manifestText.Contains('pvr.app.type')) { throw 'Quest APK contains PICO VR configuration.' }
$apkArchive = [IO.Compression.ZipFile]::OpenRead($apkPath)
try {
    $abis = @($apkArchive.Entries | Where-Object { $_.FullName -match '^lib/([^/]+)/.+\.so$' } | ForEach-Object { $_.FullName.Split('/')[1] } | Sort-Object -Unique)
    if ($abis.Count -ne 1 -or $abis[0] -ne 'arm64-v8a') { throw 'APK has unexpected native architectures.' }
    if (@($apkArchive.Entries | Where-Object { $_.FullName -match '^lib/.*/libgodot_android\.so$' }).Count -ne 1) { throw 'APK must contain exactly one Godot engine library.' }
    if ($apkArchive.GetEntry('lib/arm64-v8a/libgojni.so') -or ($apkArchive.Entries | Where-Object { $_.FullName -match '(^|/)(openlist|cloudcore)(/|\.)' })) { throw 'APK still contains the retired OpenList core.' }
    if (-not $apkArchive.GetEntry('assets/p115rsacipher/LICENSE')) { throw 'APK is missing the MIT 115 cipher license.' }
    foreach ($notice in @('assets/backgrounds/CC0-1.0.txt', 'assets/backgrounds/NOTICE.txt')) {
        if (-not $apkArchive.GetEntry($notice)) { throw "APK is missing panorama attribution/license: $notice" }
    }
    $panoramaImport = Get-Content (Join-Path $projectDirectory 'backgrounds\belfast_sunset_puresky.jpg.import') -Raw
    if ($panoramaImport -notmatch 'compress/mode=2' -or $panoramaImport -notmatch 'mipmaps/generate=true' -or $panoramaImport -notmatch 'process/size_limit=0') {
        throw 'Built-in panorama must keep full dimensions, mipmaps and GPU compression.'
    }
    $panoramaMatch = [regex]::Match($panoramaImport, '(?m)^path.astc="res://([^"]+)"')
    if (-not $panoramaMatch.Success -or -not $apkArchive.GetEntry('assets/' + $panoramaMatch.Groups[1].Value)) {
        throw 'APK is missing the full-resolution ASTC panorama texture.'
    }
    if (-not ($apkArchive.Entries | Where-Object { $_.FullName -like '*openxr_action_map*' })) { throw 'APK is missing the fixed controller action map.' }
    $fixtureHash = $null
    $maskImportedHash = $null
    if ($IncludeDiagnostics) {
        $fixtureEntry = $apkArchive.GetEntry('assets/media/c03_sbs_grid.mp4')
        if (-not $fixtureEntry) { throw 'APK is missing the C03 calibration video.' }
        $fixtureManifest = Get-Content (Join-Path $workspace 'tests\fixtures\c03_sbs_grid.json') -Raw | ConvertFrom-Json
        $fixtureStream = $fixtureEntry.Open()
        $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
        try { $fixtureHash = (Convert-HexString ($hashAlgorithm.ComputeHash($fixtureStream))).ToLowerInvariant() }
        finally { $fixtureStream.Dispose(); $hashAlgorithm.Dispose() }
        if ($fixtureHash -ne $fixtureManifest.sha256 -or $fixtureEntry.Length -ne $fixtureManifest.bytes) { throw 'Packaged C03 video does not match its fixture manifest.' }
        if ($MpvCandidate -eq 'SourceFrame') {
            $audioFixture = Get-Content (Join-Path $workspace 'tests\fixtures\mp06_audio_clock.json') -Raw | ConvertFrom-Json
            $audioEntry = $apkArchive.GetEntry('assets/media/mp06_audio_clock.mp4')
            if (-not $audioEntry -or $audioEntry.Length -ne $audioFixture.bytes) { throw 'Missing/wrong-size audio clock fixture.' }
            $audioStream = $audioEntry.Open()
            $audioSha = [Security.Cryptography.SHA256]::Create()
            try { $audioHash = (Convert-HexString ($audioSha.ComputeHash($audioStream))).ToLowerInvariant() }
            finally { $audioStream.Dispose(); $audioSha.Dispose() }
            if ($audioHash -ne $audioFixture.sha256) { throw 'Audio clock fixture bytes differ inside APK.' }
            $identityFixture = Get-Content (Join-Path $workspace 'tests\fixtures\mp03_frame_identity.json') -Raw | ConvertFrom-Json
            $identityEntry = $apkArchive.GetEntry('assets/media/mp03_frame_identity.mp4')
            if (-not $identityEntry -or $identityEntry.Length -ne $identityFixture.bytes) { throw 'Missing source-frame identity fixture.' }
            $identityStream = $identityEntry.Open()
            $identitySha = [Security.Cryptography.SHA256]::Create()
            try { $identityHash = (Convert-HexString ($identitySha.ComputeHash($identityStream))).ToLowerInvariant() }
            finally { $identityStream.Dispose(); $identitySha.Dispose() }
            if ($identityHash -ne $identityFixture.sha256) { throw 'Source-frame fixture bytes differ inside APK.' }
        }
        $alphaFixtures = Get-Content (Join-Path $workspace 'tests\fixtures\c04_alpha.json') -Raw | ConvertFrom-Json
        foreach ($asset in @($alphaFixtures.assets | Where-Object { $_.file.EndsWith('.mp4') })) {
            $entry = $apkArchive.GetEntry('assets/' + $asset.file.Replace('app/godot/', ''))
            if (-not $entry -or $entry.Length -ne $asset.bytes) { throw "Missing/wrong size C04 media: $($asset.file)" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = (Convert-HexString ($sha.ComputeHash($stream))).ToLowerInvariant() }
            finally { $stream.Dispose(); $sha.Dispose() }
            if ($hash -ne $asset.sha256) { throw "Wrong hash C04 media: $($asset.file)" }
        }
        # PNG resources are remapped to imported textures; verify the actual imported
        # numeric mask bytes as well as its remap, not just its original source filename.
        $maskSource = Join-Path $projectDirectory 'media\c04_independent_mask.png'
        $maskAsset = $alphaFixtures.assets | Where-Object { $_.file -eq 'app/godot/media/c04_independent_mask.png' } | Select-Object -First 1
        if (-not $maskAsset -or (Get-FileHash -LiteralPath $maskSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne $maskAsset.sha256) { throw 'C04 source mask hash changed.' }
        $maskImport = Get-Content ($maskSource + '.import') -Raw
        if ($maskImport -notmatch 'compress/mode=0' -or $maskImport -notmatch 'mipmaps/generate=false' -or $maskImport -notmatch 'process/premult_alpha=false') { throw 'Numeric C04 mask import must be lossless with no mipmaps/premultiply.' }
        $maskMatch = [regex]::Match($maskImport, '(?m)^path="res://([^"]+)"')
        if (-not $maskMatch.Success) { throw 'C04 mask import path missing.' }
        $maskImportedRelative = $maskMatch.Groups[1].Value
        $maskImported = Join-Path $projectDirectory $maskImportedRelative
        $maskTextureEntry = $apkArchive.GetEntry('assets/' + $maskImportedRelative)
        $maskRemapEntry = $apkArchive.GetEntry('assets/media/c04_independent_mask.png.import')
        if (-not $maskTextureEntry -or -not $maskRemapEntry) { throw 'APK lacks imported C04 numeric mask or remap.' }
        $remapReader = [IO.StreamReader]::new($maskRemapEntry.Open())
        try { $packagedRemap = $remapReader.ReadToEnd() }
        finally { $remapReader.Dispose() }
        if (-not $packagedRemap.Contains('path="res://' + $maskImportedRelative + '"')) { throw 'APK numeric mask remap points to the wrong texture.' }
        $stream = $maskTextureEntry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $maskImportedHash = (Convert-HexString ($sha.ComputeHash($stream))).ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($maskImportedHash -ne (Get-FileHash -LiteralPath $maskImported -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'APK imported C04 mask bytes changed.' }
    } else {
        if ($apkArchive.Entries | Where-Object { $_.FullName -like 'assets/media/*' -or $_.FullName -like 'assets/rvm/reference/*' -or $_.FullName -match '(?i)c04_.*\.(ctex|import)$' }) {
            throw 'Normal player APK contains diagnostic media or numerical oracles.'
        }
    }
    $rvmBundlePath = Join-Path $workspace 'android\player-plugin\src\main\assets\rvm\bundle_manifest.json'
    $rvmBundle = Get-Content $rvmBundlePath -Raw | ConvertFrom-Json
    $packagedRvmAssets = @($rvmBundle.assets | Where-Object { $IncludeDiagnostics -or $_.path -eq 'rvm/RVM_GPL-3.0.txt' })
    foreach ($asset in $packagedRvmAssets) {
        $entry = $apkArchive.GetEntry('assets/' + $asset.path)
        if (-not $entry -or $entry.Length -ne $asset.bytes) { throw "Missing or wrong size RVM asset: $($asset.path)" }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = (Convert-HexString ($sha.ComputeHash($stream))).ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($hash -ne $asset.sha256) { throw "Wrong hash for packaged RVM asset: $($asset.path)" }
    }
    if (-not $IncludeDiagnostics -and ($apkArchive.Entries | Where-Object { $_.FullName -match '^assets/rvm/.*\.(bin|param)$' -or $_.FullName -eq 'assets/rvm-mnn/rvm_quality.mnn' })) {
        throw 'Normal player APK contains unused diagnostic/quality models.'
    }
    $mnnManifest = Get-Content (Join-Path $projectDirectory '..\..\android\player-plugin\src\main\assets\rvm-mnn\manifest.json') -Raw | ConvertFrom-Json
    $depthManifest = Get-Content (Join-Path $projectDirectory '..\..\android\player-plugin\src\main\assets\depth-mnn\manifest.json') -Raw | ConvertFrom-Json
    $requiredModels = @(@('rvm-mnn/rvm.mnn', $mnnManifest.mnn_sha256), @('depth-mnn/depth.mnn', $depthManifest.mnn_sha256))
    if ($IncludeDiagnostics) { $requiredModels += ,@('rvm-mnn/rvm_quality.mnn', $mnnManifest.quality_mnn_sha256) }
    foreach ($model in $requiredModels) {
        $entry = $apkArchive.GetEntry('assets/' + $model[0])
        if (-not $entry) { throw "APK is missing playback model $($model[0])" }
        $modelStream = $entry.Open()
        $modelSha = [Security.Cryptography.SHA256]::Create()
        try { $modelHash = (Convert-HexString ($modelSha.ComputeHash($modelStream))).ToLowerInvariant() }
        finally { $modelStream.Dispose(); $modelSha.Dispose() }
        if ($modelHash -ne $model[1]) { throw "APK playback model hash differs: $($model[0])" }
    }
    $nativeEntry = $apkArchive.GetEntry('lib/arm64-v8a/libquest_rvm.so')
    if (-not $nativeEntry) { throw 'APK is missing the RVM JNI library.' }
    $nativeEvidenceDirectory = Join-Path $artifactDirectory 'native'
    New-Item -ItemType Directory -Path $nativeEvidenceDirectory -Force | Out-Null
    $rvmLibrary = Join-Path $nativeEvidenceDirectory 'libquest_rvm.so'
    [IO.Compression.ZipFileExtensions]::ExtractToFile($nativeEntry, $rvmLibrary, $true)
} finally { $apkArchive.Dispose() }
& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe" -h -d -l $rvmLibrary 2>&1 | Out-File (Join-Path $logDirectory 'rvm-elf.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'RVM ELF inspection failed.' }
$elfText = Get-Content (Join-Path $logDirectory 'rvm-elf.log') -Raw
if ($elfText -notmatch 'Machine:\s+AArch64') { throw 'RVM JNI is not AArch64.' }
$loadSegments = @($elfText -split "`n" | Where-Object { $_ -match '^\s*LOAD\s' })
if ($loadSegments.Count -eq 0 -or @($loadSegments | Where-Object { $_ -notmatch '0x4000\s*$' }).Count -gt 0) { throw 'RVM ELF LOAD segment is not 16 KB aligned.' }
& "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe" -D $rvmLibrary 2>&1 | Out-File (Join-Path $logDirectory 'rvm-symbols.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'RVM JNI symbol inspection failed.' }
$symbols = Get-Content (Join-Path $logDirectory 'rvm-symbols.log') -Raw
foreach ($symbol in @('Java_org_vrpassthroughplayer_plugin_RvmNative_runBenchmark','Java_org_vrpassthroughplayer_plugin_RvmNative_setGeneration',
    'Java_org_vrpassthroughplayer_plugin_RvmNative_runtimeCapabilities','Java_org_vrpassthroughplayer_plugin_RvmNative_prepareRuntime',
    'Java_org_vrpassthroughplayer_plugin_RvmNative_processRuntime','Java_org_vrpassthroughplayer_plugin_RvmNative_resetRuntime',
    'Java_org_vrpassthroughplayer_plugin_RvmNative_closeRuntime')) {
    if (-not $symbols.Contains($symbol)) { throw "Missing RVM JNI symbol: $symbol" }
}
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex packages --defined-only $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'apk-dex-packages.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK DEX inspection failed.' }
$dexReport = Get-Content (Join-Path $logDirectory 'apk-dex-packages.log') -Raw
foreach ($expectedClass in @('androidx.media3.exoplayer.ExoPlayer','org.vrpassthroughplayer.plugin.LocalVideoBridge','org.vrpassthroughplayer.plugin.LocalVideoPicker','org.vrpassthroughplayer.plugin.MediaSessionGate','org.vrpassthroughplayer.plugin.RvmNative','org.vrpassthroughplayer.plugin.RvmBenchmarkRunner','org.vrpassthroughplayer.plugin.RvmRuntime','org.vrpassthroughplayer.plugin.RvmProfiles','org.vrpassthroughplayer.plugin.FramePairGate','org.vrpassthroughplayer.plugin.RvmVideoProbe')) {
    if ($dexReport -notmatch ('(?m)\s' + [regex]::Escape($expectedClass) + '\r?$')) { throw "APK is missing required media class: $expectedClass" }
}
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method 'restart_video_at(III)I' $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'c05-plugin-method.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK seek method inspection failed.' }
$seekMethod = Get-Content (Join-Path $logDirectory 'c05-plugin-method.log') -Raw
if (-not $seekMethod.Contains('.method public final restart_video_at(III)I') -or -not $seekMethod.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;') -or -not $seekMethod.Contains('LocalVideoBridge;->restart(III)I')) { throw 'APK seek method/signature/runtime Godot binding differs from the contract.' }
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method 'request_rvm_profile_benchmark(ZLjava/lang/String;)I' $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'r01-plugin-method.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK profile benchmark method inspection failed.' }
$profileMethod = Get-Content (Join-Path $logDirectory 'r01-plugin-method.log') -Raw
if (-not $profileMethod.Contains('.method public final request_rvm_profile_benchmark(ZLjava/lang/String;)I') -or -not $profileMethod.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;')) { throw 'APK profile method/Godot annotation differs.' }
& "$workspace\tools\Verify-RenderBridge.ps1" -ToolRoot $ToolRoot -ApkPath $apkPath
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method 'set_mpv_audio(IIDZ)Z' $apkPath 2>&1 | Out-File (Join-Path $logDirectory 'mpv-audio-plugin-method.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK MPV audio method inspection failed.' }
$audioMethod = Get-Content (Join-Path $logDirectory 'mpv-audio-plugin-method.log') -Raw
if (-not $audioMethod.Contains('.method public final set_mpv_audio(IIDZ)Z') -or -not $audioMethod.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;') -or -not $audioMethod.Contains('MpvVideoBridge;->setAudio(IIDZ)Z')) { throw 'APK MPV audio method/Godot annotation differs.' }
& "$workspace\tools\Verify-MpvCandidate.ps1" -ToolRoot $ToolRoot -Candidate $MpvCandidate -ApkPath $apkPath
foreach ($binding in @(@('set_mpv_subtitle(II)Z', 'setSubtitle(II)Z'), @('get_mpv_subtitles(IJ)Ljava/lang/String;', 'subtitles(IJ)Ljava/lang/String;'))) {
    $methodName = $binding[0].Split('(')[0]
    $methodLog = Join-Path $logDirectory ($methodName + '-dex.log')
    & "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method $binding[0] $apkPath 2>&1 | Out-File $methodLog -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "APK subtitle method inspection failed: $methodName" }
    $methodText = Get-Content $methodLog -Raw
    if (-not $methodText.Contains('.method public final ' + $binding[0]) -or -not $methodText.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;') -or -not $methodText.Contains('MpvVideoBridge;->' + $binding[1])) { throw "APK subtitle binding differs: $methodName" }
}
foreach ($binding in @(@('request_local_video_access(Ljava/lang/String;)I', 'request(ILjava/lang/String;)Z'), @('cancel_local_video_access(I)V', 'cancel(I)V'))) {
    $name = $binding[0].Split('(')[0]
    $path = Join-Path $logDirectory ($name + '-dex.log')
    & "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method $binding[0] $apkPath 2>&1 | Out-File $path -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "APK local access method inspection failed: $name" }
    $method = Get-Content $path -Raw
    if (-not $method.Contains('.method public final ' + $binding[0]) -or -not $method.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;') -or -not $method.Contains('LocalVideoAccess;->' + $binding[1])) { throw "APK local access binding differs: $name" }
}
$pickerCancelPath = Join-Path $logDirectory 'cancel_local_video_pick-dex.log'
& "$env:ANDROID_HOME\cmdline-tools\latest\bin\apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.QuestPlayerPlugin --method 'cancel_local_video_pick(I)V' $apkPath 2>&1 | Out-File $pickerCancelPath -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'APK picker cancellation method missing.' }
$pickerCancelMethod = Get-Content $pickerCancelPath -Raw
if (-not $pickerCancelMethod.Contains('.method public final cancel_local_video_pick(I)V') -or -not $pickerCancelMethod.Contains('.annotation runtime Lorg/godotengine/godot/plugin/UsedByGodot;') -or -not $pickerCancelMethod.Contains('runOnHostThread')) { throw 'APK picker cancellation Godot/UI binding differs.' }
$buildManifest = [ordered]@{
    schema_version = 1
    built_utc = [DateTime]::UtcNow.ToString('o')
    application_id = $applicationId
    xr_vendor = $XrVendor
    hand_tracking = 'OpenXR joints; pinch ray input; physical validation pending'
    app_version = $appVersion
    build_type = $BuildType
    stage = 'MP04_MPV_shared_RVM_player_integration_development'
    engine = $engineVersion
    vendors = '5.1.0-stable'
    apk = $apkPath
    apk_sha256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    api_aar_sha256 = (Get-FileHash -LiteralPath $godotApi -Algorithm SHA256).Hash.ToLowerInvariant()
    abis = $abis
    build_signature_alignment_checks = 'passed'
    device_execution = 'not_verified'
    passthrough_display = 'not_verified'
    video_implemented = $true
    video_device_validation = 'not_verified'
    media_backend = 'Android libmpv private SourceFrame source; Godot player UI wired; device display/audio validation pending'
    diagnostic_assets_included = $IncludeDiagnostics.IsPresent
    playback_models = @($requiredModels | ForEach-Object { $_[0] })
    automatic_rvm_profile = '320x320'
    calibration_fixture_sha256 = $fixtureHash
    media_dex_inspection = 'passed'
    subtitle_implemented = $true
    subtitle_scope = 'Embedded text subtitles as independent Godot Label3D; MPV playback clock; bitmap/full ASS styling pending'
    subtitle_dex_inspection = 'passed'
    subtitle_device_validation = 'not_verified'
    file_mode_memory_implemented = $true
    file_mode_memory_schema_version = 1
    file_mode_memory_storage = 'Two checksummed generations; validated newest bank, previous bank retained during replacement'
    file_mode_memory_device_validation = 'not_verified'
    recent_files_implemented = $true
    recent_files_limit = 32
    resume_position_source = 'Current bound verified MPV source PTS; confirmed session/generation; periodic and pause/close checkpoints'
    local_uri_preflight_implemented = $true
    local_uri_preflight_dex_checks = 'passed'
    local_uri_preflight_device_validation = 'not_verified'
    recent_files_android_storage_validation = 'not_verified'
    recent_menu_implemented = $true
    recent_menu_selection = 'Left/right OpenXR aim pose ray hover; corresponding trigger press recomputes hit; pointer paging and close; no thumbstick menu navigation'
    recent_menu_pointer_host_validation = 'not_verified'
    player_menu_implemented = $true
    player_menu_sections = @('Playback', 'Picture', 'Sound', 'Info')
    player_menu_selection = 'Shared OpenXR aim ray geometry; corresponding trigger; no thumbstick selection'
    player_menu_host_validation = 'not_verified'
    player_menu_physical_quest_validation = 'not_verified'
    recent_menu_xr_device_validation = 'not_verified'
    local_picker_provider_work_on_background_worker = $true
    local_picker_selection_timeout_ms = 10000
    local_picker_cancel_dex_check = 'passed'
    local_picker_slow_provider_device_validation = 'not_verified'
    eye_order_control_implemented = $true
    playback_seek_implemented = $true
    playback_seek_backend = 'MPV absolute+exact seek; retained native source and new RVM/display processing generation'
    playback_seek_device_validation = 'not_verified'
    playback_seek_dex_method_annotation = 'passed'
    playback_clock = 'MPV audio/video clock; Godot time-pos observation is not a source-frame timestamp; device sync pending'
    source_pts_verified = $false
    alpha_display_implemented = $true
    alpha_device_validation = 'not_verified'
    alpha_fixture_media_checks = if ($IncludeDiagnostics) { 'passed' } else { 'not_packaged' }
    alpha_mask_imported_sha256 = $maskImportedHash
    video_geometries = @('flat', 'half_equirect_180', 'fisheye_180')
    rvm_benchmark_implemented = $IncludeDiagnostics.IsPresent
    rvm_model_bundled = $true
    rvm_model_param_sha256 = if ($IncludeDiagnostics) { $rvmBundle.param_sha256 } else { $null }
    rvm_model_bin_sha256 = if ($IncludeDiagnostics) { $rvmBundle.bin_sha256 } else { $null }
    rvm_assets = $packagedRvmAssets.Count
    rvm_profiles = @($rvmBundle.profiles | Where-Object { $IncludeDiagnostics -or $_.key -eq '320x320' } | ForEach-Object { $_.key })
    rvm_profile_param_sha256 = @($rvmBundle.profiles | Where-Object { $IncludeDiagnostics } | ForEach-Object { @{ profile = $_.key; sha256 = $_.param_sha256 } })
    rvm_runtime_bridge_implemented = $true
    rvm_runtime_bridge_device_execution = 'not_verified'
    rvm_jni_elf_symbols_checks = 'passed'
    rvm_device_execution = 'not_verified'
    rvm_implemented = $false
    controlled_decode_implemented = $true
    video_rvm_probe_implemented = $true
    video_rvm_probe_device_execution = 'not_verified_for_this_build'
    video_rvm_alpha_gpu_upload = $true
    video_rvm_alpha_gpu_device_execution = 'not_verified_for_this_build'
    video_rvm_pair_presented = $false
    playback_target_backend = 'libmpv_android; migration in progress'
    mpv_debug_candidate = $MpvCandidate
    mpv_core_revision = '0b7ed670f7c353dd3dd4f8ae0fc788a181a15aa6'
    mpv_source_frame_extension = ($MpvCandidate -eq 'SourceFrame')
    mpv_core_device_execution = 'not_verified_for_this_build'
    mpv_gpu_device_execution = 'not_verified_for_this_build'
    mpv_gpu_rvm_integrated = $false
    mpv_gpu_rvm_integration_code_present = $true
    mpv_godot_display_device_verified = $false
    mpv_audio_device_verified = $false
    controlled_decode_device_execution = 'not_verified_for_this_build'
    controlled_decode_audio = 'Historical video-only probe; production main playback uses MPV'
    controlled_color_slots = 3
    controlled_frame_source = 'MediaCodec output BufferInfo PTS + one released Surface buffer + exact timestamp comparison'
    render_bridge_jni_elf_dex_checks = 'passed'
}
$buildManifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifactDirectory 'build_manifest.json') -Encoding utf8
$buildManifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifactDirectory ($ApkName.Replace('.apk', '.build.json'))) -Encoding utf8
Write-Output "Built: $apkPath"
Write-Output "SHA256: $($buildManifest.apk_sha256)"
} finally {
    foreach ($key in $originalSigningEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $originalSigningEnvironment[$key], 'Process')
    }
    if ($null -ne $originalExportPresets) { [IO.File]::WriteAllBytes($exportPresetsPath, $originalExportPresets) }
    if ($buildLockHeld) { $buildMutex.ReleaseMutex() }
    $buildMutex.Dispose()
}

