"""Offline 2D->3D simulation of the Quest pipeline on real video frames.

Mirrors the device: model input (box-averaged, letterboxed) -> depth model (frozen ONNX) ->
native DepthStabilizer (tests/native/depth_stabilizer_cli.cpp) -> forward-warp soft_shift with
the render bridge's hole fill (native/render-bridge/render_bridge.cpp warp_* shaders, in numpy).
Depth runs every --every frames and a shown frame uses the newest map whose source frame is at
least --lag frames old, as the decoupled player does.

Usage: python tools/models/simulate_depth_sbs.py <frames dir with f_001.png...> --out <dir>
       [--model build/depth/depth_252x140.onnx] [--lag 6] [--every 6] [--dilate -1] [--show 30 45]
"""
import argparse
import subprocess
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'build/depth-stabilizer-test/depth_stabilizer_cli.exe'
SHIFT, CONVERGENCE = 0.035, 0.35
BG_FILL = False
MIRROR_FILL = False
CLAMP_FILL = False
CLAMP_TOL, CLAMP_MARGIN, CLAMP_SMOOTH = 0.15, 0, 0
SNAP_PX = 6.0  # toggle-sharpen half window in full-resolution pixels (PTMediaServer _near_at)


def content_rect(W, H, w, h):
    """Model = rect.xy + eye_uv * rect.zw (render_bridge allocate())."""
    src, inp = W / H, w / h
    if src > inp:
        hh = inp / src
        return np.array([0, (1 - hh) / 2, 1, hh], np.float32)
    ww = src / inp
    return np.array([(1 - ww) / 2, 0, ww, 1], np.float32)


def model_input(rgb, w, h, rect):
    """Letterboxed box average (the bridge's 4x4 footprint average ~ area resampling)."""
    cw, ch = round(rect[2] * w), round(rect[3] * h)
    img = Image.fromarray(rgb).resize((cw, ch), Image.BOX)
    canvas = np.zeros((h, w, 3), np.uint8)
    x0, y0 = round(rect[0] * w), round(rect[1] * h)
    canvas[y0:y0 + ch, x0:x0 + cw] = np.asarray(img)
    return canvas.astype(np.float32).transpose(2, 0, 1) / 255


def near_full(near, W, H, rect, snap):
    """warp_common near_at() for every full-resolution pixel."""
    h, w = near.shape
    model = np.array([w, h], np.float32)
    lo = np.ceil(rect[:2] * model - 0.5)
    hi = np.maximum(lo, np.floor((rect[:2] + rect[2:]) * model - 0.5))
    px = np.clip((rect[0] + (np.arange(W) + 0.5) / W * rect[2]) * w - 0.5, lo[0], hi[0])
    py = np.clip((rect[1] + (np.arange(H) + 0.5) / H * rect[3]) * h - 0.5, lo[1], hi[1])
    ax, ay = np.floor(px).astype(int), np.floor(py).astype(int)
    bx, by = np.minimum(ax + 1, int(hi[0])), np.minimum(ay + 1, int(hi[1]))
    fx, fy = (px - ax)[None, :], (py - ay)[:, None]
    n = (near[ay][:, ax] * (1 - fx) + near[ay][:, bx] * fx) * (1 - fy) + (near[by][:, ax] * (1 - fx) + near[by][:, bx] * fx) * fy
    if not snap:
        return n
    win = max(1, int(np.ceil(SNAP_PX * rect[2] * w / W)))
    cols = np.arange(w)
    mn = np.full_like(near, np.inf); mx = np.full_like(near, -np.inf)
    for d in range(-win, win + 1):
        c = np.clip(cols + d, int(lo[0]), int(hi[0]))
        mn = np.minimum(mn, near[:, c]); mx = np.maximum(mx, near[:, c])
    l = np.minimum(np.minimum(mn[ay][:, ax], mn[by][:, ax]), n)
    u = np.maximum(np.maximum(mx[ay][:, ax], mx[by][:, ax]), n)
    return np.where((n - l) >= (u - n), u, l)


