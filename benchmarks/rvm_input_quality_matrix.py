"""Full-sequence ONNX quality references; never report these CPU runs as GPU FPS."""
import os
from pathlib import Path
import argparse
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import uuid

import cv2
import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
CASES = [('dense512_r1', 512, 512, 1., False), ('sparse512_r1', 512, 512, 1., True),
         ('dense512_r05', 512, 512, .5, False), ('dense1024_r05', 1024, 1024, .5, False),
         ('dense1024_r025', 1024, 1024, .25, False), ('dense384x432_r1', 384, 432, 1., False)]
MOTION = ROOT / 'artifacts/device/20261004_132059_motion_4313561ab9854aa49af1faa86f8123f6'

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def write(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')

def fit_rect(width, height):
    aspect = (1920 / 2160) / (width / height)
    if aspect < 1:
        return ((1-aspect)/2, 0, aspect, 1)
    return (0, (1-1/aspect)/2, 1, 1/aspect)

def sample(image, x, y):
    x = np.clip(x, 0, image.shape[1]-1)
    y = np.clip(y, 0, image.shape[0]-1)
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    x1 = np.minimum(x0+1, image.shape[1]-1)
    y1 = np.minimum(y0+1, image.shape[0]-1)
    dx = (x-x0)[None, :]
    dy = (y-y0)[:, None]
    if image.ndim == 3:
        dx, dy = dx[..., None], dy[..., None]
    return ((image[y0[:, None], x0[None, :]]*(1-dx) + image[y0[:, None], x1[None, :]]*dx)*(1-dy) +
            (image[y1[:, None], x0[None, :]]*(1-dx) + image[y1[:, None], x1[None, :]]*dx)*dy)

def prepare(image, width, height):
    ox, oy, sx, sy = fit_rect(width, height)
    u = ((np.arange(width)+.5)/width-ox)/sx
    v = ((np.arange(height)+.5)/height-oy)/sy
    inside = (v[:, None] >= 0) & (v[:, None] <= 1) & (u[None, :] >= 0) & (u[None, :] <= 1)
    rgb = sample(image.astype(np.float32), u*1920-.5, v*2160-.5)
    rgb[~inside] = 0
    return np.ascontiguousarray(np.floor(rgb+.5).astype(np.float32).transpose(2, 0, 1)[None]/255)

def canonical(alpha, width, height):
    ox, oy, sx, sy = fit_rect(width, height)
    u = ((np.arange(512)+.5)/512*sx+ox)*width-.5
    v = ((np.arange(512)+.5)/512*sy+oy)*height-.5
    return np.ascontiguousarray(sample(alpha, u, v), dtype=np.float32)

def preview(path, colors, masks):
    rgb = np.concatenate(colors, axis=1)
    alpha = np.concatenate(masks, axis=1)
    yy, xx = np.indices(alpha.shape)
    bg = np.where(((xx//16 + yy//16) % 2)[..., None], .12, .25)
    composite = rgb*alpha[..., None] + bg*(1-alpha[..., None])
    value = np.concatenate([rgb, np.repeat(alpha[..., None], 3, axis=2), composite], axis=0)
    cv2.imwrite(str(path), (np.clip(value[..., ::-1], 0, 1)*255).astype(np.uint8))

def audit(directory):
    receipt = read(directory / 'receipt.json')
    assert sha(directory / 'acquisition-script.py') == receipt['acquisition_sha256']
    assert sha(ROOT / receipt['fixture']['file']) == receipt['fixture']['sha256']
    assert sha(ROOT / receipt['model']) == receipt['model_sha256']
    assert receipt['cases'] == [list(case) for case in CASES]
    assert receipt['model_sha256'] == '88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828'
    assert sha(MOTION / 'report.json') == receipt['sparse_motion_report_sha256']
    expected_sparse = receipt['sparse_indices']
    assert expected_sparse == [round(row['pts_us']*30/1e6) for row in read(MOTION / 'report.json')['records']]
    assert len(expected_sparse) == 12 and expected_sparse == sorted(set(expected_sparse)) and expected_sparse[-1] == 179
    summary = []
    by_case = {}
    for key, width, height, ratio, sparse in CASES:
        report = read(directory / key / 'report.json')
        indices = expected_sparse if sparse else list(range(180))
        assert report['case'] == key and report['ratio'] == ratio and report['dimensions'] == [width, height]
        assert report['reference_backend'] == 'CPUExecutionProvider' and report['production_enabled'] is False
        assert [row['source_index'] for row in report['frames']] == indices
        for row in report['frames']:
            assert row['pts_us'] == round(row['source_index']*1e6/30)
            assert sha(directory / key / row['file']) == row['sha256']
            with np.load(directory / key / row['file'], allow_pickle=False) as masks:
                for eye in ['left', 'right']:
                    alpha = masks[eye]
                    assert alpha.shape == (height, width) and alpha.dtype == np.float32
                    assert np.isfinite(alpha).all() and alpha.min() >= 0 and alpha.max() <= 1
                    mapped = canonical(alpha, width, height)
                    np.testing.assert_array_equal(mapped, masks['canonical_'+eye])
                    assert int(np.count_nonzero(mapped > .5)) == row[eye]['canonical_foreground_above_half']
        expected_shapes = [[1, channels, math.ceil(height*ratio/(2**index)), math.ceil(width*ratio/(2**index))]
                           for index, channels in enumerate([16, 20, 40, 64], 1)]
        assert report['state_shapes'] == expected_shapes
        for frame_index, row in enumerate(report['frames'][:4]):
            with np.load(directory / key / row['file'], allow_pickle=False) as masks:
                for eye in ['left', 'right']:
                    with np.load(directory / key / 'initial-four-frames' / f'{eye}_{frame_index}.npz', allow_pickle=False) as initial:
                        assert initial['src'].shape == (1, 3, height, width)
                        assert hashlib.sha256(initial['src'].tobytes()).hexdigest() == row[eye]['input_sha256']
                        np.testing.assert_array_equal(initial['pha'][0, 0], masks[eye])
                        for state_index, shape in enumerate(expected_shapes, 1):
                            value = initial[f'r{state_index}o']
                            assert list(value.shape) == shape and value.dtype == np.float32 and np.isfinite(value).all()
        by_case[key] = report
        counts = [row[eye]['canonical_foreground_above_half'] for row in report['frames'] for eye in ['left', 'right']]
        summary.append(dict(case=key, frames=len(indices), mean_canonical_foreground_above_half=float(np.mean(counts)),
            zero_foreground_eye_frames=sum(count == 0 for count in counts), state_shapes=report['state_shapes'],
            human_quality_verified=False, Quest_GPU_performance_verified=False))
    differences = []
    for index in expected_sparse:
        dense_file = directory / 'dense512_r1' / f'frame_{index:03}.npz'
        sparse_file = directory / 'sparse512_r1' / f'frame_{index:03}.npz'
        dense_row = by_case['dense512_r1']['frames'][index]
        sparse_row = next(row for row in by_case['sparse512_r1']['frames'] if row['source_index'] == index)
        with np.load(dense_file, allow_pickle=False) as dense, np.load(sparse_file, allow_pickle=False) as sparse:
            for eye in ['left', 'right']:
                assert dense_row[eye]['input_sha256'] == sparse_row[eye]['input_sha256']
                delta = np.abs(dense[eye]-sparse[eye])
                differences.append(dict(index=index, eye=eye, max_abs=float(delta.max()), rms=float(np.sqrt(np.mean(delta**2)))))
    result = dict(state='passed_six_reference_sequence_and_geometry_audits_quality_unverified', cases=summary,
        dense_sparse_same_input_comparison=differences, dense_frames_per_case=180, sparse_frames=12,
        source_sampling='Canonical encoded FFmpeg RGB; analytical bilinear pixel centers and RGBA8 rounding, no exact MPV color/shader parity claim',
        person_quality_verified=False, Quest_GPU_performance_verified=False, production_enabled=False,
        scope='Host CPU quality/oracle diagnostics; eight independent recurrent tensors per case, complete timeline for dense cases; no playback FPS/XR or numerical native proof')
    write(directory / 'verification.json', result)
    print(json.dumps(result), flush=True)

def run():
    output = ROOT / 'artifacts/rvm-input-matrix' / (datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    fixture = read(ROOT / 'tests/fixtures/mp07_motion_4k.json')
    video = ROOT / fixture['file']
    assert sha(video) == fixture['sha256']
    model = ROOT / 'models/source/rvm_mobilenetv3_fp32.onnx'
    assert sha(model) == '88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828'
    motion = read(MOTION / 'report.json')
    indices = [round(row['pts_us']*30/1e6) for row in motion['records']]
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    session = ort.InferenceSession(str(model), options, providers=['CPUExecutionProvider'])
    receipt = dict(model=model.relative_to(ROOT).as_posix(), model_sha256=sha(model), fixture=fixture,
        sparse_motion_report_sha256=sha(MOTION / 'report.json'), sparse_indices=indices,
        acquisition_sha256=sha(__file__), onnxruntime_version=ort.__version__,
        reference_backend='CPUExecutionProvider', gpu_inference_claimed=False, cases=[list(case) for case in CASES])
    shutil.copy2(__file__, output / 'acquisition-script.py')
    write(output / 'receipt.json', receipt)
    state, reports = {}, {}
    for key, width, height, ratio, sparse in CASES:
        (output / key).mkdir()
        (output / key / 'initial-four-frames').mkdir()
        state[key] = {eye: {f'r{i}i': np.zeros((1, 1, 1, 1), np.float32) for i in range(1, 5)} for eye in ['left', 'right']}
        reports[key] = dict(case=key, dimensions=[width, height], ratio=ratio, frames=[], state_shapes=None,
            reference_backend='CPUExecutionProvider', production_enabled=False)
    process = subprocess.Popen([os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), '-v', 'error', '-i', str(video),
        '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    image_bytes = 3840*2160*3
    try:
        for index in range(180):
            parts = bytearray()
            while len(parts) < image_bytes:
                value = process.stdout.read(image_bytes-len(parts))
                assert value, 'Independent decoder ended early'
                parts.extend(value)
            full = np.frombuffer(parts, np.uint8).reshape(2160, 3840, 3)
            colors = [sample(full[:, eye*1920:(eye+1)*1920].astype(np.float32),
                             (np.arange(512)+.5)/512*1920-.5, (np.arange(512)+.5)/512*2160-.5)/255 for eye in [0, 1]]
            for key, width, height, ratio, sparse in CASES:
                if sparse and index not in indices:
                    continue
                stored, row = {}, dict(source_index=index, pts_us=round(index*1e6/30))
                for eye_index, eye in enumerate(['left', 'right']):
                    src = prepare(full[:, eye_index*1920:(eye_index+1)*1920], width, height)
                    values = session.run(['pha', 'r1o', 'r2o', 'r3o', 'r4o'],
                        dict(src=src, downsample_ratio=np.array([ratio], np.float32), **state[key][eye]))
                    alpha = values[0][0, 0]
                    assert alpha.shape == (height, width) and alpha.dtype == np.float32
                    assert all(np.isfinite(value).all() for value in values) and alpha.min() >= 0 and alpha.max() <= 1
                    shapes = [list(value.shape) for value in values[1:]]
                    if reports[key]['state_shapes'] is None:
                        reports[key]['state_shapes'] = shapes
                    assert reports[key]['state_shapes'] == shapes
                    state[key][eye] = {f'r{i+1}i': value for i, value in enumerate(values[1:])}
                    stored[eye] = alpha
                    stored['canonical_'+eye] = canonical(alpha, width, height)
                    row[eye] = dict(input_sha256=hashlib.sha256(src.tobytes()).hexdigest(),
                        canonical_foreground_above_half=int(np.count_nonzero(stored['canonical_'+eye] > .5)),
                        native_min_alpha=float(alpha.min()), native_max_alpha=float(alpha.max()))
                    if len(reports[key]['frames']) < 4:
                        np.savez_compressed(output / key / 'initial-four-frames' / f'{eye}_{len(reports[key]["frames"])}.npz',
                            src=src, pha=values[0], **{f'r{i+1}o': value for i, value in enumerate(values[1:])})
                name = f'frame_{index:03}.npz'
                np.savez_compressed(output / key / name, **stored)
                row.update(file=name, sha256=sha(output / key / name))
                reports[key]['frames'].append(row)
                if index in [0, indices[len(indices)//2], 179]:
                    preview(output / key / f'preview_{index:03}.png', colors,
                        [stored['canonical_left'], stored['canonical_right']])
                write(output / key / 'report.json', reports[key])
            if index % 15 == 0 or index == 179:
                print(json.dumps(dict(index=index, state='collected_all_due_cases', trace=str(output))), flush=True)
        assert not process.stdout.read(1), 'Unexpected extra source frame'
        error = process.stderr.read().decode(errors='replace')
        assert process.wait(timeout=30) == 0, error
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    audit(output)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        audit(args.verify)
    else:
        run()
