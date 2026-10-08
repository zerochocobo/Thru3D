# Architecture

## Application and interaction

`app/godot/scenes/main.tscn` and `scripts/main.gd` own application state. Godot OpenXR supplies tracking and the vendor-specific passthrough interface. GDScript menus use controller rays/triggers and hand pointing/pinching. While a menu is open, thumbsticks scroll rather than select controls or trigger playback shortcuts.

Display geometry separates flat/180°/360° projection from mono/SBS layout and eye order. Menu pages, per-file preferences and localization are independent of the Android media backend. The desktop path is a development preview and mock backend, not an equivalent Android/XR playback implementation.

Version 0.2.1 adds persistent timestamp-only bookmarks (`bookmark_store`, `bookmark_menu`, `timeline_markers`), paged recent-file previews, cloud account/pagination handling, and input visuals. `input_visuals.gd` uses runtime render models when available and licensed glTF hand fallbacks. Seek keeps a presented frame until the target frame arrives. No ratings, stars or bookmark editing are exposed.

## Android boundary

`QuestPlayerPlugin.kt` exposes Godot-callable methods and owns Android media selection, libraries and lifecycle. Document grants, file descriptors and HTTP/SMB/cloud sources are managed in Kotlin. Authentication data stays in application-private storage; no account credentials belong in source control.

The plugin contains older controlled MediaCodec/Media3 diagnostic paths. Normal video playback uses `MpvVideoBridge` and the native mpv source extension. Their presence in source does not mean that all paths execute during ordinary playback.

## Rendering and inference

`native/mpv/mpv_source.cpp` connects libmpv's source-frame extension to JNI. `native/render-bridge` owns GPU texture/buffer operations. Frame PTS, generations and fences prevent mismatching image/alpha, showing stale frames after seek, or reusing a texture before GPU ownership is released.

The normal matting backend uses MNN OpenCL with four recurrent states for each eye. ROI decisions are in Kotlin's `RoiController`; the default source snapshot uses the internal 320×320 fast profile. No model/resolution selector is exposed in the normal UI. ncnn/reference paths are retained for dedicated diagnostics; normal playback has no automatic CPU fallback.

The independent depth backend processes flat mono videos/photos using Depth Anything V2 Small. `depth_stabilizer` limits temporal variation before Godot renders depth-based stereo. Depth updates and display frames have distinct timing; a rendered-frame rate is not an inference rate.

## Build boundaries

The Godot export plugin references the separately built Kotlin AAR and Maven dependencies. The matching Godot template provides one engine. Each Android export preset enables one vendor loader. Models, SDK/addon binaries and native libraries are prepared outside Git and checked during packaging.

The public snapshot removes private store-capture automation from the application startup path. It retains runtime icons, the licensed background, synthetic fixtures and production behavior. Source-only tests do not establish headset passthrough quality, tracking or sustained thermal performance.