def box(a, r):
    """Mean over a (2r+1)^2 window, edges clamped (separable running sums)."""
    def run(x, axis):
        pad = [(0, 0)] * x.ndim; pad[axis] = (r + 1, r)
        c = np.cumsum(np.pad(x, pad, mode='edge'), axis=axis)
        hi = np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
        lo = np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)
        return (hi - lo) / (2 * r + 1)
    return run(run(a, 0), 1)


def guided(near, frame, rect, gw, gh, r, eps):
    """Snap the near map's edges to the shown frame: guided filter (He et al.) at gw x gh."""
    p = near_full(near, gw, gh, rect, False)
    I = np.asarray(Image.fromarray(frame).resize((gw, gh), Image.BOX).convert('L'), np.float64) / 255
    mI, mp = box(I, r), box(p, r)
    a = (box(I * p, r) - mI * mp) / (box(I * I, r) - mI * mI + eps)
    b = mp - a * mI
    return np.clip(box(a, r) * I + box(b, r), 0, 1).astype(np.float32)


def minmax(a, r):
    """Windowed min and max over (2r+1)^2, edges clamped (separable)."""
    def run(x, axis, f):
        out = x.copy()
        n = x.shape[axis]
        for d in range(1, r + 1):
            idx_lo = np.clip(np.arange(n) - d, 0, n - 1); idx_hi = np.clip(np.arange(n) + d, 0, n - 1)
            out = f(out, f(np.take(x, idx_lo, axis=axis), np.take(x, idx_hi, axis=axis)))
        return out
    return run(run(a, 0, np.minimum), 1, np.minimum), run(run(a, 0, np.maximum), 1, np.maximum)


def color_snap(near, frame, rect, gw, gh, r, soft):
    """Two-class colour snap: inside a depth transition, each pixel takes the near value of the
    side (local foreground or background) whose mean colour it is closer to."""
    p = near_full(near, gw, gh, rect, False).astype(np.float64)
    I = np.asarray(Image.fromarray(frame).resize((gw, gh), Image.BOX), np.float64) / 255
    lo, hi = minmax(p, r)
    span = hi - lo
    F = (p > lo + 0.75 * span) & (span > 0.15)
    B = (p < lo + 0.25 * span) & (span > 0.15)
    def mean(mask, v):
        m = box(mask.astype(np.float64), r)
        return box(v * mask, r) / np.maximum(m, 1e-6), m
    nf, wf = mean(F, p); nb, wb = mean(B, p)
    cf = np.stack([mean(F, I[..., c])[0] for c in range(3)], -1)
    cb = np.stack([mean(B, I[..., c])[0] for c in range(3)], -1)
    df = ((I - cf) ** 2).sum(-1); db = ((I - cb) ** 2).sum(-1)
    alpha = 1 / (1 + np.exp(-(db - df) / soft))
    q = alpha * nf + (1 - alpha) * nb
    use = (span > 0.15) & (wf > 0.02) & (wb > 0.02) & (p > lo + 0.1 * span) & (p < hi - 0.1 * span)
    return np.where(use, q, p).astype(np.float32)


