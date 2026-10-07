"""Compare sparse, first-paused MPV FBO pixels against an independent decoder.

This checks orientation/colour and actual FBO contents for synthetic fixtures.
It does not establish a general render-to-source-PTS contract.
"""
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
BYTE_LIMIT = 8  # 8-bit renderer/chroma rounding; fixed before device execution.

def bilinear(plane, x, y):
    x = np.clip(x, 0, plane.shape[1] - 1)
    y = np.clip(y, 0, plane.shape[0] - 1)
    x0, y0 = int(x), int(y)
    x1, y1 = min(x0 + 1, plane.shape[1] - 1), min(y0 + 1, plane.shape[0] - 1)
    dx, dy = x - x0, y - y0
    return ((plane[y0, x0] * (1-dx) + plane[y0, x1] * dx) * (1-dy) +
            (plane[y1, x0] * (1-dx) + plane[y1, x1] * dx) * dy)


def verify(report: dict, ffmpeg: str) -> dict:
    fixture = report["fixture"]
    if fixture not in {"c03_sbs_grid", "c04_alpha_f180", "c04_independent_alpha"}:
        raise ValueError("Unknown diagnostic fixture")
    if report["source_pts_verified"] or report["godot_context_shared"]:
        raise ValueError("This public render API probe cannot certify source PTS or Godot sharing")
    width, height = report["fbo_width"], report["fbo_height"]
    if (width, height) != ((1920, 1080) if fixture == "c03_sbs_grid" else (1280, 640)):
        raise ValueError("Fixture/FBO dimensions differ")
    source = ROOT / "app" / "godot" / "media" / f"{fixture}.mp4"
    metadata = json.loads(subprocess.check_output([
        str(Path(ffmpeg).with_name("ffprobe.exe")), "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=color_space,color_range,chroma_location", "-of", "json", str(source)
    ]))["streams"][0]
    if metadata != {"color_range": "tv", "color_space": "bt709", "chroma_location": "left"}:
        raise ValueError("Only explicitly tagged BT709/limited/left-chroma YUV420 fixtures are supported")
    # This is decoded MPV video-params, not the original bitstream metadata.
    # MPV csputils.c names PL_CHROMA_LEFT "mpeg2/4/h264" and CENTER "mpeg1/jpeg".
    # MediaCodec/AImageReader on this Quest reports centre; preserve and quantify
    # that difference instead of claiming software/hardware source colour equality.
    expected_chroma = "mpeg1/jpeg" if report["requested_hardware"] else "mpeg2/4/h264"
    if (report["source_colormatrix"] != "bt.709" or report["source_colorlevels"] != "limited" or
            report["source_chroma_location"] != expected_chroma or report["cscale"] != "bilinear" or report["flip_y"] != 0):
        raise ValueError("MPV source/render settings differ from the independent YUV reference")
    raw = subprocess.check_output([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(source),
        "-frames:v", "1", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1",
    ])
    size = width * height
    data = np.frombuffer(raw, np.uint8).astype(np.float64)
    if data.size != size * 3 // 2:
        raise ValueError("Expected a complete independent YUV420 frame")
    luma = data[:size].reshape(height, width)
    cb = data[size:size*5//4].reshape(height//2, width//2)
    cr = data[size*5//4:].reshape(height//2, width//2)
    samples = report["first_paused_samples"]
    expected_points = {(width * xp // 100, height * yp // 100)
                       for yp in (20, 50, 80) for xp in (8, 25, 42, 58, 75, 92)}
    if len(samples) != 18 or {(s["x"], s["y"]) for s in samples} != expected_points:
        raise ValueError("Incomplete/duplicate sparse sample positions")
    comparisons = []
    maximum = 0
    bitstream_maximum = 0
    passed = True
    for sample in samples:
        x, y = sample["x"], sample["y"]
        Y = (luma[y, x] - 16) / 219
        # H.264 left chroma: horizontal cosited, vertical centred 4:2:0.
        chroma_x = x/2 - (.25 if report["requested_hardware"] else 0)
        U = (bilinear(cb, chroma_x, y/2-.25) - 128) / 224
        V = (bilinear(cr, chroma_x, y/2-.25) - 128) / 224
        expected = np.clip(np.rint(np.array([Y+1.5748*V, Y-.187324*U-.468124*V, Y+1.8556*U])*255),
                           0, 255).astype(np.int16)
        actual = np.asarray(sample["rgba"][:3], np.int16)
        error = int(np.abs(actual - expected).max())
        bitstream_U = (bilinear(cb, x/2, y/2-.25) - 128) / 224
        bitstream_V = (bilinear(cr, x/2, y/2-.25) - 128) / 224
        bitstream_rgb = np.clip(np.rint(np.array([Y+1.5748*bitstream_V,
            Y-.187324*bitstream_U-.468124*bitstream_V, Y+1.8556*bitstream_U])*255), 0, 255).astype(np.int16)
        bitstream_error = int(np.abs(actual-bitstream_rgb).max())
        bitstream_maximum = max(bitstream_maximum, bitstream_error)
        maximum = max(maximum, error)
        passed &= error <= BYTE_LIMIT and sample["rgba"][3] == 255
        comparisons.append({**sample, "expected_rgb": expected.tolist(), "max_abs_bytes": error,
            "bitstream_left_chroma_rgb": bitstream_rgb.tolist(), "bitstream_max_abs_bytes": bitstream_error})
    return {
        "schema_version": 1, "state": "passed" if passed else "failed",
        "fixture": fixture, "requested_hardware": report["requested_hardware"],
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "source_reference": "Independent FFmpeg YUV420, MPV decoded chroma metadata, bilinear, BT709 limited",
        "bitstream_chroma": metadata["chroma_location"], "mpv_decoded_chroma": report["source_chroma_location"],
        "bitstream_chroma_differs": report["requested_hardware"],
        "bitstream_reference_max_abs_bytes": bitstream_maximum,
        "samples": comparisons, "max_abs_bytes": maximum, "limit_bytes": BYTE_LIMIT,
        "scope": "Sparse FBO vs MPV decoded chroma reference; source/software-hardware colour equality and precise PTS unverified",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--ffmpeg", default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    result = verify(json.loads(args.report.read_text(encoding="utf-8-sig")), args.ffmpeg)
    destination = args.report.with_name(args.report.stem + "_pixels_yuv.json")
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}, ensure_ascii=False))
    raise SystemExit(0 if result["state"] == "passed" else 1)


if __name__ == "__main__":
    main()
