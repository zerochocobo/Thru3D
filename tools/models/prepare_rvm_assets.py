"""Package a numerically checked RVM profile and deterministic Android oracle assets."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]

def package_profile(args: argparse.Namespace, key: str, shared_hashes: tuple[str, str]) -> tuple[dict, dict]:
    profile = json.loads((args.profile / "profile.json").read_text(encoding="utf-8"))
    report = json.loads(args.report.read_text(encoding="utf-8"))
    model_manifest = json.loads((ROOT / "models/manifest/rvm_mobilenetv3.json").read_text(encoding="utf-8"))
    if profile["source_sha256"] != model_manifest["sha256"] or profile["fixed_profile_sequence"] != "passed":
        raise ValueError("Fixed profile is not verified against the pinned source")
    if report["profile"] != profile["profile"] or report["ncnn"] != "1.0.20260526":
        raise ValueError("Reference profile or ncnn version differs from the Android baseline")
    if hashlib.sha256((args.profile / "rvm.fixed.onnx").read_bytes()).hexdigest() != profile["onnx_fixed_sha256"]:
        raise ValueError("Fixed ONNX oracle hash changed")
    if report["numerical"] != "passed" or report["eye_isolation"] != "passed" or report["reset"] != "passed":
        raise ValueError("Unverified ncnn model cannot be bundled")
    for name in ["fgr", "pha", "r1o", "r2o", "r3o", "r4o"]:
        bound = 1e-4 if name in ["fgr", "pha"] else 1e-3
        if not 0 <= report["max_abs"][name] <= bound or not 0 <= report["max_rms"][name] <= 1e-4:
            raise ValueError("Report raw error exceeds FP32 validation bounds")
    width, height = (int(value) for value in key.split("x"))
    if profile["input_shapes"]["src"] != [1,3,height,width] or profile["downsample_ratio"] != 1.0:
        raise ValueError("Profile dimensions or ratio differ from allowlist")
    if report["bin_sha256"] != shared_hashes[1]:
        raise ValueError("Profiles no longer share identical weights; revise packaging")
    separate_param = report["param_sha256"] != shared_hashes[0]
    for index in range(4):
        if profile["input_shapes"][f"r{index+1}i"] != profile["output_shapes"][f"r{index+1}o"]:
            raise ValueError("Recurrent input/output shapes differ")
    for filename, profile_key, report_key in [("rvm.ncnn.param","ncnn_param_sha256","param_sha256"), ("rvm.ncnn.bin","ncnn_bin_sha256","bin_sha256")]:
        actual = hashlib.sha256((args.profile / filename).read_bytes()).hexdigest()
        if actual != profile[profile_key] or actual != report[report_key]:
            raise ValueError("Model hashes differ from numerical verification")
    model_directory = args.output / key
    oracle_prefix = "reference" if key == "256x144" else "reference/" + key
    oracle_directory = args.output / oracle_prefix
    model_directory.mkdir(parents=True, exist_ok=True)
    oracle_directory.mkdir(parents=True, exist_ok=True)
    if key == "256x144":
        for filename in ["rvm.ncnn.param", "rvm.ncnn.bin"]:
            shutil.copyfile(args.profile / filename, model_directory / filename)
    elif separate_param:
        shutil.copyfile(args.profile / "rvm.ncnn.param", model_directory / "rvm.ncnn.param")
    profile["ncnn_numerical_verification"] = "passed_windows_cpu_fp32"
    profile["input_blobs"] = {name:f"in{index}" for index,name in enumerate(profile["input_shapes"])}
    profile["output_blobs"] = {name:f"out{index}" for index,name in enumerate(["fgr","pha","r1o","r2o","r3o","r4o"])}
    (model_directory / "profile.json").write_text(json.dumps(profile,indent=2),encoding="utf-8")
    shutil.copyfile(args.report, model_directory / "ncnn_reference_report.json")
    shutil.copyfile(ROOT / "models/licenses/RVM_GPL-3.0.txt", args.output / "RVM_GPL-3.0.txt")
    session = ort.InferenceSession(str(args.profile / "rvm.fixed.onnx"), providers=["CPUExecutionProvider"])
    if {item.name: item.shape for item in session.get_inputs()} != profile["input_shapes"] or \
       {item.name: item.shape for item in session.get_outputs()} != profile["output_shapes"]:
        raise ValueError("Fixed ONNX actual shapes differ from profile")
    random = np.random.default_rng(20261003)
    names = [item.name for item in session.get_outputs()]
    assets = []
    for eye in ["left", "right"]:
        base = random.random(profile["input_shapes"]["src"], dtype=np.float32)
        states = {name: np.zeros(shape, dtype=np.float32) for name, shape in profile["input_shapes"].items() if name != "src"}
        for index in range(2):
            src = np.roll(base, index * 8, axis=3).copy()
            outputs = session.run(None, {"src": src, **states})
            states = {f"r{i+1}i": value for i, value in enumerate(outputs[2:])}
            for name, value in [("src", src), *zip(names, outputs)]:
                destination = oracle_directory / f"{eye}_{index}.{name}.f32"
                destination.write_bytes(value.astype("<f4", copy=False).tobytes(order="C"))
                assets.append({"path": "rvm/" + oracle_prefix + "/" + destination.name, "shape": list(value.shape),
                               "bytes": destination.stat().st_size,
                               "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
    filenames = ["profile.json", "ncnn_reference_report.json"]
    if key == "256x144":
        filenames += ["rvm.ncnn.param", "rvm.ncnn.bin"]
    elif separate_param:
        filenames += ["rvm.ncnn.param"]
    for filename in filenames:
        path = model_directory / filename
        assets.append({"path": "rvm/" + key + "/" + filename, "bytes": path.stat().st_size,
                       "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    license_file = args.output / "RVM_GPL-3.0.txt"
    if key == "256x144":
        assets.append({"path":"rvm/RVM_GPL-3.0.txt", "bytes":license_file.stat().st_size,
                       "sha256":hashlib.sha256(license_file.read_bytes()).hexdigest()})
    manifest = {"schema_version": 1, "profile": profile["profile"],
                "source_sha256": profile["source_sha256"], "param_sha256": report["param_sha256"],
                "bin_sha256": report["bin_sha256"], "oracle_provider": "ONNXRuntime CPU",
                "oracle_frames_per_eye": 2, "oracle_dtype_layout": "little-endian float32 NCHW batch1",
                "scope": "Synthetic numerical validation only", "android_execution": "not_run", "assets":assets}
    descriptor = {"key": key, "id": profile["profile"], "input_shape": profile["input_shapes"]["src"],
                  "output_shapes": profile["output_shapes"], "param_asset": "rvm/" + (key if separate_param else "256x144") + "/rvm.ncnn.param",
                  "param_sha256": report["param_sha256"], "bin_sha256": report["bin_sha256"],
                  "bin_asset": "rvm/256x144/rvm.ncnn.bin", "oracle_prefix": "rvm/" + oracle_prefix + "/"}
    return manifest, descriptor

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "android/player-plugin/src/main/assets/rvm")
    args = parser.parse_args()
    specs = json.loads((ROOT / "models/manifest/rvm_profiles.json").read_text(encoding="utf-8"))["profiles"]
    if specs[0]["key"] != "256x144" or len({p["key"] for p in specs}) != len(specs):
        raise ValueError("Allowlist requires unique keys and baseline first")
    baseline = json.loads((ROOT / "build/rvm/256x144/profile.json").read_text(encoding="utf-8"))
    shared = (baseline["ncnn_param_sha256"], baseline["ncnn_bin_sha256"])
    bundles, descriptors, rows = [], [], []
    for spec in specs:
        key = spec["key"]
        if key != f'{spec["width"]}x{spec["height"]}':
            raise ValueError("Invalid allowlist profile")
        current = argparse.Namespace(profile=ROOT / "build/rvm" / key,
                                     report=ROOT / "artifacts/rvm-ncnn-reference" / key / "report.json", output=args.output)
        bundle, descriptor = package_profile(current, key, shared)
        bundles.append(bundle)
        descriptors.append(descriptor)
        def shape(value: list[int]) -> str:
            return "{" + f"{value[3]}, {value[2]}, {value[1]}" + "}"
        rows.append("    {" + ", ".join(json.dumps(descriptor[name]) for name in
                    ["key", "id", "param_asset", "bin_asset", "oracle_prefix"]) + ", " + shape(descriptor["input_shape"]) +
                    ", {{" + ", ".join(shape(descriptor["output_shapes"][name]) for name in
                    ["fgr", "pha", "r1o", "r2o", "r3o", "r4o"]) + "}}},")
    manifest = {**bundles[0], "schema_version": 2, "profiles": descriptors,
                "assets": [asset for bundle in bundles for asset in bundle["assets"]]}
    (args.output / "bundle_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    include = ROOT / "build/rvm/include"
    include.mkdir(parents=True, exist_ok=True)
    (include / "rvm_profiles.generated.h").write_text(
        "// Generated from verified ONNX/ncnn shapes; do not edit.\n#pragma once\nnamespace quest {\n"
        f"inline constexpr std::array<RvmProfile, {len(descriptors)}> kRvmProfiles{{{{\n" + "\n".join(rows) +
        "\n}};\n} // namespace quest\n", encoding="utf-8")
    print(json.dumps({"profiles":len(descriptors),"assets":len(manifest["assets"]),
                      "bytes":sum(item["bytes"] for item in manifest["assets"]),"output":str(args.output)},indent=2))

if __name__ == "__main__":
    main()