def build_map(near, W, H, rect, half, conv):
    """warp_clear + warp_scatter + warp_classify: (H, 2W, 4) = src offset, z, gate, pick."""
    n = near_full(near, W, H, rect, True)
    keys = np.zeros((H, 2 * W), np.int64)
    xs = np.broadcast_to(np.arange(W), (H, W))
    ys = np.broadcast_to(np.arange(H)[:, None], (H, W))
    key = ((np.floor(n * 524287.0 + 0.5).astype(np.int64) + 1) << 12) | xs
    for eye, sgn in ((0, 1.0), (1, -1.0)):
        tx = np.floor(xs + (n - conv) * half * sgn + 0.5).astype(int)
        ok = (tx >= 0) & (tx < W)
        np.maximum.at(keys, (ys[ok], eye * W + tx[ok]), key[ok])
    hole = keys == 0
    z = np.where(hole, -1.0, ((keys >> 12) - 1) / 524287.0)
    ex = np.tile(np.arange(W), 2)[None, :].repeat(H, 0)
    eye = np.repeat([0, 1], W)[None, :].repeat(H, 0)
    src = (keys & 4095).astype(np.float64)
    inv = hole.copy()
    rim = max(2, round(W / 120))
    cand = (~hole) & (z < 0.5)
    for s in range(1, rim + 1):
        for e, d in ((0, 1), (1, -1)):
            shifted = np.zeros_like(hole)
            if d == 1:
                shifted[:, e * W:(e + 1) * W - s] = hole[:, e * W + s:(e + 1) * W]
            else:
                shifted[:, e * W + s:(e + 1) * W] = hole[:, e * W:(e + 1) * W - s]
            inv |= cand & (eye == e) & shifted
    if BG_FILL:
        # Disocclusions show what was behind: sample them at the background's own disparity (local
        # minimum near within the largest shift), not the interpolated edge value that copies hair.
        h_, w_ = near.shape
        reach = int(np.ceil(half * rect[2] * w_ / W)) + 1
        cols = np.arange(w_); bg = near.copy()
        for d in range(-reach, reach + 1):
            bg = np.minimum(bg, near[:, np.clip(cols + d, 0, w_ - 1)])
        nl = near_full(bg, W, H, rect, False)
    else:
        nl = near_full(near, W, H, rect, False)
    nl2 = np.concatenate([nl, nl], 1)
    src_inv = np.clip(ex + np.where(eye == 0, -1.0, 1.0) * (nl2 - conv) * half, 0, W - 1)
    src = np.where(inv, src_inv, src)
    if CLAMP_FILL:
        # Never let a disocclusion sample the occluder: if the inverse sample lands on source pixels
        # nearer than the local background, walk it back toward the hole's background side.
        h_, w_ = near.shape
        reach = int(np.ceil(half * rect[2] * w_ / W)) + 1
        cols = np.arange(w_); bgm = near.copy()
        for dd in range(-reach, reach + 1):
            bgm = np.minimum(bgm, near[:, np.clip(cols + dd, 0, w_ - 1)])
        nfull = near_full(near, W, H, rect, False); bgfull = near_full(bgm, W, H, rect, False)
        rows_ = np.arange(H)[:, None]
        for e, d in ((0, -1), (1, 1)):
            sl = slice(e * W, (e + 1) * W)
            cur = src[:, sl].copy(); m_ = inv[:, sl]
            ref = bgfull[rows_, np.clip(np.tile(np.arange(W), 1)[None, :], 0, W - 1)]
            moved = np.zeros_like(m_)
            for _ in range(int(2 * half) + 8):
                xi = np.clip(np.round(cur).astype(int), 0, W - 1)
                bad = m_ & (nfull[rows_, xi] > ref + CLAMP_TOL)
                if not bad.any():
                    break
                cur = np.where(bad, np.clip(cur + d, 0, W - 1), cur)
                moved = moved | bad if _ else bad
            # Step past the wisps at the silhouette, then keep the fill coherent from row to row.
            cur = np.where(moved, np.clip(cur + d * CLAMP_MARGIN, 0, W - 1), cur)
            off = np.where(m_, cur - np.arange(W)[None, :], 0.0); cnt = m_.astype(np.float64)
            acc = np.zeros_like(off); n_ = np.zeros_like(off)
            for dy in range(-CLAMP_SMOOTH, CLAMP_SMOOTH + 1):
                r_ = np.clip(np.arange(H) + dy, 0, H - 1)
                acc += off[r_]; n_ += cnt[r_]
            src[:, sl] = np.where(m_, np.clip(np.arange(W)[None, :] + acc / np.maximum(n_, 1), 0, W - 1), cur)
    if MIRROR_FILL:
        # The background a disocclusion reveals was hidden in the source: no lookup finds it, and an
        # inverse warp lands on the occluder (duplicated hair). Mirror the visible background instead,
        # about the first clean background pixel on the hole's background side (left eye: left).
        maxd = int(2 * half) + 2 * rim + 8
        for e, d in ((0, -1), (1, 1)):
            lo_, hi_ = e * W, (e + 1) * W
            ys_, xs_ = np.nonzero(inv[:, lo_:hi_])
            xs_ = xs_ + lo_
            found = np.full(xs_.size, -1)
            for k_ in range(1, maxd + 1):
                cx = xs_ + d * k_
                ok = (found < 0) & (cx >= lo_) & (cx < hi_)
                cxc = np.clip(cx, lo_, hi_ - 1)
                ok &= ~inv[ys_, cxc]
                found = np.where(ok, cxc, found)
            has = found >= 0
            anchor = np.clip(found + d * rim, lo_, hi_ - 1)  # past the contaminated rim
            anchor = np.where(inv[ys_, anchor], found, anchor)
            dist = np.abs(xs_ - anchor)
            s_anchor = (keys[ys_, anchor] & 4095).astype(np.float64)
            mirrored = np.clip(s_anchor + d * dist, 0, W - 1)
            src[ys_[has], xs_[has]] = mirrored[has]
        # Rows find different anchors along a ragged silhouette; average the hole offsets vertically
        # (holes only) so the mirrored background stays coherent instead of banding.
        off = np.where(inv, src - ex, 0.0); cnt = inv.astype(np.float64)
        acc = np.zeros_like(off); n_ = np.zeros_like(off)
        for dy in range(-6, 7):
            rows = np.clip(np.arange(H) + dy, 0, H - 1)
            acc += off[rows]; n_ += cnt[rows]
        src = np.where(inv, np.clip(ex + acc / np.maximum(n_, 1), 0, W - 1), src)

    def shifted(arr, dy, dx, fill):
        """arr[y+dy, x+dx] within the same eye (fill outside), rows clamped."""
        out = np.full_like(arr, fill)
        rows = np.clip(np.arange(H) + dy, 0, H - 1)
        a = arr[rows]
        for e in (0, 1):
            lo_, hi_ = e * W, (e + 1) * W
            if dx >= 0:
                out[:, lo_:hi_ - dx] = a[:, lo_ + dx:hi_]
            else:
                out[:, lo_ - dx:hi_] = a[:, lo_:hi_ + dx]
        return out

    nmin = np.full((H, 2 * W), 2.0); nmax = np.full((H, 2 * W), -1.0)
    for dy in range(-2, 3):
        for dx in range(-3, 4):
            zz = shifted(z, dy, dx, -1.0)
            written = zz >= 0
            nmin = np.where(written, np.minimum(nmin, zz), nmin)
            nmax = np.where(written, np.maximum(nmax, zz), nmax)
    gate = np.where(hole & (nmax - nmin > 0.30), 0.5 * (nmin + nmax), 2.0)
    fgwin = max(2, round(W / 240))
    fg = (~hole) & (z >= 0.5)
    left = np.zeros((H, 2 * W), int); right = np.zeros((H, 2 * W), int)
    for s in range(fgwin, 0, -1):  # nearest wins: write farthest first
        left = np.where(shifted(fg, 0, -s, False), -s, left)
        right = np.where(shifted(fg, 0, s, False), s, right)
    pick = np.where((~fg) & (left != 0) & (right != 0), np.where(-left <= right, left, right), 0)
    return np.stack([src - ex, z, gate, pick], -1), hole


