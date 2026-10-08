"""Measure cold-process and warm video opens on Quest, with production stage clocks."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import statistics
import threading
import time

from mpv_seek_strategy_device import Device, PACKAGE


class MediaServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, media, rate_mib):
        self.media, self.rate = media, rate_mib * 1024 * 1024
        self.requests = []
        super().__init__(("127.0.0.1", 0), MediaHandler)


class MediaHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        if self.path != "/sample.mp4":
            self.send_error(404); return
        size = self.server.media.stat().st_size
        start, end = 0, size - 1
        value = self.headers.get("Range", "")
        if value:
            bounds = value.removeprefix("bytes=").split("-")
            if len(bounds) != 2 or not bounds[0].isdigit():
                self.send_error(416); return
            start = int(bounds[0]); end = min(int(bounds[1]) if bounds[1] else end, end)
        if not 0 <= start <= end < size:
            self.send_error(416); return
        self.send_response(206 if value else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end-start+1))
        if value:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        row = {"range": value, "start": start, "end": end, "head": not body,
               "bytes": 0, "started": time.monotonic(), "rate_mib": self.server.rate / 1024 / 1024}
        self.server.requests.append(row)
        if body:
            try:
                with self.server.media.open("rb") as source:
                    source.seek(start)
                    while row["bytes"] < end-start+1:
                        data = source.read(min(256*1024, end-start+1-row["bytes"]))
                        if not data: break
                        if self.server.rate:
                            delay = (row["bytes"]+len(data))/self.server.rate - (time.monotonic()-row["started"])
                            if delay > 0: time.sleep(delay)
                        self.wfile.write(data); row["bytes"] += len(data)
            except ConnectionError:
                row["client_closed"] = True
        row["duration_ms"] = (time.monotonic()-row["started"])*1000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("adb", "serial", "apk", "output"):
        parser.add_argument("--"+arg, required=True)
    parser.add_argument("--original", type=Path, help="Serve this original video through ADB USB loopback HTTP")
    parser.add_argument("--uri-file", type=Path, help="JSON containing uri/title for an authorized real network source")
    parser.add_argument("--rate-mib", type=float, default=0)
    parser.add_argument("--mpv-options", default=None, help="Temporary debug A/B options; restored on exit")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--first-only", action="store_true", help="Measure from the beginning with speed mode, cold and warm")
    parser.add_argument("--cases-file", type=Path, help="JSON list of cold_process/start_ms/mode cases")
    args = parser.parse_args()
    if args.original and args.uri_file: parser.error("Choose original or uri-file")
    directory = Path(args.output); directory.mkdir(parents=True, exist_ok=True)
    device = Device(args.adb, args.serial, directory)
    path = device.run("shell", "pm", "path", PACKAGE).strip().removeprefix("package:")
    sha = device.run("shell", "sha256sum", path).split()[0]
    if sha != hashlib.sha256(Path(args.apk).read_bytes()).hexdigest():
        raise RuntimeError("Installed APK differs")
    result = {"state": "running", "apk_sha256": sha, "rows": [],
              "scope": "Normal VR source-frame/Godot binding, excluding process boot before the open request and compositor; USB HTTP excludes real Wi-Fi/NAS/auth latency"}
    server = None
    options = device.run("shell", "getprop", "debug.vrpp.mpv.opts").strip()
    save = lambda: (directory / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    try:
        if args.mpv_options is not None:
            device.run("shell", "setprop", "debug.vrpp.mpv.opts", args.mpv_options)
        if args.original:
            server = MediaServer(args.original, args.rate_mib)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            port = server.server_address[1]
            device.run("reverse", f"tcp:{port}", f"tcp:{port}")
            source = {"uri": f"http://127.0.0.1:{port}/sample.mp4", "title": "startup_8k_original"}
            result["source"] = {"path": str(args.original.resolve()), "size": args.original.stat().st_size,
                "mtime_ns": args.original.stat().st_mtime_ns, "rate_mib": args.rate_mib,
                "transport": "ADB USB reverse to range-capable PC loopback HTTP; original bytes, no reencode"}
        elif args.uri_file:
            entry = json.loads(args.uri_file.read_text(encoding="utf-8-sig"))
            source = {"uri": entry["uri"], "title": entry.get("title", "network_startup_test")}
            result["source"] = {"transport": "Quest actual network HTTP/DLNA", "uri": source["uri"]}
        else:
            source = {"fixture": "mp08_8k_high_30"}
            result["source"] = {"transport": "Quest local storage", "fixture": source["fixture"]}
        cases = [(True, 0, "speed"), (False, 0, "speed")]
        if not args.first_only:
            cases += [(False, 0, "exact"), (False, 7584, "speed"), (False, 7584, "exact")]
        if args.cases_file:
            cases = []
            for case in json.loads(args.cases_file.read_text(encoding="utf-8-sig")):
                if type(case["cold_process"]) is not bool or type(case["start_ms"]) is not int or case["start_ms"] < 0 or case["mode"] not in ("speed", "exact"):
                    raise ValueError("Invalid startup case")
                cases.append((case["cold_process"], case["start_ms"], case["mode"]))
        for cold, start, mode in cases:
            for repeat in range(args.repeats):
                if cold:
                    device.run("shell", "am", "force-stop", PACKAGE); device.process = None
                    device.run("shell", "input", "keyevent", "KEYCODE_WAKEUP")
                    device.run("shell", "am", "start", "-n", PACKAGE+"/com.godot.game.GodotAppLauncher",
                        "-a", "android.intent.action.MAIN", "-c", "com.oculus.intent.category.VR",
                        "-c", "org.khronos.openxr.intent.category.IMMERSIVE_HMD")
                    time.sleep(6)
                label = f"{'cold' if cold else 'warm'}-{start}-{mode}-{repeat}"
                rec = device.request(label, "open", **source, enabled=False, stereo=True, profile="320x320",
                                     position_ms=start, seek_mode=mode)
                r = device.wait(label, rec, lambda r: any(t["stage"] == "first_pair_bound" for t in r.get("open_trace", []))
                    and r["native_status"].get("session_id") == r["media"]["session_id"]
                    and "first_pair_bound_ms" in r["native_status"].get("startup_bridge", {}))
                if r["diagnostic_2d"] or not r["media"]["presentation_identity"]["source_pts_verified"]:
                    raise RuntimeError("Not verified production VR playback")
                stages = {t["stage"]: t for t in r["open_trace"]}
                row = {"cold_process": cold, "start_ms": start, "mode": mode, "repeat": repeat,
                    "request_to_bind_ms": stages["first_pair_bound"]["time_ms"] - stages["requested"]["time_ms"],
                    "godot_dispatch_ms": stages["dispatched"]["time_ms"]-stages["requested"]["time_ms"],
                    "first_pts_us": stages["first_pair_bound"]["pts_us"],
                    "bridge": r["native_status"]["startup_bridge"], "native": r["native_status"]["startup_native"],
                    "request": rec["request"], "diagnostic_process": device.process,
                    "hwdec": r["native_status"]["details"]["hwdec_current"]}
                if row["hwdec"] != "mediacodec": raise RuntimeError("No hardware decode")
                result["rows"].append(row); save(); print(json.dumps(row), flush=True)
                rec = device.request(label+"-close", "close")
                device.wait(label+"-close", rec, lambda r: r["media"]["session_id"] <= 0)
                time.sleep(.4)
        groups = {}
        for row in result["rows"]:
            key = f"{'cold' if row['cold_process'] else 'warm'}-{row['start_ms']}-{row['mode']}"
            groups.setdefault(key, []).append(row["request_to_bind_ms"])
        result["summary"] = {k: {"median_ms": statistics.median(v), "max_ms": max(v), "count": len(v)} for k,v in groups.items()}
        result["state"] = "passed"
    except BaseException as error:
        result["state"] = "failed"; result["error"] = str(error); raise
    finally:
        if args.mpv_options is not None:
            device.run("shell", "setprop", "debug.vrpp.mpv.opts", options or "\"\"", optional=True)
        if server:
            device.run("reverse", "--remove", f"tcp:{server.server_address[1]}", optional=True)
            server.shutdown(); server.server_close(); result["http_requests"] = server.requests
        save()


if __name__ == "__main__":
    main()
