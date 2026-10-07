"""Run the same-native Vulkan oracle with hashed independent ONNX fixtures."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ("256x144", "384x216", "512x288", "256x256", "384x384", "512x512")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(report: dict, profile: dict) -> None:
    width, height = profile["input_shapes"]["src"][-1], profile["input_shapes"]["src"][-2]
    state_bytes = sum(shape[1]*shape[2]*shape[3]*4 for key, shape in profile["output_shapes"].items() if key.startswith("r"))
    expected = {"committed_stereo_frames": 6, "rgb_upload_bytes": 6*2*width*height*3*4,
                "initial_state_upload_bytes": 5*state_bytes, "alpha_download_bytes": 6*2*width*height*4,
                "diagnostic_state_download_bytes": 14*state_bytes,
                "validation_upload_bytes": 6*32, "validation_download_bytes": 6*32,
                "production_explicit_recurrent_download_bytes": 0}
    if report["state"] != "passed" or report["state_storage"] != "VkMat_FP32":
        raise ValueError("Resident numerical oracle failed")
    if any(type(report[key]) is not int or report[key] != value for key, value in expected.items()):
        raise ValueError("Explicit transfer counts or rejected-input commits differ")
    bounds = {"alpha_max_abs": 1e-4, "recurrent_max_abs": 1e-3, "alpha_max_rms": 1e-4,
              "recurrent_max_rms": 1e-4, "reset_rollback_max_abs": 1e-6,
              "isolation_max_abs": 1e-4, "rejected_state_max_abs": 0}
    for key, bound in bounds.items():
        if not isinstance(report[key], (int, float)) or not 0 <= report[key] <= bound:
            raise ValueError(f"Numeric bound violated: {key}")
    if report["invalid_right_rejected"] is not True or report["nonfinite_right_rejected"] is not True:
        raise ValueError("Input rejection was not verified")
    if report["gpu_finite_guard_verified"] is not True:
        raise ValueError("GPU state finite guard did not pass packed/unpacked NaN and infinity checks")
    if report["identity_tile_contract_verified"] is not True or report["non_vulkan_layers"] != [] or \
        report["vulkan_capable_layers"] != report["layer_count"]:
        raise ValueError("The exact identity Tile contract and Vulkan partition must be verified")
    if len(report["stereo_ms"]) != 4 or any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in report["stereo_ms"]):
        raise ValueError("Four actual timing samples required")
    phases = report.get("phase_ms", [])
    names = {"input_validation", "setup", "command_record", "submit_wait", "output_validation", "commit", "teardown"}
    if len(phases) != 4:
        raise ValueError("Four complete phase timing samples required")
    for outer, row in zip(report["stereo_ms"], phases):
        if set(row) != names | {"completed", "total"} or row["completed"] is not True:
            raise ValueError("Incomplete phase timing coverage")
        if any(type(row[n]) not in (int, float) or not math.isfinite(row[n]) or row[n] < 0 for n in names | {"total"}):
            raise ValueError("Phase timing must be finite and nonnegative")
        if row["total"] <= 0 or abs(sum(row[n] for n in names)-row["total"]) > 1e-6 or row["total"] > outer+1e-6:
            raise ValueError("Phase totals must reconcile and fit inside the independent outer clock")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--oracle", type=Path, default=ROOT / "build/rvm-resident-host/Release/rvm_resident_oracle.exe")
    args = parser.parse_args()
    executable = args.oracle.resolve()
    output = ROOT / "artifacts/rvm-resident-host" / (datetime.now().strftime("%Y%m%d_%H%M%S")+"_"+uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    source_paths = ["native/rvm/rvm_backend.cpp", "native/rvm/rvm_backend.h", "native/rvm/rvm_channel_mean.cpp",
                    "native/rvm/rvm_resident_validation.cpp", "native/rvm/rvm_resident_validation.h",
                    "native/rvm/rvm_identity_tile.cpp", "native/rvm/rvm_identity_tile.h",
                    "native/rvm/rvm_channel_mean.h", "benchmarks/native_rvm_resident/resident_oracle.cpp",
                    "native/rvm/rvm_state_guard.cpp", "native/rvm/rvm_state_guard.h",
                    "benchmarks/native_rvm_resident/prepare_fixtures.py", "benchmarks/native_rvm_resident/verify.py",
                    "benchmarks/native_rvm_resident/CMakeLists.txt", "build/rvm/include/rvm_profiles.generated.h"]
    sources = {path: digest(ROOT / path) for path in source_paths}
    oracle_hash = digest(executable)
    results = []
    for key in PROFILES:
        model = ROOT / "build/rvm" / key
        fixture = ROOT / "build/rvm-resident-fixtures" / key
        profile = json.loads((model / "profile.json").read_text(encoding="utf-8"))
        manifest = json.loads((fixture / "manifest.json").read_text(encoding="utf-8"))
        if manifest["profile"] != key or manifest["frames_per_eye"] != 4 or len(manifest["files"]) != 48:
            raise ValueError("Incomplete or different reference sequence")
        if manifest["reference_backend"] != "ONNX Runtime CPUExecutionProvider":
            raise ValueError("Independent ONNX reference required")
        if digest(model / "profile.json") != manifest["model_manifest_sha256"] or digest(model / "rvm.fixed.onnx") != manifest["fixed_onnx_sha256"]:
            raise ValueError("ONNX reference lineage differs")
        for filename, record in manifest["files"].items():
            path = fixture / filename
            if path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
                raise ValueError("Reference bytes differ")
        for filename, field in (("rvm.ncnn.param", "ncnn_param_sha256"), ("rvm.ncnn.bin", "ncnn_bin_sha256")):
            if digest(model / filename) != profile[field]:
                raise ValueError("Model bytes differ")
        command = [str(executable), str(model / "rvm.ncnn.param"), str(model / "rvm.ncnn.bin"), str(fixture), key]
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        stdout, stderr = output / f"{key}.json", output / f"{key}.stderr.log"
        stdout.write_text(run.stdout, encoding="utf-8"); stderr.write_text(run.stderr, encoding="utf-8")
        (output / f"{key}.reference-manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
        if run.returncode != 0 or any(word in run.stderr for word in ("failed", "mismatch", "not match")):
            raise RuntimeError(f"Native oracle failed: {key}; raw logs at {output}")
        report = json.loads(run.stdout)
        if report["profile"] != key:
            raise ValueError("Native oracle returned a different profile")
        validate(report, profile)
        rejected = []
        mutations = {"state": "failed", "alpha_max_abs": 1, "recurrent_max_rms": 1,
                     "rejected_state_max_abs": 1e-7, "invalid_right_rejected": False,
                     "nonfinite_right_rejected": False, "committed_stereo_frames": 7,
                     "gpu_finite_guard_verified": False, "validation_download_bytes": 0,
                     "alpha_download_bytes": 0, "initial_state_upload_bytes": 0,
                     "production_explicit_recurrent_download_bytes": 1, "state_storage": "host_fp32"}
        mutations.update(identity_tile_contract_verified=False, non_vulkan_layers=["Tile:expand_146"])
        mutations["phase_ms"] = []
        for field, value in mutations.items():
            bad = copy.deepcopy(report); bad[field] = value
            try:
                validate(bad, profile)
            except ValueError:
                rejected.append(field)
            else:
                raise AssertionError(f"Polluted oracle accepted: {field}")
        for field, value in (("completed", False), ("submit_wait", float("nan")),
                             ("input_validation", -1), ("total", 1e9)):
            bad = copy.deepcopy(report); bad["phase_ms"][0][field] = value
            try:
                validate(bad, profile)
            except ValueError:
                rejected.append("phase_"+field)
            else:
                raise AssertionError("Polluted phase timing accepted: "+field)
        results.append({"profile": key, "report": report, "stdout": str(stdout.relative_to(ROOT)),
                        "stdout_sha256": digest(stdout), "stderr_sha256": digest(stderr),
                        "reference_manifest_sha256": digest(fixture / "manifest.json"),
                        "param_sha256": profile["ncnn_param_sha256"], "bin_sha256": profile["ncnn_bin_sha256"],
                        "polluted_reports_rejected": rejected})
        print(json.dumps({"profile": key, "state": report["state"], "alpha_max_abs": report["alpha_max_abs"]}), flush=True)
    if digest(executable) != oracle_hash or any(digest(ROOT / path) != value for path, value in sources.items()):
        raise ValueError("Oracle binary/source changed during the run")
    record = {"schema_version": 1, "recorded_utc": datetime.now(timezone.utc).isoformat(), "state": "passed",
              "scope": "Windows NVIDIA RTX 5060 Ti Vulkan FP32; same native backend, independent synthetic ONNX reference",
              "source_sha256": sources, "oracle_sha256": oracle_hash, "profiles": results,
              "android_execution_verified": False, "real_motion_quality_verified": False,
              "internal_ncnn_transfer_traffic_measured": False, "quest_performance_verified": False}
    (output / "verification.json").write_text(json.dumps(record, indent=2)+"\n", encoding="utf-8")
    (ROOT / "artifacts/rvm-resident-host-verification.json").write_text(json.dumps(record, indent=2)+"\n", encoding="utf-8")
    print(str(output / "verification.json"))


if __name__ == "__main__":
    main()