def global_shift(src, cur, search=8):
    """Integer (dx, dy) that best aligns src onto cur (mean abs diff over the overlap)."""
    h, w = src.shape
    best, arg = 1e9, (0, 0)
    for dy in range(-search, search + 1):
        for dx in range(-search, search + 1):
            a = src[max(0, -dy):h - max(0, dy), max(0, -dx):w - max(0, dx)]
            b = cur[max(0, dy):h - max(0, -dy), max(0, dx):w - max(0, -dx)]
            e = np.abs(a - b).mean()
            if e < best:
                best, arg = e, (dx, dy)
    return arg


def motion_mask(src_gray, cur_gray, lo=0.04, hi=0.12, grow=2):
    """Where the shown frame differs from the depth's source frame (model grid): 0 trust, 1 flatten.
    The camera's global shift is removed first; it moves the depth with the picture (returned)."""
    dx, dy = global_shift(src_gray, cur_gray)
    h, w = src_gray.shape
    ys, xs = np.mgrid[0:h, 0:w]
    aligned = src_gray[np.clip(ys - dy, 0, h - 1), np.clip(xs - dx, 0, w - 1)]
    d = box(np.abs(cur_gray - aligned).astype(np.float64), 1)
    d = minmax(d, grow)[1]
    k = np.clip((d - lo) / (hi - lo), 0, 1)
    k = k * k * (3 - 2 * k)
    return box(k, 1).astype(np.float32), (dx, dy)


