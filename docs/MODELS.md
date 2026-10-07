# Runtime models

No model weights are stored in this Git repository. `models/manifest/runtime-assets.json` records the exact runtime MNN files, their sizes, SHA256 and conversion manifests. Model licenses remain in `models/licenses`.

## Version-matched assets

Normal playback expects:

```text
external-model-assets/
  rvm-mnn/rvm.mnn       modified/distilled RVM, RGBA uint8-range input
  depth-mnn/depth.mnn   Depth Anything V2 Small, 252×140 input
```

Import without trusting the supplied files' own metadata:

```powershell
./tools/Import-ModelAssets.ps1 -FromDirectory ./external-model-assets
./tools/Import-ModelAssets.ps1 -VerifyOnly
```

The importer checks every model against the committed catalog before copying, reconstructs the model manifests, and installs the license notices. Models land in ignored Android assets. Do not commit them. The prepared-assets build mode supports ordinary Debug/Release builds; full numerical diagnostics require additional reference models and generated oracles.

**There is no hosted download for the project-distilled student in this initial source release.** A matching, independently obtained model directory is required for an APK build. Do not invent a release URL or substitute an upstream file while retaining the student's checksums. The importer fails explicitly if the files are missing or wrong. Source-only tests do not need these files.

## Source and transformations

| Model | Source | Project transformations |
| --- | --- | --- |
| RVM MobileNetV3 | [RVM v1.0.0](https://github.com/PeterL1n/RobustVideoMatting/releases/tag/v1.0.0); pinned ONNX in `rvm_mobilenetv3.json` | Ratio=1 specialization, unused output pruning, 0..255/RGBA input handling, operator fusion, sliced decoder and recurrent student distillation, MNN conversion. |
| Depth Anything V2 Small | [ONNX model](https://huggingface.co/onnx-community/depth-anything-v2-small); source SHA256 in the runtime conversion manifest | Fixed 252×140 shape, folded normalization, patch-embedding and attention rewrites, MNN FP16 weights. |

RVM uses four recurrent states independently for each eye. Runtime models are not generic arbitrary ONNX/MNN files; tensor names, dimensions, conventions and the patched MNN kernels are part of the interface contract.

Relevant tools:

- `Prepare-RvmReference.ps1`: retrieve/import the pinned upstream ONNX with hash verification.
- `specialize_rvm_ratio_one.py`, `fuse_rvm_graph.py`, `slim_rvm_decoder.py`: graph modifications.
- `distill_rvm_decoder.py`: train/export a student using explicitly supplied, licensed media. `data --sources` takes a JSON array of `{ "file": "path/to/your-video.mp4", "exclude_seconds": [[0, 5]] }`; no original training filenames are built in.
- `prepare_rvm_mnn.py`: convert the matching student and upstream quality graph using `MNNCONVERT`.
- `prepare_depth_mnn.py`: convert/check the depth source with two user-provided sample images under `build/depth/sample_a.png` and `sample_b.png`.
- `tools/mnn/patch_mnn_vrpp.py`: reproduce the MNN OpenCL HardSwish changes required by the matting graph.

For example, graph preparation begins with:

```powershell
./tools/models/Prepare-RvmReference.ps1
./.venv/Scripts/python.exe tools/models/specialize_rvm_ratio_one.py
$env:MNNCONVERT = (Get-Command mnnconvert).Source
```

Re-training on other media will generally produce different student weights and cannot reproduce the pinned student checksum. Changing a model requires updating the contract/catalog, conversion evidence and runtime validation together. Do not disable hash checks to imply equivalence.

## Licenses

The upstream RVM code is GPL-3.0; the project records its reused/sliced student weights as GPL-derived. The actual weight grant and appropriate modifiable form must be considered when distributing them. Depth Anything V2 **Small** weights are Apache-2.0; Base/Large/Giant have different terms. Excluding weights from Git does not settle obligations for APKs that embed them. See [licensing scope](LICENSING.md).
