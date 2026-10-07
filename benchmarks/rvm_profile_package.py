"""Verify packaged shapes, oracles and deduplicated weights before Android export."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import numpy as np

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    directory = ROOT / "android/player-plugin/src/main/assets/rvm"
    manifest = json.loads((directory / "bundle_manifest.json").read_text(encoding="utf-8"))
    specs = json.loads((ROOT / "models/manifest/rvm_profiles.json").read_text(encoding="utf-8"))["profiles"]
    keys = [item["key"] for item in specs]
    assert [item["key"] for item in manifest["profiles"]] == keys
    kotlin = (ROOT / "android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/RvmProfiles.kt").read_text(encoding="utf-8")
    godot = (ROOT / "app/godot/scripts/main.gd").read_text(encoding="utf-8").split("var display", 1)[0]
    assert re.findall(r'"(\d+x\d+)"', kotlin) == keys, "Kotlin allowlist differs"
    assert re.findall(r'"(\d+x\d+)"', godot) == keys, "Godot diagnostic sequence differs"
    expected_paths = {item["path"] for item in manifest["assets"]}
    assert len(expected_paths) == len(manifest["assets"]), "Duplicate assets"
    actual_paths = {"rvm/" + path.relative_to(directory).as_posix() for path in directory.rglob("*")
                    if path.is_file() and path.name != "bundle_manifest.json"}
    assert actual_paths == expected_paths, f"Untracked/missing generated assets: {actual_paths ^ expected_paths}"
    for item in manifest["assets"]:
        data = (directory / item["path"].removeprefix("rvm/")).read_bytes()
        assert len(data) == item["bytes"] and hashlib.sha256(data).hexdigest() == item["sha256"]
        if "shape" in item:
            tensor = np.frombuffer(data, dtype="<f4")
            assert len(tensor) == int(np.prod(item["shape"])) and np.isfinite(tensor).all()
            if item["path"].endswith((".src.f32", ".pha.f32")):
                assert tensor.min() >= 0 and tensor.max() <= 1
    reports = []
    for profile in manifest["profiles"]:
        key = profile["key"]
        report = json.loads((ROOT / "artifacts/rvm-ncnn-reference" / key / "report.json").read_text(encoding="utf-8"))
        assert all(report[field] == "passed" for field in ["numerical", "eye_isolation", "reset"])
        for asset_name, digest_name in [("param_asset", "param_sha256"), ("bin_asset", "bin_sha256")]:
            path = directory / profile[asset_name].removeprefix("rvm/")
            assert hashlib.sha256(path.read_bytes()).hexdigest() == profile[digest_name] == report[digest_name]
        for eye in ["left", "right"]:
            for frame in range(2):
                for output, shape in {"src": profile["input_shape"], **profile["output_shapes"]}.items():
                    target = profile["oracle_prefix"] + f"{eye}_{frame}.{output}.f32"
                    oracle = next(item for item in manifest["assets"] if item["path"] == target)
                    assert oracle["shape"] == shape
        reports.append({"key": key, "pha_max_abs": report["max_abs"]["pha"], "numerical": report["numerical"]})
    weights = {profile["bin_asset"] for profile in manifest["profiles"]}
    graphs = {profile["param_asset"] for profile in manifest["profiles"]}
    assert len(weights) == 1 and len(graphs) == 2
    result = {"schema_version": 1, "state": "passed", "scope": "Host package/oracle integrity; not native/device execution",
              "assets": len(manifest["assets"]), "bytes": sum(item["bytes"] for item in manifest["assets"]),
              "unique_weights": len(weights), "unique_graphs": len(graphs), "profiles": reports}
    destination = ROOT / "artifacts/rvm-profile-package.json"
    destination.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
