"""Recompute independent ONNX outputs from the stored synthetic input sequence."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument('--model-directory', type=Path)
    parser.add_argument('--source-directory', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    source = args.source_directory or ROOT / "artifacts/rvm-ncnn-reference" / args.profile
    model = args.model_directory or ROOT / "build/rvm" / args.profile
    profile = json.loads((model / "profile.json").read_text(encoding="utf-8"))
    destination = args.output or ROOT / "build/rvm-resident-fixtures" / args.profile
    destination.mkdir(parents=True, exist_ok=True)
    for filename, key in (("rvm.ncnn.param", "ncnn_param_sha256"),
                          ("rvm.ncnn.bin", "ncnn_bin_sha256")):
        if sha256(model / filename) != profile[key]:
            raise ValueError("Model differs from the conversion manifest")
    report = json.loads((source / "report.json").read_text(encoding="utf-8"))
    if report["numerical"] != "passed":
        raise ValueError("Stored ONNX/ncnn reference did not pass")
    session = ort.InferenceSession(str(model / "rvm.fixed.onnx"), providers=["CPUExecutionProvider"])
    output_names = ["fgr", "pha", "r1o", "r2o", "r3o", "r4o"]
    files = {}
    for eye in ("left", "right"):
        states = {key: np.zeros(shape, dtype=np.float32)
                  for key, shape in profile["input_shapes"].items() if key != "src"}
        for frame in range(4):
            name = f"{eye}_{frame}"
            npz = source / f"{name}.npz"
            with np.load(npz, allow_pickle=False) as sequence:
                # The old NPZ contains ncnn outputs. Only its source is reused;
                # this oracle must compare against freshly computed ONNX outputs.
                src = sequence["src"]
                outputs = session.run(output_names, {"src": src, **states})
                reference = {"src": src, **dict(zip(output_names, outputs))}
                states = {f"r{index+1}i": value for index, value in enumerate(outputs[2:])}
                for key in ("src", "pha", "r1o", "r2o", "r3o", "r4o"):
                    value = reference[key]
                    shape = profile["input_shapes"][key] if key == "src" else profile["output_shapes"][key]
                    if list(value.shape) != shape or value.dtype != np.float32 or not np.isfinite(value).all():
                        raise ValueError(f"Invalid {name} {key}")
                    target = destination / f"{name}.{key}.f32"
                    np.ascontiguousarray(value, dtype="<f4").tofile(target)
                    files[target.name] = {"sha256": sha256(target), "bytes": target.stat().st_size,
                                          "reference_npz_sha256": sha256(npz)}
    manifest = {"schema_version": 1, "profile": args.profile,
                "reference_report_sha256": sha256(source / "report.json"),
                "model_manifest_sha256": sha256(model / "profile.json"),
                "fixed_onnx_sha256": sha256(model / "rvm.fixed.onnx"),
                "onnxruntime_version": ort.__version__, "reference_backend": "ONNX Runtime CPUExecutionProvider",
                "frames_per_eye": 4, "files": files,
                "scope": "Synthetic numerical recurrence; not human matting quality or Quest performance"}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"profile": args.profile, "files": len(files), "directory": str(destination)}))


if __name__ == "__main__":
    main()
