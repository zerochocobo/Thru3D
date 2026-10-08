"""Measure real Windows MPV seek/restart latency and landing error on local files.

Uses MPV's JSON named-pipe IPC, not FFmpeg decoding timings. Playback is paused,
audio and sidecar discovery are disabled. The endpoint is playback-restart plus
MPV time-pos, not the Quest compositor or this application's frame bridge.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import threading
import time
import uuid


def run_text(command):
    return subprocess.check_output(command, text=True, encoding="utf-8", errors="replace")


def probe_media(ffprobe, path):
    return json.loads(run_text([ffprobe, "-v", "error", "-show_entries",
        "stream=index,codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,bit_rate:format=duration,size,bit_rate",
        "-of", "json", str(path)]))


def make_cases(ffprobe, path, duration, anchors):
    cases, intervals = [], []
    for anchor_index in range(anchors):
        fraction = (anchor_index + 1) / (anchors + 1)
        start = duration * fraction
        packets = json.loads(run_text([ffprobe, "-v", "error", "-select_streams", "v:0",
            "-read_intervals", f"{start:.3f}%+24", "-show_packets", "-show_entries",
            "packet=pts_time,flags", "-of", "json", str(path)]))["packets"]
        keys = sorted({float(p["pts_time"]) for p in packets if "K" in p.get("flags", "")})
        pairs = [(a, b) for a, b in zip(keys, keys[1:]) if 0.5 <= b-a <= 30]
        if not pairs:
            raise ValueError(f"No usable keyframe interval near {start:.3f}s")
        # Choose a complete, non-tiny GOP near this anchor; retain packet evidence.
        left, right = min(pairs, key=lambda p: abs(p[0]-start))
        intervals.append({"anchor_seconds": start, "keyframes_seconds": keys,
                          "selected_start": left, "selected_end": right})
        for label, offset_fraction in (("near", 0.02), ("middle", 0.5), ("late", 0.9)):
            target = left + (right-left) * offset_fraction
            index = len(cases)
            origin = target + (35 if index % 2 else -35)
            origin = min(duration-10, max(10, origin))
            cases.append({"case": f"anchor{anchor_index+1}_{label}", "target_seconds": target,
                "origin_seconds": origin, "direction": "backward" if origin > target else "forward",
                "gop_start_seconds": left, "gop_end_seconds": right,
                "gop_seconds": right-left, "target_gop_fraction": offset_fraction})
    return cases, intervals


class Mpv:
    def __init__(self, executable, output, hwdec, cache_profile, timeout, gpu=False):
        self.timeout, self.counter = timeout, 0
        self.events, self.responses = [], {}
        self.condition = threading.Condition()
        self.pipe = None
        self.process = None
        self.reader_error = None
        self.output = output
        self.args = [str(executable), "--no-config", "--load-scripts=no", "--terminal=no",
            "--idle=yes", "--keep-open=yes", "--pause=yes", "--audio=no", "--sub-auto=no",
            "--audio-file-auto=no", "--autoload-files=no", "--sub=no", "--osc=no", "--osd-level=0",
            "--input-default-bindings=no", "--input-vo-keyboard=no", "--hwdec-codecs=all",
            f"--hwdec={hwdec}", "--demuxer-max-bytes=256MiB", "--msg-level=all=warn",
            f"--log-file={output / 'mpv.log'}"]
        self.args += (["--cache=no", "--demuxer-readahead-secs=1", "--demuxer-seekable-cache=no"]
                      if cache_profile == "isolated" else
                      ["--cache=auto", "--demuxer-readahead-secs=20"])
        if gpu:
            # An invisible window owned by this harness; MPV renders into its child.
            # This measures MPV GPU output readiness, not desktop/compositor visibility.
            self.window = HiddenWindow()
            self.args += ["--vo=gpu", "--gpu-api=d3d11", "--gpu-context=d3d11",
                f"--wid={self.window.handle}", "--d3d11-sync-interval=0", "--gpu-dumb-mode=yes",
                "--scale=bilinear", "--cscale=bilinear", "--dscale=bilinear", "--dither=no"]
        else:
            self.window = None
            self.args += ["--vo=null"]
        name = "vrpp_seek_bench_" + uuid.uuid4().hex
        self.args += ["--input-ipc-server=" + name]
        output.mkdir(parents=True, exist_ok=True)
        self.process = subprocess.Popen(self.args, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(f"MPV exited with {self.process.returncode}; see {output / 'mpv.log'}")
                try:
                    self.pipe = open("\\\\.\\pipe\\" + name, "r+b", buffering=0)
                    break
                except OSError:
                    time.sleep(0.05)
            if self.pipe is None:
                raise TimeoutError("MPV named pipe did not become ready")
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
        except BaseException:
            self.close()
            raise

    def _read(self):
        import ctypes
        import msvcrt
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.PeekNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
            wintypes.LPVOID, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        kernel.PeekNamedPipe.restype = wintypes.BOOL
        handle = msvcrt.get_osfhandle(self.pipe.fileno())
        available = wintypes.DWORD()
        pending = b""
        try:
            while True:
                # Do not leave a blocking synchronous ReadFile outstanding on a
                # duplex handle: Windows would serialize a concurrent write behind it.
                if not kernel.PeekNamedPipe(handle, None, 0, None, ctypes.byref(available), None):
                    break
                if not available.value:
                    time.sleep(0.001)
                    continue
                chunk = self.pipe.read(min(65536, available.value))
                if not chunk:
                    break
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if not line:
                        continue
                    stamp = time.perf_counter_ns()
                    message = json.loads(line)
                    with self.condition:
                        if "request_id" in message:
                            self.responses[message["request_id"]] = (stamp, message)
                        elif "event" in message:
                            self.events.append((stamp, message))
                        self.condition.notify_all()
        except BaseException as error:
            with self.condition:
                self.reader_error = str(error)
                self.condition.notify_all()

    def command(self, *command, optional=False):
        with self.condition:
            self.counter += 1
            request_id = self.counter
            sent = time.perf_counter_ns()
            self.pipe.write((json.dumps({"command": command, "request_id": request_id}) + "\n").encode())
            deadline = time.monotonic() + self.timeout
            while request_id not in self.responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self.reader_error:
                    raise TimeoutError(f"MPV command {command[0]} timed out: {self.reader_error}")
                self.condition.wait(remaining)
            received, reply = self.responses.pop(request_id)
            if reply["error"] != "success" and not optional:
                raise RuntimeError(f"MPV rejected {command}: {reply}")
            return sent, received, reply.get("data")

    def prop(self, name, optional=False):
        return self.command("get_property", name, optional=optional)[2]

    def event(self, name, after):
        with self.condition:
            deadline = time.monotonic() + self.timeout
            while True:
                for stamp, message in self.events:
                    if stamp >= after and message["event"] == name:
                        return stamp, message
                    if stamp >= after and message["event"] == "end-file" and message.get("reason") == "error":
                        raise RuntimeError(f"MPV media failure: {message}")
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self.reader_error:
                    raise TimeoutError(f"No {name} event: {self.reader_error}")
                self.condition.wait(remaining)

    def load(self, path):
        sent, replied, _ = self.command("loadfile", str(path), "replace")
        loaded, _ = self.event("file-loaded", sent)
        ready, _ = self.event("playback-restart", loaded)
        return {"command_reply_ms": (replied-sent)/1e6, "file_loaded_ms": (loaded-sent)/1e6,
                "restart_ms": (ready-sent)/1e6, "hwdec_current": self.prop("hwdec-current"),
                "video_params": self.prop("video-params"), "time_pos": self.prop("time-pos")}

    def seek(self, target, strategy):
        sent, replied, _ = self.command("seek", target, "absolute+" + strategy)
        seek, _ = self.event("seek", sent)
        ready, _ = self.event("playback-restart", seek)
        actual = self.prop("time-pos")
        if not self.prop("pause") or self.prop("seeking") or actual is None:
            raise RuntimeError("Seek did not finish at a stable paused position")
        return {"command_reply_ms": (replied-sent)/1e6, "request_to_seek_event_ms": (seek-sent)/1e6,
            "request_to_restart_ms": (ready-sent)/1e6, "seek_to_restart_ms": (ready-seek)/1e6,
            "actual_seconds": actual, "landing_error_seconds": actual-target,
            "hwdec_current": self.prop("hwdec-current"),
            "frame_info": self.prop("video-frame-info", optional=True)}

    def close(self):
        if self.process is not None:
            if self.pipe is not None and self.process.poll() is None:
                try:
                    self.pipe.write(b'{"command":["quit"]}\n')
                except OSError:
                    pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
        if self.pipe is not None:
            self.pipe.close()
        if getattr(self, "window", None) is not None:
            self.window.close()


class HiddenWindow:
    def __init__(self):
        import ctypes
        from ctypes import wintypes
        self.ctypes = ctypes
        self.ready, self.finished = threading.Event(), threading.Event()
        self.handle, self.error = None, None
        def loop():
            user = ctypes.WinDLL("user32", use_last_error=True)
            user.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR,
                wintypes.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, wintypes.LPVOID]
            user.CreateWindowExW.restype = wintypes.HWND
            self.handle = user.CreateWindowExW(0, "STATIC", "MPV seek benchmark", 0,
                0, 0, 640, 360, None, None, None, None)
            if not self.handle:
                self.error = ctypes.get_last_error()
            self.ready.set()
            msg = wintypes.MSG()
            while self.handle and not self.finished.is_set():
                while user.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):
                    user.TranslateMessage(ctypes.byref(msg))
                    user.DispatchMessageW(ctypes.byref(msg))
                self.finished.wait(0.01)
            if self.handle:
                user.DestroyWindow.argtypes = [wintypes.HWND]
                user.DestroyWindow(self.handle)
        self.thread = threading.Thread(target=loop, daemon=True)
        self.thread.start()
        if not self.ready.wait(5) or self.error:
            raise RuntimeError(f"Could not create invisible benchmark parent: {self.error}")

    def close(self):
        self.finished.set()
        self.thread.join(5)


def summary(rows):
    output = {}
    for strategy in ("exact", "keyframes"):
        selected = [r for r in rows if r["strategy"] == strategy]
        latency = [r["request_to_restart_ms"] for r in selected]
        errors = [abs(r["landing_error_seconds"]) for r in selected]
        output[strategy] = {"count": len(selected), "median_ms": statistics.median(latency),
            "mean_ms": statistics.mean(latency), "max_ms": max(latency),
            "median_abs_error_seconds": statistics.median(errors), "max_abs_error_seconds": max(errors)}
    output["median_ratio"] = output["exact"]["median_ms"] / output["keyframes"]["median_ms"]
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media-dir", required=True, type=Path)
    parser.add_argument("--mpv", required=True, type=Path)
    parser.add_argument("--ffprobe", default="ffprobe.exe")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--hwdec", default="d3d11va-copy")
    parser.add_argument("--gpu", action="store_true")
    parser.add_argument("--cache-profile", choices=("isolated", "application"), default="isolated")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--anchors", type=int, default=3)
    parser.add_argument("--files", type=int, default=0, help="Limit number of inputs for a pilot")
    parser.add_argument("--timeout", type=float, default=40)
    args = parser.parse_args()
    if os.name != "nt" or args.repeats < 1 or args.anchors < 1:
        parser.error("Windows, positive repeats and anchors are required")
    args.output.mkdir(parents=True, exist_ok=True)
    videos = sorted(args.media_dir.glob("*.mp4"))
    if args.files:
        videos = videos[:args.files]
    if not videos:
        parser.error("No MP4 files found")
    result = {"state": "running", "mpv_version": run_text([str(args.mpv.with_suffix('.com'))
              if args.mpv.with_suffix('.com').exists() else str(args.mpv), "--version"]),
              "mpv_sha256": hashlib.sha256(args.mpv.read_bytes()).hexdigest(),
              "settings": vars(args) | {"media_dir": str(args.media_dir), "mpv": str(args.mpv), "output": str(args.output)},
              "endpoint": "host IPC send to MPV playback-restart, then paused time-pos; not compositor visibility",
              "os_file_cache": "not flushed; matched interleaved strategy order",
              "files": []}
    write = lambda: (args.output / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    write()
    try:
        for index, path in enumerate(videos, 1):
            meta = probe_media(args.ffprobe, path)
            video = next(s for s in meta["streams"] if "width" in s)
            if video["width"] < 7680:
                raise ValueError(f"Input is not 8K: {path.name}")
            cases, intervals = make_cases(args.ffprobe, path, float(meta["format"]["duration"]), args.anchors)
            entry = {"file": str(path), "size": path.stat().st_size,
                     "mtime_ns": path.stat().st_mtime_ns, "metadata": meta,
                     "intervals": intervals, "cases": cases, "rows": []}
            result["files"].append(entry)
            print(json.dumps({"file_index": index, "state": "starting", "cases": len(cases),
                              "gop_seconds": [x["selected_end"]-x["selected_start"] for x in intervals]}), flush=True)
            mpv = Mpv(args.mpv, args.output / f"file{index}", args.hwdec, args.cache_profile, args.timeout, args.gpu)
            entry["mpv_arguments"] = mpv.args
            try:
                entry["open"] = mpv.load(path)
                if args.hwdec != "no" and entry["open"]["hwdec_current"] != args.hwdec:
                    raise RuntimeError(f"Hardware decoding fell back: {entry['open']}")
                if (entry["open"]["video_params"]["w"], entry["open"]["video_params"]["h"]) != (video["width"], video["height"]):
                    raise RuntimeError("MPV did not decode the full source resolution")
                schedule = [(case, repeat) for repeat in range(args.repeats) for case in cases]
                random.Random(20261008 + index).shuffle(schedule)
                with (args.output / f"file{index}" / "rows.jsonl").open("w", encoding="utf-8") as records:
                    for trial, (case, repeat) in enumerate(schedule):
                        strategies = ["exact", "keyframes"] if trial % 2 == 0 else ["keyframes", "exact"]
                        for strategy in strategies:
                            mpv.seek(case["origin_seconds"], "keyframes")
                            time.sleep(0.10)
                            before = mpv.prop("time-pos")
                            row = case | {"repeat": repeat+1, "strategy": strategy,
                                "origin_actual_seconds": before} | mpv.seek(case["target_seconds"], strategy)
                            if row["hwdec_current"] != entry["open"]["hwdec_current"]:
                                raise RuntimeError("Decoder changed during the run")
                            if strategy == "exact" and abs(row["landing_error_seconds"]) > 0.05:
                                raise RuntimeError(f"Exact seek landed too far from target: {row}")
                            entry["rows"].append(row)
                            records.write(json.dumps(row) + "\n")
                            records.flush()
                        if (trial+1) % 3 == 0:
                            print(json.dumps({"file_index": index, "paired_trials": trial+1,
                                              "total_pairs": len(schedule)}), flush=True)
                entry["summary"] = summary(entry["rows"])
                print(json.dumps({"file_index": index, "summary": entry["summary"]}), flush=True)
                if path.stat().st_size != entry["size"] or path.stat().st_mtime_ns != entry["mtime_ns"]:
                    raise RuntimeError("Source changed during benchmark")
            finally:
                mpv.close()
                write()
        result["state"] = "passed"
    except BaseException as error:
        result["state"] = "failed"
        result["error"] = str(error)
        raise
    finally:
        write()


if __name__ == "__main__":
    main()
