"""Quest XR regression: Alpha first frame, close, reopen, and enable Alpha again.

Requires an installed Debug build and a staged files/fixtures/<fixture>.mp4 (use
adb push then run-as cp). No installation or device resolution changes are made.
Uses the production Godot/native pipeline and saves current-session draw proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=Path, required=True, help="Exact installed APK, including its signature")
    parser.add_argument("--fixture", choices=("mp05_person_still", "mp08_8k_low", "mp08_8k_high"), default="mp05_person_still")
    parser.add_argument("--cycles", type=int, default=12)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 100:
        parser.error("cycles must be 1..100")
    args.out.mkdir(parents=True, exist_ok=False)
    package = "com.wapok.thru3d"
    base = [args.adb, "-s", args.serial]
    process_id = None
    last_frame_report_us = 0
    readiness = []

    def adb(*command):
        return subprocess.run(base + list(command), capture_output=True, check=True, timeout=30).stdout

    def read(name):
        try:
            return json.loads(adb("exec-out", "run-as", package, "cat", "files/diagnostics/" + name))
        except (subprocess.CalledProcessError, ValueError):
            return {}

    def save(name, data):
        (args.out / name).write_text(json.dumps(data, indent=2) + "\n", encoding="utf8")

    def command(label, operation, enabled=None):
        nonlocal process_id, last_frame_report_us
        key = uuid.uuid4().hex
        extras = [] if enabled is None else ["--ez", "enabled", str(enabled).lower()]
        if operation == "open":
            extras += ["--es", "fixture", args.fixture, "--es", "profile", "320x320",
                       "--ez", "benchmark", "true", "--ei", "projection", "1"]
        adb("shell", "am", "broadcast", "-n", package + "/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",
            "-a", package + ".DEBUG_PLAYER_MPV", "--es", "request", key, "--es", "operation", operation, *extras)
        deadline = time.monotonic() + 15
        receipt = {}
        while time.monotonic() < deadline:
            receipt = read("debug_request_" + key + ".json")
            if receipt:
                break
            time.sleep(0.15)
        save(label + "-receipt.json", receipt)
        if receipt.get("state") != "accepted":
            raise RuntimeError(f"{label}: request rejected: {receipt}")
        if process_id is not None and process_id != receipt.get("diagnostic_process"):
            raise RuntimeError("Player process changed during the test")
        process_id = receipt["diagnostic_process"]
        # Benchmark reports are throttled; closing has no future frame to trigger
        # another report. The main app's periodic snapshot still observes close.
        if operation == "close":
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                caps = read("capabilities_latest.json")
                if (caps.get("media", {}).get("state") == "closed"
                        and caps["media"]["session_id"] <= 0
                        and caps.get("xr", {}).get("captured_ticks_usec", 0) > last_frame_report_us
                        and caps.get("xr", {}).get("applied_passthrough") == (caps.get("background") == "passthrough")):
                    save(label + "-closed.json", caps)
                    return
                time.sleep(0.15)
            raise TimeoutError(label + ": closed presentation/background")
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            report = read("mpv_player_" + str(receipt["id"]) + ".json")
            if report and any(c.get("request_key") == key for c in report.get("commands", [])):
                save(label + "-report.json", report)
                media = report["media"]
                native = report.get("native_status", {})
                layout = report["layout"]
                if media["state"] == "failed":
                    raise RuntimeError(f"{label}: {media['error']}")
                if report["diagnostic_2d"]:
                    raise RuntimeError("Expected real XR entry")
                if (native.get("session_id") == media["session_id"]
                        and native.get("rvm_model_created") and not native.get("rvm_model_ready")):
                    sample = {k: native.get(k) for k in ("session_id", "acquired", "captured_frames", "rvm_model_ready")}
                    if not readiness or readiness[-1] != sample:
                        readiness.append(sample)
                    # MPV's acquired counter is shared across revisions of one
                    # source; only captured_frames belongs to this Alpha session.
                    if native.get("captured_frames", 0) != 0:
                        raise RuntimeError("Alpha captured a source frame before model readiness")
                if (media["frame_counter"] > 0 and native.get("session_id") == media["session_id"]
                        and native.get("generation") == media["generation"] and native.get("post_draw_frames", 0) > 0
                        and layout["alpha_enabled"] == enabled and (not enabled or layout["alpha_ready"])):
                    print(f"{label}: session {media['session_id']}, drawn Alpha={enabled}", flush=True)
                    last_frame_report_us = report["sample_monotonic_us"]
                    return
            time.sleep(0.15)
        raise TimeoutError(label)

    installed = adb("shell", "pm", "path", package).decode().strip().removeprefix("package:")
    installed_hash = adb("shell", "sha256sum", installed).decode().split()[0]
    with args.apk.open("rb") as stream:
        expected_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    if installed_hash != expected_hash:
        raise RuntimeError("Installed APK differs from --apk")
    result = {"state": "failed", "apk_sha256": expected_hash, "cycles": args.cycles, "fixture": args.fixture,
              "scope": "Actual Quest XR/native first-pair and close/reopen transitions; not sustained FPS or lens-quality acceptance"}
    try:
        adb("shell", "am", "force-stop", package)
        adb("shell", "am", "broadcast", "-a", "com.oculus.vrpowermanager.prox_close")
        adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
        adb("shell", "am", "start", "-n", package + "/com.godot.game.GodotAppLauncher", "-a", "android.intent.action.MAIN",
            "-c", "com.oculus.intent.category.VR", "-c", "org.khronos.openxr.intent.category.IMMERSIVE_HMD")
        time.sleep(8)
        caps = read("capabilities_latest.json")
        save("startup-capabilities.json", caps)
        if caps.get("xr", {}).get("view_count") != 2 or not caps["xr"].get("passthrough_supported"):
            raise RuntimeError("Quest XR passthrough unavailable")
        command("first-alpha", "open", True)
        for index in range(args.cycles):
            command(f"{index:02}-close", "close")
            command(f"{index:02}-normal", "open", False)
            command(f"{index:02}-alpha", "alpha", True)
        command("final-close", "close")
        result["state"] = "passed"
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        save("model-readiness.json", readiness)
        events = adb("exec-out", "run-as", package, "cat", "files/diagnostics/events.jsonl")
        (args.out / "events.jsonl").write_bytes(events)
        pid = adb("shell", "pidof", package).decode().strip()
        if pid:
            log = adb("logcat", "-d", "--pid=" + pid, "-v", "threadtime")
            (args.out / "logcat.txt").write_bytes(log)
            if any(token in log for token in (b"SCRIPT ERROR:", b"SHADER ERROR:", b"FATAL EXCEPTION:", b'"event":"mpv_error"')):
                result.update(state="failed", error="Current process reported a playback/script/shader/crash error")
        save("result.json", result)
        adb("shell", "am", "broadcast", "-a", "com.oculus.vrpowermanager.automation_disable")
    if result["state"] != "passed":
        raise RuntimeError(result)


if __name__ == "__main__":
    main()
