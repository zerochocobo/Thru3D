"""Exercise the production MPV Source with private, never-packaged media.

The paced phase performs no pixel readback. PTS/epoch/flags, hardware backend,
frame coverage, EOF and seek are checked independently from the app's verdict.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "com.wapok.thru3d"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("fixture", type=Path)
    p.add_argument("--serial", required=True)
    p.add_argument("--adb", default="adb")
    p.add_argument("--name", default="profile5")
    p.add_argument("--direct", action="store_true")
    p.add_argument("--audio", action="store_true")
    p.add_argument("--software", action="store_true")
    p.add_argument("--pixels-only", action="store_true")
    p.add_argument("--profile5", action="store_true")
    p.add_argument("--apk", type=Path)
    args = p.parse_args()
    key = "dovi_" + uuid.uuid4().hex
    output = ROOT / "artifacts/dovi-player/device" / (args.name + "_" + key)
    output.mkdir(parents=True)
    name = "dovi_profile5.mkv" if args.profile5 else "regression" + args.fixture.suffix.lower()
    remote = "/data/local/tmp/" + key + args.fixture.suffix.lower()
    adb = [args.adb, "-s", args.serial]
    def run(*cmd):
        return subprocess.check_output(adb + list(cmd), stderr=subprocess.STDOUT)
    def read(name):
        try:
            return json.loads(run("exec-out", "run-as", PACKAGE, "cat", "files/diagnostics/" + name))
        except (subprocess.CalledProcessError, ValueError):
            return None
    try:
        installed_path = run("shell", "pm", "path", PACKAGE).decode().strip().split('package:', 1)[1]
        installed_hash = run("shell", "sha256sum", installed_path).decode().split()[0]
        if args.apk:
            assert installed_hash == hashlib.sha256(args.apk.read_bytes()).hexdigest(), 'Installed APK differs'
        (output / 'installed.json').write_text(json.dumps({'apk_sha256': installed_hash, 'serial': args.serial}, indent=2))
        run("shell", "am", "force-stop", PACKAGE)
        run("push", str(args.fixture.resolve()), remote)
        run("shell", "run-as", PACKAGE, "mkdir", "-p", "files/fixtures")
        run("shell", "run-as", PACKAGE, "cp", remote, "files/fixtures/" + name)
        run("shell", "am", "broadcast", "-n", PACKAGE + "/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",
            "-a", PACKAGE + ".DEBUG_LAUNCH_2D", "--es", "request", key + "_launch")
        request = ["shell", "am", "broadcast", "-n", PACKAGE + "/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",
                   "-a", PACKAGE + ".DEBUG_MPV_DOLBY", "--es", "request", key, "--es", "fixture", name]
        for flag, enabled in (("direct", args.direct), ("audio", args.audio),
                              ("hardware", not args.software), ("pixels_only", args.pixels_only)):
            request += ["--ez", flag, str(enabled).lower()]
        (output / "broadcast.txt").write_bytes(run(*request))
        deadline = time.monotonic() + 70
        receipt = None
        while time.monotonic() < deadline:
            receipt = read("debug_request_" + key + ".json")
            if receipt:
                break
            time.sleep(0.5)
        assert receipt and receipt.get("state") == "accepted", receipt
        (output / "request.json").write_text(json.dumps(receipt, indent=2))
        report = None
        while time.monotonic() < deadline:
            candidate = read("mpv_dolby_" + str(receipt["id"]) + ".json")
            if candidate and candidate.get('diagnostic_process') == receipt['diagnostic_process']:
                report = candidate
                break
            try:
                if not run('shell', 'pidof', PACKAGE).strip():
                    break
            except subprocess.CalledProcessError:
                break
            time.sleep(0.5)
        (output / "logcat.txt").write_bytes(run("logcat", "-d", "-t", "6000", "-v", "threadtime",
            "QuestMpv:I", "QuestMpvSource:I", "AndroidRuntime:E", "libc:F", "DEBUG:F", "*:S"))
        if not report:
            (output / 'crash.txt').write_bytes(run('logcat', '-b', 'crash', '-d', '-t', '150'))
        assert report, "No terminal report"
        (output / "report.json").write_text(json.dumps(report, indent=2))
        assert report["request_id"] == receipt["id"]
        assert report["diagnostic_process"] == receipt["diagnostic_process"]
        for label in ("initial", "seek"):
            if label + "_frame" in report:
                (output / (label + ".png")).write_bytes(run("exec-out", "run-as", PACKAGE, "cat",
                    f"files/diagnostics/mpv_dolby_{receipt['id']}_{label}.png"))
        assert report["state"] == "passed_native_checks", report.get("error")
        assert run("shell", "sha256sum", installed_path).decode().split()[0] == installed_hash, 'APK changed during probe'
        assert report["source_closed"] and report["owner_closed"]
        state = report["after_playback"]
        assert not state["render_failed"] and state["invalid_frames"] == 0, state
        details = state["details"]
        assert details["hwdec_current"] == ("no" if args.software else "mediacodec"), details
        assert details.get("dolby_profile5", False) == args.profile5, details
        if args.audio and not args.pixels_only:
            clocks = [s for s in report['audio_snapshots'] if s.get('audio_clock_available')]
            assert len(clocks) >= 2 and all(s.get('audio_output') == 'aaudio' for s in clocks), 'No live audio clock'
        records = report["paced_frames"]
        for frame in records:
            assert bool(frame["source_flags"] & 32) == args.profile5, frame
            if args.profile5:
                assert frame["color_target"] == "GL_TEXTURE_2D" and "hardware_buffer" not in frame
        metrics = {}
        if not args.pixels_only:
            assert state["eof_source_resolved"]
            assert all(b["pts_us"] > a["pts_us"] for a, b in zip(records, records[1:])), "Repeated/backwards PTS"
            probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=avg_frame_rate", "-of", "json", str(args.fixture)]))
            num, den = map(int, probe["streams"][0]["avg_frame_rate"].split("/"))
            fps = num / den
            wall = report["paced_elapsed_ns"] / 1e9
            span = (records[-1]["pts_us"] - records[0]["pts_us"]) / 1e6
            metrics = {"source_fps": fps, "observed_fps": (len(records)-1) / wall,
                       "source_pts_span_s": span, "wall_span_s": wall,
                       "frame_coverage": (len(records)-1) / (span * fps)}
            assert metrics["frame_coverage"] >= 0.97, metrics
            assert metrics["observed_fps"] >= fps * 0.95, metrics
        assert report["seek_frame"]["source_epoch"] > report.get("initial_frame", report["seek_frame"])["source_epoch"] or args.direct
        verification = {"passed": True, "fixture_sha256": hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
                        "profile5": args.profile5, "software": args.software, "pixels_only": args.pixels_only,
                        "direct": args.direct, "audio": args.audio, "metrics": metrics,
                        "scope": "Production decode/render/lease path; offscreen pacing, not headset XR performance"}
        (output / "verification.json").write_text(json.dumps(verification, indent=2))
        print(json.dumps({"output": str(output), **verification}, indent=2), flush=True)
    finally:
        run("shell", "rm", "-f", remote)
        run("shell", "am", "force-stop", PACKAGE)


if __name__ == "__main__":
    main()
