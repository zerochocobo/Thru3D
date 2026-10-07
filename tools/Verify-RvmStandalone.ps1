$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$directory=Join-Path $workspace 'artifacts/rvm-standalone-build-check'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$symbol='Java_org_vrpassthroughplayer_plugin_RvmResidentValidationNative_run'
# Read generated compilation rules, rather than inferring optimization from CMake.
$compileRules=Get-ChildItem "$workspace/android/player-plugin/.cxx/Debug/*/arm64-v8a/build.ninja"
if ($compileRules.Count -ne 1) { throw 'Ambiguous or absent Debug native compilation rules' }
$rules=Get-Content $compileRules[0].FullName -Raw
$flags=[regex]::Matches($rules,'(?m)^build CMakeFiles/quest_rvm\.dir/[^\r\n]+\.cpp\.o:[\s\S]*?^  FLAGS = ([^\r\n]+)')
if ($flags.Count -ne 8) { throw 'Expected all eight RVM native compilation units' }
foreach ($rule in $flags) {
    $arguments=$rule.Groups[1].Value -split '\s+'
    $optimization=@($arguments | Where-Object { $_ -match '^-O([0-3szg]|fast)$' })
    $finiteMath=@($arguments | Where-Object { $_ -in @('-ffast-math','-fno-fast-math') })
    if ($optimization.Count -eq 0 -or $optimization[-1] -ne '-O2' -or $finiteMath.Count -eq 0 -or $finiteMath[-1] -ne '-fno-fast-math' -or
        $arguments -contains '-ffinite-math-only' -or $arguments -contains '-funsafe-math-optimizations') { throw 'Debug RVM wrapper must use O2 and preserve nonfinite rejection' }
}
Copy-Item -LiteralPath $compileRules[0].FullName -Destination "$directory/debug-build.ninja" -Force
foreach ($variant in @('debug','release')) {
    $archive=[IO.Compression.ZipFile]::OpenRead("$workspace/android/player-plugin/build/outputs/aar/player-plugin-$variant.aar")
    try {
        $entry=$archive.GetEntry('jni/arm64-v8a/libquest_rvm.so')
        if (-not $entry) { throw 'RVM AAR library missing' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,"$directory/$variant.so",$true)
    } finally { $archive.Dispose() }
    & "$env:ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-nm.exe" -D "$directory/$variant.so" | Set-Content "$directory/$variant-symbols.txt"
    if ($LASTEXITCODE -ne 0) { throw 'RVM symbols unavailable' }
    $present=(Get-Content "$directory/$variant-symbols.txt" -Raw).Contains($symbol)
    if ($present -ne ($variant -eq 'debug')) { throw 'Resident validation native entry leaked into Release or is missing from Debug' }
    $halfPresent=(Get-Content "$directory/$variant-symbols.txt" -Raw).Contains($symbol+'HalfStorage')
    if ($halfPresent -ne ($variant -eq 'debug')) { throw 'FP16 diagnostic native entry leaked into Release or is absent' }
}
$apk="$workspace/artifacts/quest3-player-debug.apk"
& "$env:ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.RvmResidentValidationNative --method 'run(Landroid/content/res/AssetManager;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;' $apk | Set-Content "$directory/native-binding.txt"
if ($LASTEXITCODE -ne 0) { throw 'Resident APK JNI class/method differs' }
& "$env:ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer.bat" dex code --class org.vrpassthroughplayer.plugin.RvmResidentValidationNative --method 'runHalfStorage(Landroid/content/res/AssetManager;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;' $apk | Set-Content "$directory/half-native-binding.txt"
if ($LASTEXITCODE -ne 0) { throw 'FP16 diagnostic APK JNI binding absent' }
foreach ($workerClass in @('RvmWorkers','RvmBenchmarkRunner','MpvVideoBridge','ControlledVideoBridge')) {
    & "$env:ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer.bat" dex code --class "org.vrpassthroughplayer.plugin.$workerClass" $apk | Set-Content "$directory/$workerClass-dex.txt"
    if ($LASTEXITCODE -ne 0) { throw "Missing process worker class: $workerClass" }
}
$runnerDex=Get-Content "$directory/RvmBenchmarkRunner-dex.txt" -Raw
if (-not $runnerDex.Contains('RvmWorkers;->getValidation') -or $runnerDex.Contains('shutdownNow')) { throw 'Benchmark runner does not preserve its process OpenMP worker' }
$mpvDex=Get-Content "$directory/MpvVideoBridge-dex.txt" -Raw
if (-not $mpvDex.Contains('RvmWorkers;->getVideo') -or $mpvDex.Contains('quitSafely')) { throw 'MPV bridge does not preserve its process OpenMP worker' }
$controlledDex=Get-Content "$directory/ControlledVideoBridge-dex.txt" -Raw
if (-not $controlledDex.Contains('RvmWorkers;->getVideo')) { throw 'Controlled bridge does not use the same process model worker' }
@{state='passed';apk_sha256=(Get-FileHash $apk -Algorithm SHA256).Hash.ToLowerInvariant();
    debug_native_entry=$true;release_native_entry=$false;process_owned_rvm_workers_packaged=$true;
    debug_rvm_native_optimization='O2';debug_rvm_fast_math=$false;
    debug_build_ninja_sha256=(Get-FileHash "$directory/debug-build.ninja" -Algorithm SHA256).Hash.ToLowerInvariant();
    scope='Debug/Release native export, APK JNI descriptor and process worker wiring; device execution not inferred'} |
    ConvertTo-Json | Set-Content "$directory/verification.json"
Write-Output 'RVM standalone Debug/Release native and DEX checks passed'
