"""Audit the separate ratio=1 graph against the released ONNX's base projection.

This is structural/numerical branch validation, not an independent PyTorch
checkpoint oracle, annotated person quality gate or Quest performance test.
"""
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
import onnx
from onnx import helper, TensorProto
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/rvm-ratio-one/reference'
MOTION = ROOT / 'artifacts/device/20261004_132059_motion_4313561ab9854aa49af1faa86f8123f6'
NAMES = ['fgr', 'pha', 'r1o', 'r2o', 'r3o', 'r4o', '753', '754']

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'models/source/rvm_mobilenetv3_fp32.onnx'
    assert sha(source) == '88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828'
    model = onnx.load(source)
    # Expose the original graph's pre-refiner projection without reconnecting
    # or modifying any operator or original output.
    model.graph.output.extend([helper.make_tensor_value_info('753', TensorProto.FLOAT, [1, 3, 512, 512]),
                               helper.make_tensor_value_info('754', TensorProto.FLOAT, [1, 1, 512, 512])])
    onnx.checker.check_model(model)
    onnx.save(model, OUT / 'released-with-base-outputs.onnx')
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    options.intra_op_num_threads = 4
    original = ort.InferenceSession(str(OUT / 'released-with-base-outputs.onnx'), options, providers=['CPUExecutionProvider'])
    candidate_model = ROOT / 'build/rvm-ratio-one/512x512/rvm.fixed.onnx'
    candidate = ort.InferenceSession(str(candidate_model), options, providers=['CPUExecutionProvider'])
    profile = read(ROOT / 'build/rvm-ratio-one/512x512/profile.json')
    motion = read(MOTION / 'report.json')
    motion_dir = MOTION / motion['evidence_directory']
    rows = []
    synthetic = []
    # Each scenario and eye has its own fresh four-state sequence.
    for scenario in ['synthetic', 'captured_motion']:
        states_a = {eye: {key: np.zeros(shape, np.float32) for key, shape in profile['input_shapes'].items() if key != 'src'} for eye in ['left', 'right']}
        states_b = {eye: {key: value.copy() for key, value in states.items()} for eye, states in states_a.items()}
        count = 4 if scenario == 'synthetic' else len(motion['records'])
        for index in range(count):
            colors, old_masks, new_masks = [], [], []
            for eye in ['left', 'right']:
                if scenario == 'synthetic':
                    path = ROOT / 'artifacts/rvm-ratio-one/host/512x512' / f'{eye}_{index}.npz'
                    with np.load(path, allow_pickle=False) as item:
                        src = item['src']
                else:
                    entry = motion['records'][index]['files'][eye + '_rgb']
                    path = motion_dir / entry['file']
                    assert sha(path) == entry['sha256']
                    src = np.fromfile(path, '<f4').reshape(1, 3, 512, 512)
                reference = original.run(NAMES, dict(src=src, downsample_ratio=np.array([1], np.float32), **states_a[eye]))
                actual = candidate.run(NAMES[:6], dict(src=src, **states_b[eye]))
                expected = [np.clip(reference[-2] + src, 0, 1), np.clip(reference[-1], 0, 1)] + reference[2:6]
                errors = {name: float(np.max(np.abs(a - b))) for name, a, b in zip(NAMES[:6], actual, expected)}
                for a, b in zip(actual, expected):
                    np.testing.assert_allclose(a, b, rtol=1e-6, atol=1e-6)
                states_a[eye] = {f'r{i+1}i': v for i, v in enumerate(reference[2:6])}
                states_b[eye] = {f'r{i+1}i': v for i, v in enumerate(actual[2:6])}
                row = dict(scenario=scenario, index=index, eye=eye, errors=errors,
                    old_foreground_above_half=int(np.count_nonzero(reference[1] > .5)),
                    new_foreground_above_half=int(np.count_nonzero(actual[1] > .5)),
                    old_new_alpha_max_difference=float(np.max(np.abs(actual[1] - reference[1]))),
                    input_sha256=hashlib.sha256(src.tobytes()).hexdigest())
                (synthetic if scenario == 'synthetic' else rows).append(row)
                colors.append(src[0].transpose(1, 2, 0))
                old_masks.append(reference[1][0, 0])
                new_masks.append(actual[1][0, 0])
            if scenario == 'captured_motion' and index in [0, count // 2, count - 1]:
                color = np.concatenate(colors, axis=1)
                old = np.concatenate(old_masks, axis=1)
                new = np.concatenate(new_masks, axis=1)
                yy, xx = np.indices(old.shape)
                bg = np.where(((xx // 16 + yy // 16) % 2)[..., None], .12, .25)
                picture = np.concatenate([color, np.repeat(old[..., None], 3, axis=2),
                    np.repeat(new[..., None], 3, axis=2), color * old[..., None] + bg * (1-old[..., None]),
                    color * new[..., None] + bg * (1-new[..., None])], axis=0)
                cv2.imwrite(str(OUT / f'branch-motion-{index:03}.png'), (np.clip(picture[..., ::-1], 0, 1) * 255).astype(np.uint8))
            print(json.dumps(dict(scenario=scenario, index=index, state='base_projection_parity_passed')), flush=True)
    result = dict(state='passed_released_graph_base_projection_parity', branch_model_sha256=sha(candidate_model),
        original_model_sha256=sha(source), exposed_oracle_sha256=sha(OUT / 'released-with-base-outputs.onnx'),
        motion_report_sha256=sha(MOTION / 'report.json'), synthetic=synthetic, motion=rows,
        max_branch_error=max(max(row['errors'].values()) for row in synthetic + rows),
        states_unchanged=True, input_frame_order_unchanged=True,
        upstream_PyTorch_checkpoint_parity_verified=False, person_quality_verified=False,
        production_enabled=False, scope='Distinct eyes, four synthetic and twelve captured real frames; own complete states, same base projection, old/new Alpha intentionally different')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: value for key, value in result.items() if key not in ['synthetic', 'motion']}), flush=True)

if __name__ == '__main__':
    main()
