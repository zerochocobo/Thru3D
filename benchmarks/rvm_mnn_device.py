"""Quest check of the production MNN OpenCL RVM wrapper (native/rvm/rvm_mnn_backend.cpp).

Runs the standalone ADB executable (shell UID; the app UID is checked separately
through the APK paths). For each precision it:
  * audits op placement (any CPU op rejects the backend),
  * runs the first N R09 real stereo frames recurrently and compares Alpha with
    the ORT FP32 sequence of the same ratio=1 graph (MAE, RMS, max, IoU, recall,
    temporal flicker of the difference),
  * times the stereo call on synthetic input for every requested profile,
    sampling the kgsl GPU clock.
Evidence goes to artifacts/rvm-mnn/device/<timestamp>/.
"""
import os
from pathlib import Path
import argparse
import glob
import hashlib
import json
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
ADB = str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'android-sdk/platform-tools/adb.exe')
LIBCXX = str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so')
EXE = ROOT / 'build/rvm-mnn-test/rvm_mnn_test'
MODEL = ROOT / 'build/rvm/mnn/rvm.mnn'
REMOTE = '/data/local/tmp/rvm_mnn'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def metrics(ref, est):
    d = est - ref
    fr, fe = ref > 0.5, est > 0.5
    inter = (fr & fe).sum((1, 2)); union = (fr | fe).sum((1, 2))
    rec = (np.minimum(est, ref) * fr).sum((1, 2)) / np.maximum((ref * fr).sum((1, 2)), 1e-6)
    return dict(max_abs=float(np.abs(d).max()), rms=float(np.sqrt((d ** 2).mean())), mae=float(np.abs(d).mean()),
                iou=float((inter / np.maximum(union, 1)).mean()), iou_min=float((inter / np.maximum(union, 1)).min()),
                fg_recall=float(rec.mean()), fg_recall_min=float(rec.min()),
                diff_flicker=float(np.abs(np.diff(d, axis=0)).mean()))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--serial', default='2G0YC5ZF7V0664')
    p.add_argument('--frames', type=int, default=60)
    p.add_argument('--iters', type=int, default=40)
    p.add_argument('--profiles', nargs='*', default=['512x512', '384x384', '320x320', '384x216', '256x144'])
    a = p.parse_args()

    def adb(*args, check=True, timeout=600):
        r = subprocess.run([ADB, '-s', a.serial, *args], capture_output=True, text=True, errors='replace', timeout=timeout)
        if check and r.returncode:
            raise RuntimeError(r.stderr or r.stdout)
        return r.stdout

    out = ROOT / 'artifacts/rvm-mnn/device' / datetime.now().strftime('%Y%m%d_%H%M%S')
    out.mkdir(parents=True)
    src = Path(glob.glob(str(ROOT / 'artifacts/device/20261004_164221_motion_*/mpv_motion_*'))[0])
    receipt = dict(exe_sha256=sha(EXE), model_sha256=sha(MODEL), frames=a.frames, source=str(src),
                   model_manifest=json.loads((MODEL.parent / 'manifest.json').read_text(encoding='utf-8')),
                   battery_before=adb('shell', 'dumpsys', 'battery'))
    adb('shell', 'rm', '-rf', REMOTE)
    adb('shell', 'mkdir', '-p', REMOTE + '/frames')
    for local in (EXE, MODEL, LIBCXX):
        adb('push', str(local), REMOTE + '/')
    adb('shell', 'chmod', '755', REMOTE + '/rvm_mnn_test')
    for i in range(1, a.frames + 1):
        for eye in ('left', 'right'):
            adb('push', str(src / f'frame_{i}_{eye}_rgb.f32'), f'{REMOTE}/frames/')
    run = lambda args: adb('shell', f'cd {REMOTE} && LD_LIBRARY_PATH={REMOTE} ./rvm_mnn_test {args}', check=False)
    results = dict(sequence={}, timing=[])
    refs = {eye: np.load(ROOT / f'artifacts/rvm-expert/ref_alpha_{eye}.npy')[:a.frames] for eye in ('left', 'right')}
    for fp16 in (1, 0):
        text = run(f'rvm.mnn 512 512 {fp16} frames {a.frames} 0')
        (out / f'sequence_fp{16 if fp16 else 32}.txt').write_text(text, encoding='utf-8')
        if 'PREPARE' not in text or 'SEQUENCE' not in text:
            raise SystemExit('Sequence run failed:\n' + text)
        tag = 'fp16' if fp16 else 'fp32'
        res = dict(prepare=re.search(r'PREPARE.*', text).group(0))
        for eye in ('left', 'right'):
            est = []
            for i in range(1, a.frames + 1):
                pulled = out / 'pulled.f32'
                adb('pull', f'{REMOTE}/frames/frame_{i}_{eye}_mnn_alpha.f32', str(pulled))
                est.append(np.fromfile(pulled, np.float32).reshape(512, 512))
            pulled.unlink()
            res[eye] = metrics(refs[eye], np.stack(est))
        results['sequence'][tag] = res
        print(tag, json.dumps(res), flush=True)
    for profile in a.profiles:
        w, h = profile.split('x')
        for fp16 in (1, 0):
            text = run(f'rvm.mnn {w} {h} {fp16} - 0 {a.iters} cache_{profile}_{fp16}.bin')
            line = re.search(r'RESULT.*', text)
            prep = re.search(r'PREPARE.*', text)
            results['timing'].append(dict(profile=profile, fp16=bool(fp16), prepare=prep.group(0) if prep else None,
                                          result=line.group(0) if line else text[-500:]))
            print(profile, fp16, line.group(0) if line else text[-300:], flush=True)
            time.sleep(2)
    receipt['battery_after'] = adb('shell', 'dumpsys', 'battery')
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    (out / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    adb('shell', 'rm', '-rf', REMOTE, check=False)
    print('evidence', out)


if __name__ == '__main__':
    main()
