# Building from source

The primary application build scripts target PowerShell 7 on Windows. The libmpv source build uses Linux. Paths are configurable; source and build output must remain separate. This repository does not bundle SDKs, compiled libraries or runtime model weights.

## Source-only verification

Python 3.10+ is sufficient for `python tools/Check-PublicSource.py`. Godot host tests require the matching Godot executable but no Android toolchain or models:

```powershell
$env:GODOT_EXE = (Get-Command godot).Source
./tools/Test-Source.ps1
```

## Pinned toolchain

The versions/hashes used by this source snapshot are in `tools/environment/toolchain.lock.json`, the Gradle wrapper, and third-party source locks. The application build checks Godot `4.7.2.stable.official.ed1daf0bf`; use its corresponding Android templates and Godot OpenXR Vendors `5.1.0`. Android plugin configuration uses Java 17, compile SDK 36, build-tools 36.1.0, NDK 29.0.14206865 and CMake 3.31.6. The 0.2.1 Quest export uses min SDK 32 / target SDK 34; PICO and experimental standard OpenXR use 29 / 36. The separately built mpv dependency uses its own locked Linux NDK r30. Do not silently mix these toolchains.

Set your own paths:

```powershell
$env:THRU3D_TOOL_ROOT = Join-Path $HOME '.cache/thru3d-toolchain'
$env:GODOT_EXE = (Get-Command godot).Source
```

Prepare this layout beneath `THRU3D_TOOL_ROOT`:

```text
jdk/jdk-17.0.20.1+1/
android-sdk/                       platform 36, tools, NDK and CMake above
godot-templates/4.7.2.stable/       matching extracted templates incl. android_source.zip
openxr-vendors/5.1.0/asset/addons/godotopenxrvendors/
ncnn/20260526/ncnn-20260526-android-vulkan/arm64-v8a/
mnn/source-3.6.1/                  pristine MNN source
mnn/source-3.6.1-vrpp/             generated patched source
mnn/build-android-arm64-lib-vrpp/libMNN.a
mpv/source-frame/arm64-v8a/        eight rebuilt/exported libraries
```

The build is a dependency assembly workflow, not an unattended SDK installer. Download exact-version tools from their upstream projects, accept applicable terms yourself, and retain their notices. Godot template Android export configuration must point at your JDK/SDK; the scripts supply the release signing environment when building Release.

## MNN

The matting graph depends on project-patched MNN 3.6.1. In Git Bash, with `THRU3D_TOOL_ROOT` pointing at your tool directory:

```bash
bash tools/Build-MnnAndroid.sh
```

This uses `tools/mnn/patch_mnn_vrpp.py` to copy/patch the pristine source and build the static ARM64 library. The unmodified upstream MNN runtime cannot be assumed equivalent. Keep the upstream Apache-2.0 notice with redistributed outputs.

## libmpv / FFmpeg

`third_party/mpv/source-plan.json` and `source-lock.json` identify the dependencies; `native/mpv/patches` contains the source-frame extension. The player requires that extension, not an arbitrary stock `libmpv.so`.

1. Fetch the locked dependency archives with `python tools/environment/mpv-linux/fetch_sources.py --cache <downloads>`.
2. On Linux, set `THRU3D_MPV_WORK` and `THRU3D_MPV_DOWNLOADS`; run the included bootstrap script in a disposable build environment with permission to install its host packages. Obtain Android NDK r30 from the official Android NDK distribution and the mpv-android builder at revision `fdf74f6830c47dbaa8a22ac79726e8303f1db5af`. Name the archives `android-ndk-r30-linux.zip` and `mpv-android-fdf74f6.tar.gz`; the bootstrap script records and verifies their exact SHA256. The dependency source archives are a separate locked set.
3. Run `bash tools/environment/mpv-linux/build_source.sh`. The build applies and verifies the exact mpv patch.
4. Set `THRU3D_MPV_EXPORT` to your chosen output directory, then run `python3 tools/environment/mpv-linux/export_candidate.py`. It verifies the extension, ARM64 ELF, 16 KiB alignment and dependency closure, then writes a new `third_party/mpv/source-build.json` for your library hashes.
5. Place the eight outputs under your Windows tool root's `mpv/source-frame/arm64-v8a`. Build in the same source checkout, or transfer the generated receipt to it together with the libraries.

The committed source-build receipt records reference library bytes. A different machine/toolchain may produce different binaries; rebuild/export a valid receipt instead of bypassing integrity checks. WSL is not asserted to have upstream mpv build support.

## Runtime models and APK

Obtain the matching runtime models separately as explained in [MODELS.md](MODELS.md). The initial source release does not host the distilled matting weights.

```powershell
./tools/Import-ModelAssets.ps1 -FromDirectory ./external-model-assets
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Quest -BuildType Debug
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Pico -BuildType Debug
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor OpenXR -BuildType Debug
```

The build creates/validates the Kotlin plugin AARs, imports/exports Godot, checks manifest/vendor settings, ELF/JNI linkage, model hashes, signing and 16 KiB packaging. These are build checks, not a headset playback acceptance test.

Compatibility targets start at Quest 2 and PICO Neo3. PICO/OpenXR retain min SDK 29 for older Android devices; Quest retains 32/34. Version 0.3.1 packaging checks preserve the legacy-storage flag and existing read/all-files declarations. Android 10 uses the runtime read grant with legacy storage; newer Android versions use the separate all-files access path.

Release builds use `-BuildType Release`. `Prepare-ReleaseSigning.ps1` creates your own reusable local signing key under ignored build outputs. Back it up privately. No distribution key, password or original user's settings are provided in this repository.

Distribution filenames identify platforms as `QUEST`, `PICO` and `OpenXR`, retaining the version and requested build date; for example `Thru3D-QUEST-0.3.1-release-20261009.apk`. Internal export-preset names and older debug fixture filenames can retain their existing names.

The historical full conversion/diagnostic path remains available without `-UsePreparedModelAssets`, but requires upstream/reference models, the pinned project student, converter tools and generated numerical oracles. It is not the minimal build path and does not fetch the missing student automatically.

Model conversion additionally uses ONNX Runtime, NumPy, ONNX simplification, Pillow/OpenCV and the matching MNN converter/Python bindings; distillation uses PyTorch and onnx2torch. These tools belong in separate local environments. The small model-tools requirements lock covers reference conversion packages, not every optional training/analysis tool.

## OpenList Android core

Build-Player invokes tools/environment/Prepare-OpenList.ps1. It downloads checksum-pinned OpenList and Go archives, applies the recorded encrypted Storage.Addition tag, and binds the local cloud/openlist adapter as an arm64 AAR using the fixed gomobile revision and 16KiB linker alignment. The generated AAR is exported alongside the Kotlin plugin. Only its private JNI management API and loopback media router are enabled. Test-CloudCore.ps1 uses a local synthetic WebDAV server to check encryption, original-file ranges and fresh-process persistence without personal accounts.
