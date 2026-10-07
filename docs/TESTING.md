# Testing

## Source-only checks

```powershell
python tools/Check-PublicSource.py
$env:GODOT_EXE = (Get-Command godot).Source
./tools/Test-Source.ps1
```

The public checker examines tracked files for excluded binary types, credentials and private paths. It is a publication boundary check, not a substitute for a full security review.

`Test-Source.ps1` runs the Godot GDScript host suite without activating the Android toolchain. It includes localization, media-library/menu interaction, controller/hand logic, projection/eye-order, preferences and image/depth handling. An OpenXR loader can be absent during headless tests; XR/device behavior is not part of their result.

The native depth stabilizer can also be tested with a C++17 compiler:

```bash
mkdir -p build/tests
g++ -std=c++17 -Wall -Wextra -Werror -I native/rvm tests/native/depth_stabilizer_test.cpp native/rvm/depth_stabilizer.cpp -o build/tests/depth_stabilizer_test
./build/tests/depth_stabilizer_test
```

## Android tests

With the full toolchain configured, `Build-Player.ps1` runs JVM tests as part of plugin assembly. `Test-Player.ps1` provides the broader historical host/render checks. Additional `Test-*Device.ps1` tools require an authorized headset and their specified media/model fixtures.

Only project-generated synthetic media are distributed. Moving-person tests and student training require user-supplied, licensed media; original personal media, numerical captures and device identifiers are excluded. Generate your own fixtures before attempting those optional probes.

## What constitutes device verification

Record the APK hash, device/vendor, model hash, input media contract and test scope. Distinguish decoding, inference, presented unique video frames, engine ticks and final XR display. Test seeking, pause/resume, menu interactions, permission revocation, background/foreground transitions, stereo alignment and sustained operation separately.

Host tests and ELF/APK inspection do not prove passthrough visuals, audio synchronization, physical hand/controller interaction or sustained frame rate. PICO export success is not PICO hardware validation.
