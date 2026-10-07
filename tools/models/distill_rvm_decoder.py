"""Distil a narrower-decoder RVM (slim_rvm_decoder.py) from the production graph.

Teacher: build/rvm/mnn/rvm.fused.u8.onnx (the shipped network, FP32). Student: the same
graph with sliced decoder layers, initialised from the teacher's first channels. Both
run in PyTorch through onnx2torch on CUDA (a separate training virtual environment).

  data   decode 8-frame 30fps sequences of one eye from local VR videos, crop windows
         like the player's ROI (full eye, windows around the teacher's people, random),
         resize to 320x320 and store uint8 (artifacts/rvm-distill/<name>.npy).
         User-supplied exclusion windows are left out of training.
  train  recurrent unroll from zero states (as the player starts a window), L1 + gradient
         loss on Alpha against the teacher; the backbone and the untouched decoder stages
         stay frozen.
  export write the trained weights back into the student ONNX.
"""
import os
from pathlib import Path
import argparse
import json
import random
import subprocess
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
TEACHER = ROOT / 'build/rvm/mnn/rvm.fused.u8.onnx'
OUT = ROOT / 'artifacts/rvm-distill'
FFMPEG = os.environ.get('THRU3D_FFMPEG', 'ffmpeg')
VIDEOS = ROOT
MASTER = 1024
SIZE = 320
T = 8
# (file, layout) — layout 'sbs' = side-by-side stereo, one eye per half. Exclusions are the
# User-supplied exclusion windows are expressed in seconds.
SOURCES = []  # Filled by data --sources; no private training filenames.


def duration(path):
    out = subprocess.run([FFMPEG.replace('ffmpeg.exe', 'ffprobe.exe'), '-v', 'error', '-show_entries', 'format=duration',
                          '-of', 'csv=p=0', str(path)], capture_output=True, text=True).stdout.strip()
    return float(out) if out else 0.0


