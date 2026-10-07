"""Compare dense Quest GPU Alpha with sparse ORT recurrence on identical RGB.

CPU is an independent trajectory control, never a playback/inference FPS claim.
Both eyes retain their own complete recurrent states. No crop or weight changes.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

from mpv_motion_probe import ROOT, buffer, read, require, sha, validate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--sparse-report', type=Path, required=True)
    args = parser.parse_args()
    report = read(args.report)
    records = validate(report)
    require(report.get('ordered_frames') is True, 'Requires complete ordered GPU acquisition')
    sparse = read(args.sparse_report)
    sparse_records = validate(sparse)
    require(sparse['fixture_sha256'] == report['fixture_sha256'] and sparse['profile'] == report['profile'],
            'Sparse source/profile differs')
    points = {p['pts_us'] for p in sparse_records}
    require(len(points) < 180 and points <= {p['pts_us'] for p in records}, 'Sparse timeline differs')
    profile_dir = ROOT / 'build/rvm' / report['profile']
    profile = read(profile_dir / 'profile.json')
    require(sha(profile_dir / 'rvm.fixed.onnx') == profile['onnx_fixed_sha256'], 'Reference model changed')
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    session = ort.InferenceSession(str(profile_dir / 'rvm.fixed.onnx'), sess_options=options,
                                   providers=['CPUExecutionProvider'])
    states = [{k: np.zeros(v, np.float32) for k, v in profile['input_shapes'].items() if k != 'src'}
              for _ in range(2)]
    width, height = map(int, report['profile'].split('x'))
    directory = args.report.parent / report['evidence_directory']
    output = args.report.parent / 'temporal-control'
    output.mkdir(exist_ok=True)
    rows = []
    for pair in records:
        if pair['pts_us'] not in points:
            continue
        images = []
        for eye, label in enumerate(('left', 'right')):
            rgb = buffer(directory, pair['files'][label + '_rgb'], [1, 3, height, width])
            dense = buffer(directory, pair['files'][label + '_alpha'], [1, 1, height, width])
            outputs = session.run(['pha', 'r1o', 'r2o', 'r3o', 'r4o'], {'src': rgb, **states[eye]})
            states[eye] = {f'r{i+1}i': v for i, v in enumerate(outputs[1:])}
            sparse_alpha = outputs[0]
            require(np.isfinite(sparse_alpha).all(), 'Nonfinite sparse reference')
            difference = np.abs(dense - sparse_alpha)
            rows.append(dict(ordinal=pair['ordinal'], pts_us=pair['pts_us'], eye=label,
                             max_abs=float(difference.max()), rms=float(np.sqrt(np.mean(difference ** 2))),
                             dense_foreground=int(np.count_nonzero(dense > .5)),
                             sparse_foreground=int(np.count_nonzero(sparse_alpha > .5))))
            color = rgb[0].transpose(1, 2, 0)
            yy, xx = np.indices((height, width))
            background = np.where(((xx // 16 + yy // 16) % 2)[..., None], .12, .25)
            layers = [color]
            for alpha in (dense[0, 0], sparse_alpha[0, 0]):
                layers.extend([np.repeat(alpha[..., None], 3, axis=2),
                               color * alpha[..., None] + background * (1 - alpha[..., None])])
            images.append(np.concatenate(layers, axis=0))
        image = np.concatenate(images, axis=1)
        path = output / f"source_{pair['ordinal']-1:03d}.png"
        require(cv2.imwrite(str(path), (np.clip(image[..., ::-1], 0, 1) * 255).astype(np.uint8)),
                'Preview write failed')
        print(pair['ordinal'], flush=True)
    require(len(rows) == len(points) * 2, 'Sparse control omitted an eye/frame')
    result = dict(state='completed_trajectory_comparison', report_sha256=sha(args.report),
                  sparse_timeline_report_sha256=sha(args.sparse_report), tool_sha256=sha(Path(__file__)),
                  reference_model_sha256=profile['onnx_fixed_sha256'], source_sha256=report['fixture_sha256'],
                  source_indices=[p['ordinal']-1 for p in records if p['pts_us'] in points], results=rows,
                  preview_rows=['source', 'dense_Quest_GPU_Alpha', 'dense_composite',
                                'sparse_CPU_reference_Alpha', 'sparse_composite'],
                  independent_quality_ground_truth=False, fps_verified=False,
                  scope='Same captured RGB; dense GPU versus sparse CPU recurrence. Numeric differences include '
                        'backend rounding; dense GPU/CPU precision is checked separately by the motion probe.')
    (output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k != 'results'}), flush=True)


if __name__ == '__main__':
    main()
