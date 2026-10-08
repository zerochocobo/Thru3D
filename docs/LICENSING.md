# Licensing scope

SPDX-License-Identifier: GPL-3.0-only

Copyright (C) 2026 FFSky Studio and contributors.

Unless a file or the provenance records identify a different license, project-owned application source, build tools and technical documentation in this repository are available under the GNU General Public License, version 3 only. The complete, unmodified license text is in the root `LICENSE` file. No warranty is provided, as described in that license.

## Why GPL v3

The native player bridge directly links libmpv and libavcodec. The recorded dependency build uses GPL mpv and FFmpeg with GPL/version3 enabled. Publishing the combined application under GPL v3 is the chosen route for the current implementation. This is a deliberate license choice for project-owned work, not a claim that the mere presence of an external model automatically determines the entire application's license.

Sources: [mpv Copyright](https://github.com/mpv-player/mpv/blob/master/Copyright), [FFmpeg legal information](https://ffmpeg.org/legal.html), and GPL v3 sections 1, 5 and 6 in [LICENSE](../LICENSE). The recorded revisions and build options, rather than an upstream repository's current default alone, determine the actual binary dependency profile.

## Third-party material

The project license does not replace third-party notices or claim ownership of upstream files.

| Component | License / treatment |
| --- | --- |
| libmpv / FFmpeg | Recorded GPL build; source revisions, build scripts and the project mpv patch are included/referenced. Upstream headers retain their notices. |
| Robust Video Matting | Upstream code is GPL-3.0. The project records its modified student weights as GPL-derived; no separate permissive grant for the actual weights is asserted. Keep its full license and modification provenance. |
| Depth Anything V2 Small | Upstream Small weights are Apache-2.0. The ONNX export and graph/MNN modifications are recorded separately. Other Depth Anything model sizes can have different licenses. |
| MNN / ncnn | Upstream Apache-2.0 / BSD-3-Clause respectively; preserve exact-version notices and the MNN modification record. |
| Godot | MIT engine and corresponding template notices. |
| Hand fallback meshes and texture | Unmodified MIT Godot OpenXR hand demo assets; full license and pinned upstream provenance in `app/godot/models/hands`. These glTF buffers are runtime visuals, not AI weights. |
| Godot OpenXR Vendors | External addon; preserve the addon and each vendor component's actual license. No vendor SDK binaries are vendored here. |
| AndroidX Media3 | Apache-2.0; retain applicable dependency/transitive notices when distributing an APK. |
| CodeLibs JCIFS | LGPL-2.1; keep its source/license obligations and those of transitive dependencies. |
| p115rsacipher adaptation | MIT; source and attribution in `third_party/p115rsacipher`. |
| Gradle wrapper | Apache-2.0; license and notice in `third_party/gradle`. |
| Belfast Sunset (Pure Sky) | Unmodified Poly Haven background, CC0-1.0; source and attribution are kept with the image. |
| Project-generated test fixtures | Synthetic images, patterns and audio; no private source media is included. |

RVM source: <https://github.com/PeterL1n/RobustVideoMatting>. Depth Anything source/model license: <https://github.com/DepthAnything/Depth-Anything-V2#license>. Model conversion and slimming scripts are retained in `tools/models`; excluded weights are not relicensed by this repository's declaration.

Names and branding identify this project. The software license does not promise trademark permission or endorsement by the project, device vendors or upstream authors.

## Source publication versus APK distribution

This repository is an application source snapshot. Model weights and compiled third-party libraries are excluded from Git. A clean clone cannot reproduce the current distributed APK until the required modified model and its appropriate modification form are made available separately. The original private media used during training is not distributed; this statement does not conclude what model-related corresponding source must include.

When distributing a covered binary, GPL v3 requires corresponding source through an applicable delivery method. A root license file and links to upstream projects are not, by themselves, a complete binary source offer. Supply the relevant preferred forms for modification, required modifications, interfaces, build/install scripts, exact dependency sources and applicable installation information. Keep each binary release associated with its source tag and model/dependency versions.

Vendor SDK terms, the actual combined binary, distribution-channel terms and any GPL exceptions must also be checked before claiming complete binary-distribution compliance. GPL permissions do not grant rights to third-party SDKs or private media. This source publication does not declare the existing store/testing APK fully compliant.