def decode_eye(path, start, eye, frames=T):
    x = '0' if eye == 0 else 'iw/2'
    vf = (f'fps=30,crop=iw/2:ih:{x}:0,scale={MASTER}:{MASTER}:force_original_aspect_ratio=decrease:flags=area,'
          f'pad={MASTER}:{MASTER}:(ow-iw)/2:(oh-ih)/2')
    count = frames
    raw = subprocess.run([FFMPEG, '-v', 'error', '-ss', f'{start:.2f}', '-i', str(path), '-frames:v', str(frames), '-vf', vf,
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True).stdout
    frames = np.frombuffer(raw, np.uint8)
    return frames.reshape(-1, MASTER, MASTER, 3) if frames.size == count * MASTER * MASTER * 3 else None


def crop(frames, win):
    x0, y0, w = win
    m = np.array([[SIZE / w, 0, -x0 * SIZE / w], [0, SIZE / w, -y0 * SIZE / w]], np.float32)
    flags = cv2.INTER_AREA if w > SIZE else cv2.INTER_LINEAR
    return np.stack([cv2.warpAffine(f, m, (SIZE, SIZE), flags=flags, borderMode=cv2.BORDER_CONSTANT) for f in frames])


class Net:
    """onnx2torch module of a u8 RVM graph; step(src_u8 NCHW float, states) -> (pha, states)."""
    def __init__(self, path, device, raw_alpha=False):
        import onnx
        import onnx2torch
        from onnx import helper, TensorProto
        model = onnx.load(path)
        if raw_alpha:
            # Train on the projection before Clip(0, 1): a clipped output that drifts below zero
            # everywhere gets no gradient and the student collapses to a constant.
            clip = next(n for n in model.graph.node if n.op_type == 'Clip' and n.output[0] == 'pha')
            model.graph.output.append(helper.make_tensor_value_info(clip.input[0], TensorProto.FLOAT, None))
        self.raw = clip.input[0] if raw_alpha else None
        # Always eval: the graph's only BatchNorm is the fixed input normalisation (gradients still flow).
        self.model = onnx2torch.convert(model).to(device).eval()
        self.inputs = [i.name for i in model.graph.input]
        self.outputs = [o.name for o in model.graph.output]
        self.channels = {i.name: i.type.tensor_type.shape.dim[1].dim_value or {'r1i': 16, 'r2i': 20, 'r3i': 40, 'r4i': 64}[i.name]
                         for i in model.graph.input if i.name != 'src'}
        self.device = device
        self.rgba = next(i for i in model.graph.input if i.name == 'src').type.tensor_type.shape.dim[1].dim_value == 4

    def zeros(self, batch):
        import torch
        return {k: torch.zeros(batch, c, SIZE // 2 ** int(k[1]), SIZE // 2 ** int(k[1]), device=self.device)
                for k, c in self.channels.items()}

    def step(self, src, states):
        import torch
        if self.rgba and src.shape[1] == 3:  # RGBA graphs ignore the 4th channel (zero weights)
            src = torch.cat([src, torch.zeros_like(src[:, :1])], 1)
        out = self.model(*[src if n == 'src' else states[n] for n in self.inputs])
        named = dict(zip(self.outputs, out))
        return named[self.raw or 'pha'], {f'r{i}i': named[f'r{i}o'] for i in range(1, 5)}


def make_data(name, sequences, seed, length=T):
    import torch
    rng = random.Random(seed)
    device = 'cuda'
    teacher = Net(TEACHER, device)
    teacher.model.eval()
    sources = [(VIDEOS / f, ex) for f, ex in SOURCES if (VIDEOS / f).exists()]
    lengths = {p: duration(p) for p, _ in sources}
    OUT.mkdir(parents=True, exist_ok=True)
    store = np.lib.format.open_memmap(OUT / f'{name}.npy', mode='w+', dtype=np.uint8, shape=(sequences, length, SIZE, SIZE, 3))
    meta, n = [], 0
    while n < sequences:
        path, exclude = rng.choice(sources)
        start = rng.uniform(1, max(2, lengths[path] - 2))
        if any(a - 1 <= start <= b for a, b in exclude):
            continue
        frames = decode_eye(path, start, rng.randint(0, 1), length)
        if frames is None:
            continue
        full = crop(frames, (0, 0, MASTER))
        with torch.no_grad():
            states = teacher.zeros(1)
            for f in full:
                src = torch.from_numpy(f).permute(2, 0, 1)[None].float().to(device)
                pha, states = teacher.step(src, states)
        alpha = pha[0, 0].cpu().numpy()
        windows = [(0, 0, MASTER)]
        ys, xs = np.nonzero(alpha > 0.5)
        if len(xs) > 20:
            scale = MASTER / SIZE
            x0, x1, y0, y1 = xs.min() * scale, (xs.max() + 1) * scale, ys.min() * scale, (ys.max() + 1) * scale
            for margin in (rng.uniform(0.1, 0.3), rng.uniform(0.3, 0.8)):
                side = max(x1 - x0, y1 - y0) * (1 + margin)
                side = min(MASTER, max(side, 160))
                cx, cy = (x0 + x1) / 2 + rng.uniform(-0.1, 0.1) * side, (y0 + y1) / 2 + rng.uniform(-0.1, 0.1) * side
                windows.append((int(np.clip(cx - side / 2, 0, MASTER - side)), int(np.clip(cy - side / 2, 0, MASTER - side)), int(side)))
        side = rng.uniform(240, 900)
        windows.append((rng.uniform(0, MASTER - side), rng.uniform(0, MASTER - side), side))
        for win in windows:
            if n >= sequences:
                break
            store[n] = full if win == (0, 0, MASTER) else crop(frames, win)
            meta.append(dict(video=path.name, start=round(start, 2), window=[float(v) for v in win]))
            n += 1
        if n % 50 < len(windows):
            print(f'{n}/{sequences}', flush=True)
    store.flush()
    (OUT / f'{name}.json').write_text(json.dumps(meta, indent=1, ensure_ascii=False), encoding='utf-8')


def trainable(student_path):
    """Initializers of the student that differ in shape from the teacher's (the sliced layers)
    plus every layer after them in the decoder."""
    import onnx
    from onnx import numpy_helper
    t = {i.name: i.dims for i in onnx.load(TEACHER).graph.initializer}
    s = onnx.load(student_path)
    sliced = {i.name for i in s.graph.initializer if list(i.dims) != list(t.get(i.name, []))}
    return sliced


def train(student_path, data, steps, out, lr, batch, fg_weight=0.0, resume=None):
    import torch
    device = 'cuda'
    teacher, student = Net(TEACHER, device), Net(student_path, device, raw_alpha=True)
    if resume:
        student.model.load_state_dict(torch.load(resume))
    teacher.model.eval()
    for p in teacher.model.parameters():
        p.requires_grad_(False)
    sliced = trainable(student_path)
    params = []
    # onnx2torch keeps initializer tensors as module parameters/buffers named after the ONNX node.
    decoder = ('Conv_230', 'Conv_236', 'Conv_241', 'Conv_260', 'Conv_266', 'Conv_271', 'Conv_290', 'Conv_292', 'Conv_294')
    for name, p in student.model.named_parameters():
        train_it = any(k in name for k in decoder)
        p.requires_grad_(train_it)
        if train_it:
            params.append(p)
    print('trainable tensors', len(params), 'sliced initializers', len(sliced), flush=True)
    opt = torch.optim.Adam(params, lr=lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, steps)
    seqs = np.load(data, mmap_mode='r')
    rng = np.random.default_rng(0)
    held = rng.choice(len(seqs), size=min(64, len(seqs) // 10), replace=False)
    train_ids = np.setdiff1d(np.arange(len(seqs)), held)

    def batch_loss(ids, grad):
        x = torch.from_numpy(np.ascontiguousarray(seqs[np.sort(ids)])).to(device).permute(0, 1, 4, 2, 3).float()
        if grad and rng.random() < 0.5:
            x = x.flip(-1)
        ts, ss = teacher.zeros(len(ids)), student.zeros(len(ids))
        total = 0
        for t in range(x.shape[1]):
            with torch.no_grad():
                target, ts = teacher.step(x[:, t], ts)
            pha, ss = student.step(x[:, t], ss)
            # Small, distant people are a few percent of the pixels: weight their neighbourhood.
            weight = 1 + fg_weight * torch.nn.functional.max_pool2d((target > 0.02).float(), 9, 1, 4)
            l1 = ((pha - target).abs() * weight).mean()
            gy = ((pha[..., 1:, :] - pha[..., :-1, :]) - (target[..., 1:, :] - target[..., :-1, :])).abs() * weight[..., 1:, :]
            gx = ((pha[..., 1:] - pha[..., :-1]) - (target[..., 1:] - target[..., :-1])).abs() * weight[..., 1:]
            grad_l = gy.mean() + gx.mean()
            total = total + l1 + grad_l
        return total / x.shape[1]

    log = []
    for step in range(1, steps + 1):
        loss = batch_loss(rng.choice(train_ids, size=batch, replace=False), True)
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(params, 1.0)
        opt.step()
        sched.step()
        if step % 100 == 0 or step == 1:
            with torch.no_grad():
                val = float(np.mean([batch_loss(held[i:i + batch], False).item() for i in range(0, len(held), batch)]))
            log.append(dict(step=step, train=float(loss.item()), held=val))
            print(json.dumps(log[-1]), flush=True)
    torch.save(student.model.state_dict(), out)
    return log


def export(student_path, weights, output):
    """Copy trained Conv weights into the student ONNX initializers (by node)."""
    import onnx
    import torch
    from onnx import numpy_helper
    model = onnx.load(student_path)
    state = torch.load(weights, map_location='cpu')
    inits = {i.name: i for i in model.graph.initializer}
    written = 0
    for node in model.graph.node:
        if node.op_type != 'Conv':
            continue
        key = node.name.replace('/', '_').replace('.', '_')
        for slot, suffix in ((1, 'weight'), (2, 'bias')):
            if len(node.input) <= slot:
                continue
            match = [k for k in state if k.endswith(f'{key}.{suffix}')]
            if len(match) != 1:
                continue
            value = state[match[0]].numpy().astype(np.float32)
            name = node.input[slot]
            assert list(inits[name].dims) == list(value.shape), (name, inits[name].dims, value.shape)
            inits[name].CopyFrom(numpy_helper.from_array(value, name))
            written += 1
    onnx.save(model, output)
    print('exported', written, 'tensors ->', output)


def main():
    import torch
    # TF32 convolutions differ from the FP32 teacher by ~3e-3 in Alpha; keep full precision.
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('data'); d.add_argument('--name', default='train'); d.add_argument('--sequences', type=int, default=1200)
    d.add_argument('--seed', type=int, default=1); d.add_argument('--frames', type=int, default=T)
    d.add_argument('--sources', type=Path, required=True)
    t = sub.add_parser('train'); t.add_argument('--student', type=Path, required=True); t.add_argument('--data', type=Path, default=OUT / 'train.npy')
    t.add_argument('--steps', type=int, default=3000); t.add_argument('--lr', type=float, default=1e-4); t.add_argument('--batch', type=int, default=8)
    t.add_argument('--out', type=Path, required=True)
    t.add_argument('--fg-weight', type=float, default=0.0); t.add_argument('--resume', type=Path)
    e = sub.add_parser('export'); e.add_argument('--student', type=Path, required=True); e.add_argument('--weights', type=Path, required=True)
    e.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.cmd == 'data':
        global SOURCES, VIDEOS
        VIDEOS = a.sources.resolve().parent
        SOURCES = [(entry['file'], [tuple(pair) for pair in entry.get('exclude_seconds', [])])
                   for entry in json.loads(a.sources.read_text(encoding='utf-8'))]
        if not SOURCES:
            raise SystemExit('Supply at least one licensed source video')
        make_data(a.name, a.sequences, a.seed, a.frames)
    elif a.cmd == 'train':
        log = train(a.student, a.data, a.steps, a.out, a.lr, a.batch, a.fg_weight, a.resume)
        a.out.with_suffix('.log.json').write_text(json.dumps(log, indent=1), encoding='utf-8')
    else:
        export(a.student, a.weights, a.output)


if __name__ == '__main__':
    main()
