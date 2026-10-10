# Architecture

## Application and interaction

`app/godot/scenes/main.tscn` and `scripts/main.gd` own application state. Godot OpenXR supplies tracking and the vendor-specific passthrough interface. GDScript menus use controller rays/triggers and hand pointing/pinching. Libraries, settings, list popups and photo menus reserve thumbsticks for scrolling. The ordinary video control bar permits seek, volume and immersive zoom shortcuts. Pointer capture suppresses shortcuts; leaving a list or ending capture requires the stick to return to center before reactivation.

Display geometry separates flat/180°/360° projection from mono/SBS layout and eye order. Menu pages, per-file preferences and localization are independent of the Android media backend. The desktop path is a development preview and mock backend, not an equivalent Android/XR playback implementation.

The application includes persistent timestamp-only bookmarks (`bookmark_store`, `bookmark_menu`, `timeline_markers`), paged recent-file previews, cloud account/pagination handling, and input visuals. `input_visuals.gd` uses runtime render models when available and licensed glTF hand fallbacks. Seek keeps a presented frame until the target frame arrives; `seek_policy.gd` routes speed-first and precise positioning. No ratings, stars or bookmark editing are exposed.

Photo presentation uses immersive screen geometry, adjacent-image preloading and a separate stereo cache. Flat-photo navigation uses a single-hand horizontal pinch drag followed by release; two-hand pinch zoom remains available. Photo stereo strength is capped at 100%, independently of video strength. `projected_subtitles.gd` and the shader include implement subtitles in the video projection.

## Android boundary

`QuestPlayerPlugin.kt` exposes Godot-callable methods and owns Android media selection, libraries and lifecycle. Document grants, file descriptors and HTTP/SMB/cloud sources are managed in Kotlin. Authentication data stays in application-private storage; no account credentials belong in source control.

`LocalStoragePermissions` separates Android 10 legacy/read-permission access from Android 11+ all-files settings, with supported settings fallbacks and directory refresh. `DeviceBatteryStatus` interprets the sticky battery snapshot separately from cable connection; connected power alone does not mean charging.

The plugin contains older controlled MediaCodec/Media3 diagnostic paths. Normal video playback uses `MpvVideoBridge` and the native mpv source extension. Their presence in source does not mean that all paths execute during ordinary playback.

Account and server forms are rendered by `account_panel.gd` inside the VR library.
`AccountManager` owns transient authentication state and cancelled-request guards.
Web authentication uses `InAppWebLogin` to transfer in-memory WebView frames and
ray/keyboard events through the same host Activity. It does not launch account
Activities or the PICO 2D shell. Pause keeps the current workflow; an explicit
close cancels it. The global About page contains the license index and reader.
These bridges still require device-specific website/input validation.

## Rendering and inference

`native/mpv/mpv_source.cpp` connects libmpv's source-frame extension to JNI. `native/render-bridge` owns GPU texture/buffer operations. Frame PTS, generations and fences prevent mismatching image/alpha, showing stale frames after seek, or reusing a texture before GPU ownership is released.

The normal matting backend uses MNN OpenCL with four recurrent states for each eye. ROI decisions are in Kotlin's `RoiController`; the default source snapshot uses the internal 320×320 fast profile. No model/resolution selector is exposed in the normal UI. ncnn/reference paths are retained for dedicated diagnostics; normal playback has no automatic CPU fallback.

The independent depth backend processes flat mono videos/photos using Depth Anything V2 Small. `depth_stabilizer` limits temporal variation before Godot renders depth-based stereo. Depth updates and display frames have distinct timing; a rendered-frame rate is not an inference rate.

## Build boundaries

The Godot export plugin references the separately built Kotlin AAR and Maven dependencies. The matching Godot template provides one engine. Each Android export preset enables one vendor loader. Models, SDK/addon binaries and native libraries are prepared outside Git and checked during packaging.

The public snapshot removes private store-capture automation from the application startup path. It retains runtime icons, the licensed background, synthetic fixtures and production behavior. Source-only tests do not establish headset passthrough quality, tracking or sustained thermal performance.

## Cloud providers

Existing 115 and Baidu clients retain encrypted account records. The embedded OpenList JNI core supplies additional provider connections, including 115 Open, OneDrive, Aliyun Drive and Quark. Only the capability-protected loopback media router listens on HTTP. Authorization stays in the same Activity's VR web panel; provider-specific callbacks are validated against the active session/state before importing credentials and checking directory access. Quark uses the FnNAS broker's nonce-bound callback exchange. No OpenList frontend or separate Android account window is used. Real-account and minimum-headset validation remains separate from source publication.

Media-server browsing separates home sections, loaded pages, filter/category state and detail navigation. Favorites use server support where available and a local fallback otherwise. Source policies and native/Go bridges provide supported rename/delete operations without assuming every backend permits writes. Photo magnification maps the displayed image's local projected size to a separate inspection window; it does not enlarge the underlying full-image shader.
