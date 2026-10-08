param(
    [Parameter(Mandatory=$true)][string]$Serial,
    [Parameter(Mandatory=$true)][string]$Probe,
    [string]$Inputs = 'artifacts/photo-depth-fix/xz',
    [string[]]$Samples = @('index-20_1','index-35_1','index-50_1'),
    [string]$Output = 'artifacts/photo-depth-fix/device'
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$adb = (Get-Command adb -ErrorAction Stop).Source
$ndk = if ($env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME } elseif ($env:THRU3D_TOOL_ROOT) { Join-Path $env:THRU3D_TOOL_ROOT 'android-sdk/ndk/29.0.14206865' } else { throw 'Activate the Android environment before running a device probe.' }
$out = Join-Path $workspace $Output
New-Item -ItemType Directory -Force $out | Out-Null
$remote = '/data/local/tmp/vrpp_photo_depth_' + [guid]::NewGuid().ToString('N')
function Adb-Photo([string[]]$Arguments) {
    $result = & $adb -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB failed: $($Arguments[0]); $result" }
    return $result
}
Adb-Photo -Arguments @('shell','mkdir','-p',$remote) | Out-Null
$executable = Join-Path $out 'photo_depth_probe'
Copy-Item -LiteralPath (Resolve-Path -LiteralPath $Probe) -Destination $executable -Force
& "$ndk/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe" --strip-debug $executable
if ($LASTEXITCODE -ne 0) { throw 'Probe strip failed' }
Adb-Photo -Arguments @('push',$executable,"$remote/photo_depth_probe") | Out-Null
Adb-Photo -Arguments @('push',"$ndk/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so","$remote/libc++_shared.so") | Out-Null
$model = Join-Path $workspace 'android/player-plugin/src/main/assets/depth-mnn/photo_depth.mnn'
Adb-Photo -Arguments @('push',$model,"$remote/photo_depth.mnn") | Out-Null
Adb-Photo -Arguments @('shell','chmod','755',"$remote/photo_depth_probe") | Out-Null
$report = @{ scope='Standalone production Android Depth runtime, MNN OpenCL FP16; no XR or Android Bitmap/EXIF execution'; serial=$Serial; remote=$remote; model_sha256=(Get-FileHash $model -Algorithm SHA256).Hash.ToLowerInvariant(); samples=@() }
foreach ($sample in $Samples) {
    if ($sample -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid sample name' }
    $folder = Join-Path (Join-Path $workspace $Inputs) $sample
    $metadata = Get-Content (Join-Path $folder 'input.json') -Raw | ConvertFrom-Json
    if ($metadata.width -ne 518 -or $metadata.height -ne 518 -or $metadata.rect.Count -ne 4) { throw 'Unexpected input shape' }
    Adb-Photo -Arguments @('push',(Join-Path $folder 'input.bin'),"$remote/input.bin") | Out-Null
    $rect = ($metadata.rect | ForEach-Object { [int]$_ }) -join ' '
    $log = Adb-Photo -Arguments @('shell',"cd $remote && LD_LIBRARY_PATH=. ./photo_depth_probe photo_depth.mnn input.bin near.bin photo.cache $rect 1")
    $log | Set-Content (Join-Path $out "$sample.log")
    $json = @($log | Where-Object { $_ -match '^\{"state"' })[-1] | ConvertFrom-Json
    if ($json.state -ne 'ready' -or $json.gpu_ops -le 0 -or $json.cpu_fallback_ops -ne 0) { throw "GPU photo depth failed: $sample" }
    Adb-Photo -Arguments @('pull',"$remote/near.bin",(Join-Path $out "$sample-near.bin")) | Out-Null
    $report.samples += @{ name=$sample; runtime=$json; input=$metadata }
    $report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $out 'report.json')
    Write-Output "$sample GPU ops=$($json.gpu_ops) fallback=$($json.cpu_fallback_ops) inference_ms=$($json.runs_ms -join ',')"
}
# Keep the uniquely named probe cache for follow-up warm/cold comparisons; never modify app data.
Write-Output "Device evidence: $out; probe cache: $remote"
