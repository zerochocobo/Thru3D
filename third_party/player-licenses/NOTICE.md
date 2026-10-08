# In-app license reader assets

These unmodified license texts are additional copies for the global About reader.
They do not replace each dependency's original notices or source records.

`tools/Prepare-AccountLicenses.py` records the local source of each copy:

- MNN: the existing upstream 3.6.1 source plus the project's recorded patch.
- ncnn: LICENSE.txt from the pinned 1.0.20260526 upstream wheel.
- Godot OpenXR Vendors: all six original vendor license files from addon 5.1.0.
- RVM and Depth Anything: the model license files already recorded in this repository.
- Hands and panorama: existing source/author notices beside the shipped assets.
- Media3: the unmodified Apache 2.0 text; upstream is AndroidX Media3 1.10.1
  (https://github.com/androidx/media), licensed by The Android Open Source Project.
- CodeLibs JCIFS: the unmodified LGPL 2.1 text; upstream version 3.0.4
  (https://github.com/codelibs/jcifs). Source files retain their original author notices.

Godot engine and its compiled dependency notices are read from Engine's runtime
license/copyright APIs. MPV/FFmpeg, p115rsacipher, Gradle and CC0 use existing
third_party assets directly. The index is app/godot/i18n/licenses.json.
