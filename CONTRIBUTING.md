# Contributing

Open an issue or pull request with a concrete problem, the affected source path and a reproducible example. Keep one change focused on one behavior. Contributions to project-owned source are submitted under GPL-3.0-only; preserve existing third-party notices and identify any imported code's origin/license.

Run the source boundary and applicable host tests described in [TESTING.md](docs/TESTING.md). Android changes also need JVM/build checks; headset-specific claims need device evidence with matching versions. State what you have and have not verified.

Do not commit model weights, generated APKs/libraries, signing material, credentials, personal media or device logs containing user data. Provide synthetic reproduction fixtures or generation instructions. Do not send account tokens in public issues.

VR menus use controller ray/trigger selection or hand interaction, never thumbstick selection. Libraries, settings, list popups and photo menus reserve thumbsticks for scrolling and suppress playback shortcuts. The ordinary video control bar allows the same seek, volume and immersive zoom shortcuts as hidden controls. Pointer capture suppresses shortcuts; after leaving a list or ending capture, the stick must return to center before reactivation. Keep visible UI text concise and place implementation notes in technical documentation.

Distribution APK filenames use platform names `QUEST`, `PICO` and `OpenXR`, with the requested software version and build date. Do not use specific headset models in distribution filenames.
