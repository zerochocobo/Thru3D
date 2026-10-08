"""Verify Quest production ray-release settings and bookmark precision routing."""
import argparse
import hashlib
import json
from pathlib import Path

from mpv_seek_strategy_device import Device, PACKAGE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("adb", "serial", "apk", "output"):
        parser.add_argument("--"+name, required=True)
    args = parser.parse_args()
    directory = Path(args.output); directory.mkdir(parents=True, exist_ok=True)
    device = Device(args.adb, args.serial, directory)
    installed = device.run("shell", "pm", "path", PACKAGE).strip().removeprefix("package:")
    sha = device.run("shell", "sha256sum", installed).split()[0]
    if sha != hashlib.sha256(Path(args.apk).read_bytes()).hexdigest(): raise RuntimeError("APK differs")
    result = {"state": "running", "apk_sha256": sha, "cases": [],
              "scope": "Real Quest production ray press/release software paths and verified source PTS; no physical controller feel/compositor claim"}
    marker = None

    def ui(label, step, **extras):
        rec = device.request(label, "seek_policy_ui", step=step, **extras)
        r = device.wait(label, rec, lambda r: r.get("seek_policy_ui", {}).get("request_key") == rec["request"])
        if not r["seek_policy_ui"].get("accepted"): raise RuntimeError("Ray release rejected: "+step)
        return rec, r

    try:
        rec = device.request("open", "open", fixture="mp08_8k_high_30", enabled=False, stereo=True, profile="320x320", seek_mode="speed")
        device.wait("open", rec, lambda r: r["media"]["frame_counter"] >= 2)
        rec = device.request("pause", "playing", enabled=False)
        device.wait("pause", rec, lambda r: r["native_status"]["details"].get("paused") == "yes")
        device.seek("marker-position", 7584, "exact")
        _, r = ui("add", "bookmark_add")
        marker = r["seek_policy_ui"]["marker"]
        if abs(marker["position_ms"] - 7584) > 17: raise RuntimeError("Wrong stored bookmark PTS")
        result["marker"] = marker
        for global_mode, override, expected in [("speed", "global", "speed"), ("speed", "exact", "exact"),
                                               ("exact", "speed", "speed"), ("exact", "global", "exact")]:
            name = global_mode+"-"+override
            _, r = ui(name+"-global", "global_"+global_mode)
            if r["seek_policy_ui"]["global_mode"] != global_mode: raise RuntimeError("Global setting not applied")
            _, r = ui(name+"-override", "bookmark_"+override)
            if r["seek_policy_ui"]["bookmark_mode"] != override: raise RuntimeError("Independent bookmark setting not applied")
            origin = device.seek(name+"-origin", 27000, global_mode)
            rec, _ = ui(name+"-tap", "bookmark_seek", marker_id=marker["id"])
            r = device.wait(name+"-landed", rec, lambda r: r["layout"]["playback_control"]["state"] == "idle"
                and r["layout"]["playback_control"]["target_ms"] == marker["position_ms"]
                and r["media"]["presentation_identity"]["source_epoch"] > origin["source_epoch"]
                and r["player_menu_progress"].get("position_ms") == r["layout"]["playback_control"]["observed_position_ms"])
            pair = r["media"]["presentation_identity"]; actual = pair["pts_us"]/1000
            if not pair["source_pts_verified"] or abs(actual - (marker["position_ms"] if expected == "exact" else 5082)) > 17:
                raise RuntimeError("Bookmark landed at wrong frame")
            if r["native_status"]["seek_mode"] != expected: raise RuntimeError("Native precision differs")
            if abs(r["layout"]["playback_control"]["observed_position_ms"] - actual) > 1:
                raise RuntimeError("Progress did not match actual frame")
            _, r = ui(name+"-stored", "bookmark_"+override)
            saved = next(b for b in r["seek_policy_ui"]["bookmarks"] if b["id"] == marker["id"])
            if saved["position_ms"] != marker["position_ms"]: raise RuntimeError("Precision changed stored time")
            result["cases"].append({"global": global_mode, "bookmark": override, "effective": expected,
                "stored_ms": saved["position_ms"], "actual_ms": actual})
        result["diagnostic_process"] = device.process; result["state"] = "passed"
    except BaseException as error:
        result["state"] = "failed"; result["error"] = str(error); raise
    finally:
        try:
            if marker:
                _, r = ui("cleanup-marker", "bookmark_delete", marker_id=marker["id"])
                if any(b["id"] == marker["id"] for b in r["seek_policy_ui"]["bookmarks"]):
                    raise RuntimeError("Test bookmark cleanup failed")
            ui("restore-global", "global_speed")
            ui("restore-bookmark", "bookmark_global")
            result["cleanup"] = "test bookmark removed; speed/global restored"
        except BaseException as error:
            result["cleanup_error"] = str(error); result["state"] = "failed"
        (directory / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
