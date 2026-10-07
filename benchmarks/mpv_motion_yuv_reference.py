"""Preserve explicit source-color references and replay their full-buffer checks."""
import os
from pathlib import Path
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
from unittest.mock import patch
import uuid

import numpy as np
import mpv_motion_probe as probe

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def stats(actual, reference):
    delta = np.abs(actual-reference)
    channel, y, x = np.unravel_index(int(np.argmax(delta)), delta.shape[1:])
    return dict(values=delta.size, max_abs=float(delta.max()), rms=float(np.sqrt(np.mean(delta**2))),
                values_above_limit=int(np.count_nonzero(delta > probe.RGB_LIMIT)),
                peak=dict(channel=int(channel), x=int(x), y=int(y),
                          actual=float(actual[0, channel, y, x]), reference=float(reference[0, channel, y, x])))


def audit(directory):
    report = read(directory / 'report.json')
    assert report['rgb_limit'] == .08 and report['source_sha256'] == probe.sha(ROOT / report['source'])
    assert report['reference_recipe_sha256'] == probe.sha(directory / 'reference-recipe.py')
    assert report['collector_sha256'] == probe.sha(directory / 'collector.py')
    total = 0
    for case in report['cases']:
        trace = ROOT / case['trace']
        native = read(trace / 'report.json')
        records = probe.validate(native)
        width, height = map(int, native['profile'].split('x'))
        assert case['profile'] == native['profile'] and case['native_report_sha256'] == probe.sha(trace / 'report.json')
        assert case['native_log_sha256'] == probe.sha(trace / 'logcat.txt')
        assert native['fixture_sha256'] == report['source_sha256']
        installed = read(trace / 'installed.json')
        assert installed['apk_sha256'] == installed['installed_sha256'] == case['captured_apk_sha256']
        assert len(case['rows']) == len(records)*2
        pairs = {(pair['ordinal'], eye): pair for pair in records for eye in ['left', 'right']}
        assert {(row['ordinal'], row['eye']) for row in case['rows']} == set(pairs)
        for row in case['rows']:
            path = directory / row['file']
            assert probe.sha(path) == row['sha256']
            pair = pairs[row['ordinal'], row['eye']]
            assert row['pts_us'] == pair['pts_us'] and row['frame_id'] == pair['frame_id']
            assert row['source_index'] == round(pair['pts_us']*30/1e6)
            with np.load(path, allow_pickle=False) as saved:
                actual, reference = saved['actual'], saved['reference']
                assert actual.shape == reference.shape == (1, 3, height, width)
                assert actual.dtype == reference.dtype == np.float32
                assert np.isfinite(actual).all() and np.isfinite(reference).all()
                assert 0 <= actual.min() <= actual.max() <= 1 and 0 <= reference.min() <= reference.max() <= 1
                assert hashlib.sha256(actual.tobytes()).hexdigest() == pair['files'][row['eye']+'_rgb']['sha256']
                assert stats(actual, reference) == row['comparison']
                assert row['comparison']['max_abs'] <= .08 and row['comparison']['values_above_limit'] == 0
                total += actual.size
        color_gate = read(trace / 'motion-yuv-aspect-verified.json')
        assert probe.sha(trace / 'motion-yuv-aspect-verified.json') == case['joint_verifier_report_sha256']
        assert color_gate['source_sha256'] == report['source_sha256']
        assert color_gate['apk_sha256'] == case['captured_apk_sha256']
        assert color_gate['report_sha256'] == case['native_report_sha256']
        assert color_gate['verifier_sha256'] == report['reference_recipe_sha256']
        assert color_gate['rgb_max_abs_limit'] == .08 and color_gate['alpha_max_abs_limit'] == 1e-5
        assert color_gate['rgb_reference_state'] == 'passed' and color_gate['packed_R8_state'] == 'passed'
        assert color_gate['rgb_max_abs'] == max(row['comparison']['max_abs'] for row in case['rows'])
        assert not color_gate['quality_subjectively_verified'] and not color_gate['sustained_fps_verified']
    assert total == report['rgb_values_checked']
    assert report['unsupported_reference_cases_rejected'] == ['missing_RGBA16F', 'missing_OES', 'wrong_chroma',
        'missing_linear_shader', 'wrong_BT709', 'wrong_timeline']
    result = dict(state='passed_scoped_explicit_YUV_color_reference', rgb_values_checked=total,
                  cases=len(report['cases']), person_quality_verified=False, playback_fps_verified=False,
                  native_OES_conversion_algorithm_independently_verified=False,
                  scope='Source FFmpeg YUV420 and logged BT709/centered OES/linear RGBA16F/aspect, full actual input buffers; no generic driver/color-space claim')
    write(directory / 'verification.json', result)
    print(json.dumps(result), flush=True)


