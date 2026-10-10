# Thru3D Media Player

[简体中文](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [中文更新日志](CHANGELOG.zh-CN.md)

Standalone Android VR/MR media player for Meta Quest and PICO. Thru3D combines a Godot OpenXR interface, Android media access, a native libmpv renderer, and MNN inference for video matting and depth-based stereo rendering.

Current source version: **0.5.1** (Android versionCode **11**). An experimental standard OpenXR Android export is also available.

Minimum compatibility targets are **Quest 2** and **PICO Neo3**. Source/build compatibility does not establish hardware performance or interaction acceptance on every device.

## Features

- Video and photo viewing: flat, 180° and 360° projections; mono and side-by-side stereo.
- Person matting and passthrough composition for supported 180° video projections.
- Depth-based 2D-to-3D viewing for flat mono videos and photos.
- Local Android document access, SMB, WebDAV, DLNA and media-server libraries; 115, Baidu, Aliyun Drive, Quark and OneDrive connections.
- Audio tracks, text subtitles and flat-video PGS bitmap subtitles; 0.25×–3× playback speed with pitch correction and per-file viewing preferences.
- Plex phone/computer pairing and original-file library playback.
- Dolby Vision Profile 5 color handling on compatible hardware; no blanket profile, certification or native HDR claim.
- Picture rotation, flat-screen distance/size/curvature and text subtitle sizing/position; subtitles remain upright when the picture rotates.
- Controller ray/trigger selection and hand interaction; English, Chinese and Japanese UI.
- Persistent timestamp bookmarks, source-frame previews for recent playback, and paged media navigation.
- Rendered hands/controllers and display-quality controls, including sharpness and flat-screen adjustments.
- VR-native account forms and in-app web login; speed-first and precise seek policies.
- Immersive photo presentation, pinch-drag navigation, adjacent-photo preload and cached 3D conversion; photo stereo strength is capped at 100%.

- Media-server sections, filters, details, continuation pages and capability-dependent favorites; manual DLNA endpoints and exposed external subtitles.
- Photo distance/size controls and a separate 2–8× magnifier referenced to the displayed image; source-dependent file management.

## Source release

This repository contains application source, build scripts, third-party source pins/patches, and tests. Model weights, compiled dependencies, signing keys, personal media and development records are excluded.

**A fresh clone does not yet build an APK without external dependencies and the exact runtime models.** The default matting model is a project-modified, distilled RVM model. Its weights are not hosted in this source release; the upstream RVM checkpoint is not a drop-in replacement. See [model requirements](docs/MODELS.md) before starting an Android build. This source snapshot is not presented as a complete corresponding-source offer for an existing APK.

The desktop Godot tests and native depth-stabilizer test can run without model weights or an Android toolchain.

## Architecture

```text
Godot scenes / GDScript / OpenXR
              │
Android Kotlin plugin: media libraries, permissions, playback sessions
              │ JNI
libmpv / FFmpeg → shared GPU video textures → Godot stereo rendering
              └ MNN OpenCL: recurrent matting and monocular depth
```

| Directory | Purpose |
| --- | --- |
| `app/godot` | XR scenes, menus, shaders, localization and host tests |
| `android` | Kotlin Godot plugin, Gradle wrapper and JVM tests |
| `native` | JNI media bridge, rendering and inference backends |
| `cloud/openlist` | Embedded OpenList Go adapter and synthetic tests |
| `tools` | Build, conversion and verification entry points |
| `models` | Model contracts, checksums and licenses; no weights |
| `third_party` | Dependency sources, patches, provenance and notices |
| `benchmarks`, `tests` | Verification programs and synthetic fixtures |

## Getting started

```powershell
git clone https://github.com/zerochocobo/Thru3D-Media-Player.git Thru3D
cd Thru3D
python tools/Check-PublicSource.py

# Source-only tests: point this at your Godot executable.
$env:GODOT_EXE = (Get-Command godot).Source
./tools/Test-Source.ps1
```

For Android, prepare the pinned toolchain and externally supplied, version-matched models as described in [BUILD.md](docs/BUILD.md):

```powershell
$env:THRU3D_TOOL_ROOT = Join-Path $HOME '.cache/thru3d-toolchain'
./tools/Import-ModelAssets.ps1 -FromDirectory ./external-model-assets
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Quest
# PICO uses a separate export preset and vendor loader.
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Pico
# Experimental: requires a compatible standard OpenXR runtime on the device.
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor OpenXR
```

Outputs are written under the ignored `artifacts` directory. A locally built application has your own signing identity. It cannot necessarily update an installed distribution signed by another key.

## Controls

Open the VR menu with the left Menu button. Point a controller ray at a control and press that controller's trigger. Libraries, settings, list popups and photo menus use thumbsticks only for scrolling. The ordinary video control bar allows seek, volume and immersive zoom shortcuts; pointer capture suppresses them, with a return-to-center gate after capture or lists close. Hand pointing/pinching is also supported. Desktop input is intended for development previews.

## Status and limitations

- Early source release; Android ARM64 builds use separate Quest, PICO and experimental standard OpenXR presets.
- Quest 3 has been used during development. PICO packaging checks do not establish PICO hardware playback, passthrough or hand-tracking validation.
- Matting quality, GPU support and sustained performance depend on the model, device and video. Host/packaging checks are not headset performance measurements.
- AI depth operates on flat mono content; passthrough matting is limited to supported 180° projections.
- Cloud/media-service adapters depend on third-party services and user authorization.

Read [architecture](docs/ARCHITECTURE.md), [build](docs/BUILD.md), [models](docs/MODELS.md) and [testing](docs/TESTING.md) for implementation details. Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Project-owned source is released under **GPL-3.0-only**. See [LICENSE](LICENSE) for the complete GNU GPL v3 text and [licensing scope](docs/LICENSING.md) for third-party code, models, assets and binary distribution requirements. Third-party components keep their existing licenses; this declaration does not relicense them or grant rights to excluded assets.

The embedded OpenList component is **AGPL-3.0**; its adapter, pinned build recipe and upstream/dependency notices are included. Combined binary distribution must satisfy its applicable AGPL obligations as explained in the licensing scope.
