"""Independently compare displayed reference/frozen pixels and seek identities."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def require(value, reason):
    if not value:
        raise ValueError(reason)


def audit(directory):
    result = read(directory / "result.json")
    require(result["state"] == "passed_state_trace_pending_independent_pixel_audit", "Incomplete test")
    outputs = []
    processes = set()
    for item in result["modes"]:
        mode = item["mode"]
        before = read(directory / f"{mode}-before-report.json")
        during = read(directory / f"{mode}-during-report.json")
        held = read(directory / f"{mode}-held-report.json")
        target = read(directory / f"{mode}-target-report.json")
        for name, report in ((f"{mode}-before", before), (f"{mode}-during", during),
                             (f"{mode}-target-observe", target)):
            receipt = read(directory / f"{name}-receipt.json")
            processes.add(receipt["diagnostic_process"])
            require(receipt["id"] == report["request_id"], "Stale report ID")
            require(sum(c["request_key"] == receipt["request"] for c in report["commands"]) == 1,
                    "Command not consumed exactly once")
            require(not report["diagnostic_2d"], "Not normal VR entry")
        original = before["media"]["presentation_identity"]
        frozen = during["pixel_probe"]["pair"]
        for key in ("frame_id", "pts_us", "source_epoch", "session_id", "generation", "slot_token"):
            require(original[key] == frozen[key], f"Frozen {key} changed")
        require(frozen["frozen_frame_id"] > 0 and frozen["color_target"] == "texture", "No independent GPU copy")
        require(held["layout"]["frame_hold"]["visible"] and held["layout"]["frame_hold"]["frozen"], "Wait hid frame")
        if mode == "alpha":
            require(before["pixel_probe"]["pair"]["color_target"] == "external", "Direct MediaCodec path not exercised")
            require(during["layout"]["alpha_enabled"], "Freeze lost Alpha")
        for report in (before, during):
            require(report["pixel_probe"]["state"] == "captured", "Pixel capture failed")
            require(report["pixel_probe"]["analytic_material_probe"]["state"] == "passed", "Shader analytic probe failed")
            require("Adreno" in report["pixel_probe"]["renderer"], "Not headset GPU")
        new = target["media"]["presentation_identity"]
        require(new["source_epoch"] > original["source_epoch"] and new["generation"] > original["generation"], "Stale seek epoch")
        require(3000000 <= new["pts_us"] < 3034000, "Wrong exact target")
        require(target["native_status"]["details"]["paused"] == "yes", "Paused seek resumed")
        require(not target["layout"]["frame_hold"]["frozen"] and target["layout"]["frame_hold"]["visible"], "Target did not replace hold")
        indices = lambda r: {(e["rotation"], e["eye"], e["alpha_enabled"]): e for e in r["pixel_probe"]["images"]}
        refs, copies = indices(before), indices(during)
        require(refs.keys() == copies.keys() and len(refs) == 16, "Incomplete rotations/eyes/masks")
        metrics = []
        for key, entry in refs.items():
            a = np.array(Image.open(directory / entry["file"]).convert("RGBA"), dtype=np.int16)
            b = np.array(Image.open(directory / copies[key]["file"]).convert("RGBA"), dtype=np.int16)
            require(a.shape == b.shape == (640, 640, 4), "Wrong capture size")
            diff = np.abs(a - b)
            # Depth uses its R8 as a near map, with Alpha disabled in production.
            # Deliberately forcing that near map as opacity can be entirely transparent.
            if not (mode == "depth" and key[2]):
                require(a[..., :3].mean() > 1 and b[..., :3].mean() > 1, "Black reference or frozen image")
            require(float(diff.mean()) < 1.5 and int(diff.max()) <= 16, "Frozen copy differs materially from displayed frame")
            if mode == "alpha" and key[2]:
                require(a[..., 3].min() < 64 and a[..., 3].max() > 192, "Mask not exercised")
            metrics.append({"rotation": key[0], "eye": key[1], "masked": key[2],
                            "mean_absolute_error": float(diff.mean()), "max_absolute_error": int(diff.max()),
                            "reference_rgb_mean": float(a[..., :3].mean()), "frozen_rgb_mean": float(b[..., :3].mean())})
        rapid = read(directory / f"{mode}-rapid-target-report.json")
        require(rapid["layout"]["playback_control"]["target_ms"] == 2000 and not rapid["layout"]["frame_hold"]["frozen"], "Rapid seek lost final target")
        closed = read(directory / f"{mode}-close-report.json")
        require(closed["media"]["session_id"] <= 0 and not closed["layout"]["frame_hold"]["visible"], "Held close leaked presentation")
        outputs.append({"mode": mode, "copy_us": frozen["freeze_copy_us"], "pixel_cases": metrics})
    require(len(processes) == 1, "Test mixed different processes")
    return {"state": "passed", "apk_sha256": result["apk_sha256"], "modes": outputs,
            "scope": "Actual Quest hardware decode, GPU frozen RGBA/R8 and production shader SubViewport pixels; compositor/head tracking/manual controller feel not inferred"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    checked = audit(args.directory)
    (args.directory / "pixel-audit.json").write_text(json.dumps(checked, indent=2), encoding="utf-8")
    print(json.dumps({"state": checked["state"], "modes": [m["mode"] for m in checked["modes"]],
                      "copy_us": [m["copy_us"] for m in checked["modes"]]}))