def render(frame, m, W, H, k=None):
    """warp_frame_body: one pass over the 2W x H pair. k (H x W): parallax kept = 1 - k."""
    ex = np.tile(np.arange(W), 2)[None, :]
    if k is not None:
        k2 = np.concatenate([k, k], 1)
        m = m.copy(); m[..., 0] *= 1 - k2
        m[..., 3] = np.where(k2 < 0.5, m[..., 3], 0)
        m[..., 1] = np.where(k2 < 0.5, m[..., 1], 0)  # no hole blend where flattened
    sx = np.clip(ex + m[..., 0], 0, W - 1)
    x0 = np.floor(sx).astype(int); x1 = np.minimum(x0 + 1, W - 1); f = (sx - x0)[..., None]
    rows = np.arange(H)[:, None]
    f32 = frame.astype(np.float32)
    flat = f32[rows, x0] * (1 - f) + f32[rows, x1] * f
    out = flat.copy()
    pick = m[..., 3].astype(int)
    py, px = np.nonzero(pick)
    out[py, px] = flat[py, px + pick[py, px]]
    hy, hx = np.nonzero((pick == 0) & (m[..., 1] < 0))
    acc = np.zeros((hy.size, 3), np.float32); cnt = np.zeros(hy.size, np.float32)
    eye_lo = np.where(hx >= W, W, 0)
    for dy in range(-2, 3):
        ny = np.clip(hy + dy, 0, H - 1)
        for dx in range(-3, 4):
            nx = hx + dx
            ok = (nx >= eye_lo) & (nx < eye_lo + W)
            nxc = np.clip(nx, 0, 2 * W - 1)
            z = m[ny, nxc, 1]
            ok &= ~((z >= 0) & (z > m[hy, hx, 2]))
            acc += flat[ny, nxc] * ok[:, None]; cnt += ok
    blur = np.where(cnt[:, None] > 0, acc / np.maximum(cnt, 1)[:, None], flat[hy, hx])
    out[hy, hx] = flat[hy, hx] * 0.65 + blur * 0.35
    return np.clip(out + 0.5, 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('frames')
    ap.add_argument('--out', required=True)
    ap.add_argument('--model', default=str(ROOT / 'build/depth/depth_252x140.onnx'))
    ap.add_argument('--lag', type=int, default=6, help='frames between a depth input and its first display')
    ap.add_argument('--every', type=int, default=6, help='frames between depth inputs')
    ap.add_argument('--dilate', type=int, default=-1)
    ap.add_argument('--strength', type=float, default=1.0)
    ap.add_argument('--show', type=int, nargs='+', default=[30])
    ap.add_argument('--snap', type=float, nargs=3, metavar=('WIDTH', 'RADIUS', 'SOFT'),
                    help='colour-snap depth transitions to the shown frame at WIDTH (16:9 grid)')
    ap.add_argument('--guide', type=float, nargs=3, metavar=('WIDTH', 'RADIUS', 'EPS'),
                    help='guided-filter the near map by the shown frame at WIDTH (16:9 grid)')
    ap.add_argument('--snap-px', type=float, default=SNAP_PX)
    ap.add_argument('--bg-fill', action='store_true', help='fill disocclusions at the local background disparity')
    ap.add_argument('--mirror-fill', action='store_true', help='fill disocclusions by mirroring the visible background')
    ap.add_argument('--clamp-fill', type=float, nargs=3, metavar=('TOL', 'MARGIN', 'SMOOTH'),
                    help='keep disocclusion samples off the occluder (near tolerance, extra px, row smoothing)')
    ap.add_argument('--motion', type=float, nargs=2, metavar=('LO', 'HI'),
                    help='flatten parallax where the shown frame differs from the depth source (luma diff band)')
    a = ap.parse_args()
    globals()['SNAP_PX'] = a.snap_px
    globals()['BG_FILL'] = a.bg_fill
    globals()['MIRROR_FILL'] = a.mirror_fill
    globals()['CLAMP_FILL'] = a.clamp_fill is not None
    if a.clamp_fill:
        globals()['CLAMP_TOL'], globals()['CLAMP_MARGIN'], globals()['CLAMP_SMOOTH'] = a.clamp_fill[0], int(a.clamp_fill[1]), int(a.clamp_fill[2])
    frames = sorted(Path(a.frames).glob('f_*.png'))
    out = Path(a.out); work = out / 'work'; work.mkdir(parents=True, exist_ok=True)
    sess = ort.InferenceSession(a.model, providers=['CPUExecutionProvider'])
    _, _, h, w = sess.get_inputs()[0].shape
    first = np.asarray(Image.open(frames[0]).convert('RGB'))
    H, W = first.shape[:2]
    rect = content_rect(W, H, w, h)
    sources = list(range(0, len(frames), a.every))
    for i, f in enumerate(sources):
        x = model_input(np.asarray(Image.open(frames[f]).convert('RGB')), w, h, rect)
        inv = sess.run(None, {'src': x[None]})[0][0, 0].astype(np.float32)
        inv.tofile(work / f'inv_{i:03d}.bin'); x.astype(np.float32).tofile(work / f'rgb_{i:03d}.bin')
        (work / f'step_{i:03d}.txt').write_text(str(a.every if i else 1))
    r = subprocess.run([str(CLI), str(work), str(w), str(h), str(len(sources)), str(a.dilate)], capture_output=True, text=True)
    print(r.stdout.strip(), r.stderr.strip())
    half = W * SHIFT * a.strength * 0.5
    for t in a.show:
        usable = [i for i, f in enumerate(sources) if f + a.lag <= t] or [0]
        i = usable[-1]
        near = np.fromfile(work / f'near_{i:03d}.bin', np.float32).reshape(h, w)
        frame = np.asarray(Image.open(frames[t]).convert('RGB'))
        if a.snap:
            gw = int(a.snap[0]); gh = round(gw * H / W)
            near = color_snap(near, frame, rect, gw, gh, int(a.snap[1]), a.snap[2])
            np.save(out / f'guided_{t:03d}.npy', near)
            m, _ = build_map(near, W, H, np.array([0, 0, 1, 1], np.float32), half, CONVERGENCE)
        elif a.guide:
            gw = int(a.guide[0]); gh = round(gw * H / W)
            near = guided(near, frame, rect, gw, gh, int(a.guide[1]), a.guide[2])
            np.save(out / f'guided_{t:03d}.npy', near)
            m, _ = build_map(near, W, H, np.array([0, 0, 1, 1], np.float32), half, CONVERGENCE)
        else:
            m, _ = build_map(near, W, H, rect, half, CONVERGENCE)
        k = None
        if a.motion:
            src_gray = model_input(np.asarray(Image.open(frames[sources[i]]).convert('RGB')), w, h, rect).mean(0)
            cur_gray = model_input(frame, w, h, rect).mean(0)
            km, gshift = motion_mask(src_gray, cur_gray, a.motion[0], a.motion[1])
            # Only near depth edges, where a stale map drags background with the subject; keep 30%.
            lo_n, hi_n = minmax(near if not (a.snap or a.guide) else near, 4)
            e = np.clip((hi_n - lo_n - 0.1) / 0.2, 0, 1)
            km = (km * e * e * (3 - 2 * e) * 0.7).astype(np.float32)
            print('global shift', gshift, 'flattened share %.2f' % km.mean())
            if km.mean() > 0.85:
                km[:] = 0  # nearly everything changed (a cut the stabilizer has not seen yet): keep the depth
            k = near_full(km, W, H, rect, False)
            Image.fromarray((k * 255).astype(np.uint8)).resize((W // 4, H // 4)).save(out / f'motion_{t:03d}.png')
        Image.fromarray(render(frame, m, W, H, k)).save(out / f'sbs_{t:03d}.png')
        Image.fromarray((near * 255).astype(np.uint8)).resize((W // 4, H // 4), Image.NEAREST).save(out / f'near_{t:03d}.png')
        print(f'frame {t}: depth from source frame {sources[i]} (age {t - sources[i]})')


if __name__ == '__main__':
    main()
