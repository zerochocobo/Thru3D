# Third-party components

This directory retains upstream license texts, source locks, checksums and provenance. The application's overall GPL v3 choice does not replace these components' existing terms. See [licensing scope](../docs/LICENSING.md) for the component inventory and binary-release requirements.

- `mpv`: headers/provenance, exact source archives, library reference receipt and GPL/LGPL texts. The project's source-frame modification is in `native/mpv/patches`.
- `p115rsacipher`: original MIT notice and provenance for the Kotlin 115 RSA adaptation.
- `gradle`: wrapper Apache-2.0 license and notice.
- `polyhaven`: CC0 source and attribution for the unmodified built-in background.

Godot, Godot OpenXR Vendors, MNN, ncnn and Maven dependencies are prepared externally. Keep their exact-version notices with redistributed outputs. The MNN fork is built from upstream 3.6.1 plus `tools/mnn/patch_mnn_vrpp.py`; models use their separately recorded licenses.

The repository includes only synthetic test media. Private human-video fixtures and model weights are excluded.
