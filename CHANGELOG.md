# Changelog

[简体中文](CHANGELOG.zh-CN.md)

Newest first, following product release milestones. Some development/source snapshots contained features before their product release. Original APK identifiers `0.2` and `0.4` are retained; `0.4` was also called `0.4.0` in release notes. Availability depends on device, server and media capabilities.

## 0.5.1 — 2026-10-11

- Added Plex phone/computer pairing, library browsing and original-file playback, with improved LAN connection selection.
- Corrected Dolby Vision Profile 5 green-tinted playback on compatible hardware; no blanket profile support, Dolby certification or native HDR claim.
- Added embedded PGS bitmap subtitles for flat-screen video, including switching while paused. Immersive projections continue to use text subtitles.
- Added 0.25×–3× playback speed, audio pitch correction and one-button return to 1×.
- Reorganized Screen/Playback/Info settings. Added flat-screen distance, size and curvature controls, and −90°–90° picture rotation while subtitles stay upright.
- Added 50%–200% text subtitle sizing, independent flat-video vertical position and filename guidance. Text controls do not change PGS layout.
- Improved modification-time sorting with folders first for local/SMB/cloud libraries, and ascending/descending DLNA name sorting.
- Fixed screen percentages and slider positions, straightened settings panels, and placed conditional speed/rotation resets beside their sliders.

## 0.5.0 — 2026-10-10

- Upgraded media-server sections, Continue Watching, Recently Added, categories, details, continuous loading and restored navigation/scroll state.
- Added capability-dependent favorites: server-backed where supported, otherwise local; no playback-progress writeback promise.
- Added Aliyun Drive, Quark and remote WebDAV connections. The 115 Open display name became 115.
- Added manual DLNA addresses and server-exposed external subtitles.
- Added photo adjustment controls and a separate 2×–8× magnifier referenced to actual displayed image size; flat-photo distance is 0.3–10 m and size 40%–600%.
- Fixed immersive opening alignment, stale mode locks and Quest passthrough clarity while retaining selected display quality.
- Improved embedded web-login scaling/input and reauthentication entry points.
- Removed unused JCIFS HTTP adapters and strengthened package checks while retaining required HTTP media compatibility.

## 0.4.2 — 2026-10-10

- Added horizontal/vertical immersive text subtitles with improved first-character alignment, multiline/bilingual layouts and long-line wrapping.
- Added live directional placement and extended subtitle distance to 0.1–10 m.
- Improved cloud-folder external-subtitle matching, including language suffixes and paged directories.
- Added text subtitles exposed by supported Emby, Jellyfin, Stash and XBVR servers.
- Extended external dubbing/audio discovery to supported cloud/media-server sources, including `movie.si.mix.m4a` naming.

## 0.4.1 — 2026-10-09

- Rebuilt the QUEST release as application version 0.4.1 / versionCode 8.
- No separate user-facing feature additions were recorded for this packaging revision; it retains the 0.4 feature set.

## 0.4 — 2026-10-09

Also called **0.4.0** in release notes; actual APK versionName was **0.4**.

- Improved photo-to-3D processing reuse, landscape/portrait depth and stable placement after zoom/reset.
- Added half-width SBS and half-height top-bottom stereo layouts, improved format detection and corrected some fisheye proportions.
- Simplified mode controls and moved eye swapping into playback settings.
- Added 115 Open/OneDrive authorization and switched Baidu sign-in to authorization. Existing Baidu accounts need reauthorization; saved legacy 115 accounts remain compatible.
- Added persistent name/modification-time/size sorting for local, SMB and cloud libraries.
- Added optional, confirmation-based file management, disabled by default: supported local/SMB deletion and 115 Open recycle-bin operations.
- Added bundled local/SMB video/subtitle/dubbing renaming, preserving history/bookmark links after complete success.
- Added removable-storage shortcuts, volume-change refresh and a control to stop app reads/preloading; this is not system-level safe eject.
- Added live subtitle distance/position controls, improved long track lists and refreshed About links.

## 0.3.1 — 2026-10-09

- Stabilized VR subtitles relative to video and improved PICO controller compatibility.
- Improved older-Android storage authorization, status/error feedback and directory refresh after permission changes.
- Distinguished charging from connected-but-not-charging power; showed red battery state below 20% when not charging.
- Moved 115 SMS send/verify actions above the keyboard.
- Enlarged launcher artwork while preserving the Thru3D / Media Player wordmark.

## 0.3.0 — 2026-10-09

- Added persistent timestamp bookmarks with timeline/list navigation, deletion and undo; no ratings or editing.
- Added larger immersive photo presentation, softer edges and slide/fade transitions.
- Added single-hand pinch-drag photo navigation and two-hand zoom; capped photo 3D strength at 100%, independently of video.
- Improved portrait depth, edge completion, adjacent-photo preload, looping and conversion-cache reuse/cleanup.
- Moved cloud/media-server forms and web login into VR and improved input layout/hand response.
- Added faster seeking with separate bookmark precision preferences and audio-track selection on the control bar.
- Allowed thumbstick playback shortcuts with ordinary video controls while retaining list/pointer-capture isolation.
- Improved subtitle placement/distance, Jellyfin connections, settings and near-hand/menu/background rendering.

## 0.2.1 — 2026-10-08

- Retained the displayed frame while seeking and corrected timeline targets jumping back before completion.
- Added recent-playback source-frame previews, poster fallback, bounded preview caches and paged history.
- Added controller/hand visual models and improved input/profile handling.
- Added separate QUEST/PICO and experimental standard OpenXR exports while retaining Quest 2 compatibility.

## 0.2 — 2026-10-07

- Upgraded SMB2/3 compatibility, encryption and direct share/subfolder access without enabling SMB1.
- Added global display-quality presets and live sharpness for videos/photos.
- Reorganized settings and added real restart/exit controls.
- Improved PICO panel/input integration and controller fallbacks, keeping accounts/media links compatible.

## 0.1.0 — 2026-10-07

- Initial standalone Android VR/MR video/photo test release.
- Added flat/180°/360° and stereo viewing, supported person-matting passthrough and depth-based 2D-to-3D rendering.
- Provided local/LAN/media-library access, audio tracks, subtitles and controller-ray/hand interaction.
- Supplied separate Quest/PICO builds with multilingual UI and dependency notices.
