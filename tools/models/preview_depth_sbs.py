"""PC preview of realtime 2D->3D: the frozen depth graph, the runtime's near-map band
(native/rvm/depth_runtime_jni.cpp) and the shader's per-eye inverse warp
(app/godot/shaders/video_rvm_pair.gdshader), written as near map + flat SBS images.

Usage: python tools/models/preview_depth_sbs.py frame.png [--strength 1.0] [--out build/depth/preview]
"""
import argparse
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SHIFT, CONVERGENCE = 0.035, 0.35  # shader defaults: depth_shift per strength 1.0, depth_convergence


def near_map(session, rgb, width, height):
    src = np.asarray(Image.fromarray(rgb).resize((width, height), Image.BILINEAR), np.float32).transpose(2, 0, 1)[None] / 255
    depth = session.run(None, {'src': src})[0][0, 0]
    sample = np.sort(depth[1::3, 1::3].ravel())
    lo, hi = sample[int(0.02 * (sample.size - 1))], sample[int(0.98 * (sample.size - 1))]
    return np.clip((depth - lo) / max(1e-6, hi - lo), 0, 1)


def sample_bilinear(image, x, y):
    h, w = image.shape[:2]
    x = np.clip(x, 0, w - 1); y = np.clip(y, 0, h - 1)
    x0 = np.floor(x).astype(int); x1 = np.minimum(x0 + 1, w - 1); fx = (x - x0)[..., None] if image.ndim == 3 else x - x0
    y0 = np.floor(y).astype(int); y1 = np.minimum(y0 + 1, h - 1); fy = (y - y0)[..., None] if image.ndim == 3 else y - y0
    top = image[y0, x0] * (1 - fx) + image[y0, x1] * fx
    bottom = image[y1, x0] * (1 - fx) + image[y1, x1] * fx
    return top * (1 - fy) + bottom * fy


def eye(rgb, near, side, shift):
    h, w = rgb.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    u, v = (xs + 0.5) / w, (ys + 0.5) / h
    nh, nw = near.shape
    p = u.copy()
    for _ in range(3):  # same fixed point as depth_parallax()
        n = sample_bilinear(near, p * nw - 0.5, v * nh - 0.5)
        p = u - side * (n - CONVERGENCE) * shift * 0.5
    return sample_bilinear(rgb.astype(np.float32), p * w - 0.5, v * h - 0.5).astype(np.uint8)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('frame')
    parser.add_argument('--strength', type=float, default=1.0)
    parser.add_argument('--model', default=str(ROOT / 'build/depth/depth_252x140.onnx'))
    parser.add_argument('--out', default=str(ROOT / 'build/depth/preview'))
    args = parser.parse_args()
    session = ort.InferenceSession(args.model, providers=['CPUExecutionProvider'])
    _, _, height, width = session.get_inputs()[0].shape
    rgb = np.asarray(Image.open(args.frame).convert('RGB'))
    near = near_map(session, rgb, width, height)
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    stem = Path(args.frame).stem
    Image.fromarray((near * 255).astype(np.uint8)).resize((rgb.shape[1], rgb.shape[0]), Image.BILINEAR).save(out / f'{stem}_near.png')
    shift = SHIFT * args.strength
    sbs = np.concatenate([eye(rgb, near, 1.0, shift), eye(rgb, near, -1.0, shift)], axis=1)
    Image.fromarray(sbs).save(out / f'{stem}_sbs.jpg', quality=90)
    print(out / f'{stem}_sbs.jpg')


if __name__ == '__main__':
    main()