def run(traces, output):
    output.mkdir(parents=True)
    shutil.copy2(__file__, output / 'collector.py')
    shutil.copy2(probe.__file__, output / 'reference-recipe.py')
    fixture = read(ROOT / 'tests/fixtures/mp07_motion_4k.json')
    video = ROOT / fixture['file']
    assert probe.sha(video) == fixture['sha256']
    report = dict(source=fixture['file'], source_sha256=fixture['sha256'], rgb_limit=.08,
                  reference_recipe_sha256=probe.sha(output / 'reference-recipe.py'),
                  collector_sha256=probe.sha(output / 'collector.py'), cases=[], rgb_values_checked=0,
                  production_model_changed=False, production_APK_changed=False)
    for ordinal, trace in enumerate(traces):
        trace = trace.resolve()
        native = read(trace / 'report.json')
        records = probe.validate(native)
        width, height = map(int, native['profile'].split('x'))
        log = (trace / 'logcat.txt').read_text(encoding='utf-8-sig')
        indices, references = probe.source_references(video, records, width, height, os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), log, True)
        case_dir = output / f'case_{ordinal}'
        case_dir.mkdir()
        case = dict(trace=trace.relative_to(ROOT).as_posix(), profile=native['profile'], rows=[],
                    captured_apk_sha256=read(trace / 'installed.json')['apk_sha256'],
                    native_report_sha256=probe.sha(trace / 'report.json'), native_log_sha256=probe.sha(trace / 'logcat.txt'),
                    joint_verifier_report_sha256=probe.sha(trace / 'motion-yuv-aspect-verified.json'))
        for pair, index in zip(records, indices):
            for eye_index, eye in enumerate(['left', 'right']):
                actual = probe.buffer(trace / native['evidence_directory'], pair['files'][eye+'_rgb'], (1,3,height,width))
                reference = references[index][eye_index]
                path = case_dir / f'{pair["ordinal"]:03}_{eye}.npz'
                np.savez_compressed(path, actual=actual, reference=reference)
                comparison = stats(actual, reference)
                case['rows'].append(dict(ordinal=pair['ordinal'], eye=eye, source_index=index, frame_id=pair['frame_id'],
                    pts_us=pair['pts_us'], file=path.relative_to(output).as_posix(), sha256=probe.sha(path), comparison=comparison))
                report['rgb_values_checked'] += actual.size
        report['cases'].append(case)
        write(output / 'report.json', report)
        print(json.dumps(dict(trace=case['trace'], state='color_buffers_saved',
                              maximum=max(row['comparison']['max_abs'] for row in case['rows']))), flush=True)
    # Reject missing/wrong metadata before any full-frame decoder is started.
    native = read(traces[0] / 'report.json')
    records = probe.validate(native)
    width, height = map(int, native['profile'].split('x'))
    log = (traces[0] / 'logcat.txt').read_text(encoding='utf-8-sig')
    rejected = []
    for name, poisoned in [('missing_RGBA16F', log.replace('Using FBO format rgba16f.', 'Using FBO format rgba8.')),
                           ('missing_OES', log.replace('samplerExternalOES texture0', 'sampler2D texture0')),
                           ('wrong_chroma', log.replace('CL=mpeg1/jpeg', 'CL=left')),
                           ('missing_linear_shader', log.replace('pow(color.rgb, vec3(2.4))', 'color.rgb'))]:
        try:
            probe.source_references(video, records, width, height, os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), poisoned, True)
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError('Unsupported reference accepted: ' + name)
    real_check = probe.subprocess.check_output
    for name in ['wrong_BT709', 'wrong_timeline']:
        def poisoned_probe(command, **kwargs):
            blob = real_check(command, **kwargs)
            value = json.loads(blob)
            if name == 'wrong_BT709' and 'stream=pix_fmt,color_range,color_space,color_transfer,color_primaries' in command:
                value['streams'][0]['color_space'] = 'bt470bg'
            if name == 'wrong_timeline' and 'frame=best_effort_timestamp_time' in command:
                value['frames'][1]['best_effort_timestamp_time'] = '0.099999'
            return json.dumps(value).encode()
        with patch.object(probe.subprocess, 'check_output', side_effect=poisoned_probe):
            try:
                probe.source_references(video, records, width, height, os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), log, True)
            except ValueError:
                rejected.append(name)
            else:
                raise ValueError('Unsupported reference accepted: ' + name)
    report['unsupported_reference_cases_rejected'] = rejected
    write(output / 'report.json', report)
    audit(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--traces', type=Path, nargs='+')
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.verify:
        audit(args.verify)
    else:
        assert args.traces
        output = args.output or ROOT / 'artifacts/r08-color-reference' / (datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:8])
        run(args.traces, output)
