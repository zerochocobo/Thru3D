"""Compare actual production Quest seeks using fresh debug receipts and source PTS."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import statistics
import subprocess
import time
import uuid

PACKAGE = "com.wapok.thru3d"


class Device:
    def __init__(self, adb, serial, output):
        self.adb, self.serial, self.output = adb, serial, output
        self.process = None

    def run(self, *args, optional=False):
        p = subprocess.run([self.adb, "-s", self.serial, *map(str, args)], capture_output=True,
                           encoding="utf-8", errors="replace", timeout=35)
        if p.returncode and not optional:
            raise RuntimeError(p.stderr + p.stdout)
        return p.stdout if p.returncode == 0 else ""

    def read(self, filename):
        text = self.run("shell", "run-as", PACKAGE, "cat", "files/diagnostics/" + filename, optional=True)
        try:
            return json.loads(text)
        except ValueError:
            return None

    def request(self, label, operation, **extras):
        key = "seek_" + uuid.uuid4().hex
        args = ["shell", "am", "broadcast", "-n", PACKAGE + "/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",
                "-a", PACKAGE + ".DEBUG_PLAYER_MPV", "--es", "request", key, "--es", "operation", operation]
        for name, value in extras.items():
            flag = "--ez" if isinstance(value, bool) else "--ei" if isinstance(value, int) else "--es"
            args += [flag, name, str(value).lower() if isinstance(value, bool) else str(value)]
        self.run(*args)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            receipt = self.read("debug_request_" + key + ".json")
            if receipt:
                break
            time.sleep(.1)
        else:
            raise TimeoutError("No request receipt: " + label)
        if receipt.get("state") != "accepted" or receipt.get("request") != key:
            raise RuntimeError("Rejected request: " + str(receipt))
        if self.process and receipt["diagnostic_process"] != self.process:
            raise RuntimeError("App process changed; cannot combine this run")
        self.process = receipt["diagnostic_process"]
        (self.output / (label + "-receipt.json")).write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        return receipt

    def wait(self, label, receipt, condition, timeout=60):
        deadline = time.monotonic() + timeout
        report = None
        while time.monotonic() < deadline:
            report = self.read(f"mpv_player_{receipt['id']}.json")
            if report and sum(c["request_key"] == receipt["request"] for c in report["commands"]) == 1:
                if report["media"]["state"] == "failed":
                    raise RuntimeError("Player failed: " + str(report["native_status"]))
                if condition(report):
                    (self.output / (label + "-report.json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
                    return report
            time.sleep(.12)
        (self.output / (label + "-timeout.json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
        raise TimeoutError("Report timeout: " + label)

    def seek(self, label, target_ms, mode):
        receipt = self.request(label, "seek", position_ms=target_ms, seek_mode=mode)
        report = self.wait(label, receipt, lambda r: r["layout"]["playback_control"]["state"] == "idle"
                           and not r["layout"]["frame_hold"]["frozen"]
                           and r["layout"]["playback_control"]["target_ms"] == target_ms
                           and r["native_status"].get("session_id") == r["media"]["session_id"])
        trace = report["seek_trace"]
        start = max(i for i, event in enumerate(trace) if event["stage"] == "requested")
        trace = trace[start:]
        stages = {event["stage"]: event for event in trace}
        if "target_presented" not in stages:
            raise RuntimeError("No new frame binding")
        actual = report["media"]["presentation_identity"]
        if not actual["source_pts_verified"] or report["native_status"]["details"]["hwdec_current"] != "mediacodec":
            raise RuntimeError("No verified hardware-decoded source PTS")
        if report["diagnostic_2d"]:
            raise RuntimeError("Not the normal VR entry")
        actual_ms = actual["pts_us"] / 1000
        if abs(report["layout"]["playback_control"]["observed_position_ms"] - actual_ms) > 2:
            raise RuntimeError("Timeline does not confirm the actual landed PTS")
        row = {"mode": mode, "target_ms": target_ms, "actual_ms": actual_ms,
               "error_ms": actual_ms - target_ms,
               "request_to_bind_ms": stages["target_presented"]["time_ms"] - stages["requested"]["time_ms"],
               "request_to_freeze_ms": stages["frozen"]["time_ms"] - stages["requested"]["time_ms"],
               "submit_to_bind_ms": stages["target_presented"]["time_ms"] - stages["seek_started"]["time_ms"],
               "freeze_copy_us": stages["frozen"]["freeze_copy_us"],
               "source_epoch": actual["source_epoch"], "generation": actual["generation"],
               "native_seek_mode": report["native_status"].get("seek_mode"), "receipt": receipt["request"]}
        if mode == "exact" and abs(row["error_ms"]) > 34:
            raise RuntimeError("Exact seek is not at the requested frame: " + str(row))
        return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--fixture", default="mp08_8k_high_30")
    parser.add_argument("--uri-file", type=Path, help="Authorized actual network video JSON with uri/title")
    parser.add_argument("--packets", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    device = Device(args.adb, args.serial, args.output)
    installed = device.run("shell", "pm", "path", PACKAGE).strip().removeprefix("package:")
    installed_sha = device.run("shell", "sha256sum", installed).split()[0]
    if installed_sha != hashlib.sha256(args.apk.read_bytes()).hexdigest():
        raise RuntimeError("Installed APK is not the test package")
    packet_data = json.loads(args.packets.read_text(encoding="utf-8-sig"))
    keys = sorted({float(p["pts_time"]) for p in packet_data["packets"] if "K" in p.get("flags", "")})
    intervals = [(a, b) for a, b in zip(keys, keys[1:]) if 4 <= b-a <= 6]
    intervals = [intervals[1], intervals[-2]]
    cases = [{"gop_start_ms": round(a*1000), "gop_end_ms": round(b*1000), "fraction": fraction,
              "target_ms": round((a+(b-a)*fraction)*1000)} for a, b in intervals for fraction in (.02, .5, .9)]
    result = {"state": "running", "apk_sha256": installed_sha, "serial": args.serial, "cases": cases,
              "scope": "Normal Quest VR production decode, GPU freeze and verified source-frame/Godot binding; not physical-controller feel or compositor timing",
              "rows": []}
    save = lambda: (args.output / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    save()
    try:
        source = {"fixture": args.fixture}
        if args.uri_file:
            entry = json.loads(args.uri_file.read_text(encoding="utf-8-sig"))
            source = {"uri": entry["uri"], "title": entry.get("title", "network_seek_test")}
        result["source"] = source
        receipt = device.request("open", "open", **source, enabled=False, stereo=True, profile="320x320", seek_mode="speed")
        device.wait("open", receipt, lambda r: r["media"]["frame_counter"] >= 2 and r["media"]["format"].get("width") == 8192)
        receipt = device.request("pause", "playing", enabled=False)
        device.wait("pause", receipt, lambda r: r["native_status"]["details"].get("paused") == "yes")
        schedule = [(case, repeat) for repeat in range(args.repeats) for case in cases]
        random.Random(20261008).shuffle(schedule)
        for index, (case, repeat) in enumerate(schedule):
            for mode in (("speed", "exact") if index % 2 == 0 else ("exact", "speed")):
                origin = 27000 if case["target_ms"] < 15000 else 3000
                device.seek(f"origin-{index}-{mode}", origin, "speed")
                label = f"seek-{index}-{mode}"
                row = case | {"repeat": repeat+1} | device.seek(label, case["target_ms"], mode)
                if mode == "speed" and abs(row["actual_ms"] - case["gop_start_ms"]) > 34:
                    raise RuntimeError("Keyframe mode did not land at its indexed keyframe: " + str(row))
                result["rows"].append(row)
                save()
            print(json.dumps({"pair": index+1, "total_pairs": len(schedule), "last": result["rows"][-2:]}), flush=True)
        result["diagnostic_process"] = device.process
        result["summary"] = {mode: {"count": len(rows := [r for r in result["rows"] if r["mode"] == mode]),
            "median_ms": statistics.median(r["request_to_bind_ms"] for r in rows),
            "max_ms": max(r["request_to_bind_ms"] for r in rows),
            "max_abs_error_ms": max(abs(r["error_ms"]) for r in rows)} for mode in ("speed", "exact")}
        result["state"] = "passed"
        print(json.dumps(result["summary"]), flush=True)
    except BaseException as error:
        result["state"] = "failed"; result["error"] = str(error); raise
    finally:
        save()


if __name__ == "__main__":
    main()
