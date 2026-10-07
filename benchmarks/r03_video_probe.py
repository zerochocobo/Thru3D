"""Collect exact Quest RGB/Alpha buffers and compare full eye recurrence with ONNX."""
from __future__ import annotations

import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zlib

import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]


def validate(report: dict) -> list[dict]:
    if report.get('rvm_probe') is not True or report['state']['state'] != 'ended':
        raise ValueError('Expected completed real video RVM probe')
    pairs = report['rvm_pairs']
    if len(pairs) != 8 or report['state']['held_slots'] != 0:
        raise ValueError('Expected exactly eight completed pairs and all leases retired')
    previous = (-1, -1)
    for ordinal, pair in enumerate(pairs, 1):
        kernel = pair['kernel']
        if (pair['session_id'] != report['session_id'] or pair['probe_ordinal'] != ordinal or
                pair['logical_session_id'] != kernel['session_id'] or
                pair['model_generation'] != kernel['generation'] or
                pair['frame_id'] != kernel['frame_id'] or pair['pts_us'] != kernel['pts_us'] or
                pair['profile_key'] != kernel['profile_key'] or kernel['state'] != 'ready' or
                not pair['inference_ran'] or not pair['pair_identity_verified'] or
                not pair['source_pts_verified'] or not pair['immutable_color_frame'] or
                pair['slot_token'] <= 0 or pair['pair_presented']):
            raise ValueError('Pair source/model identity or implementation scope mismatch')
        current = pair['frame_id'], pair['pts_us']
        if current[0] <= previous[0] or current[1] < previous[1]:
            raise ValueError('Nonmonotonic completed RVM input sequence')
        previous = current
        first = pairs[0]
        if any(pair[key] != first[key] for key in ('generation', 'logical_session_id', 'effect_revision',
                                                 'model_generation', 'format_revision', 'profile_key')):
            raise ValueError('Unexpected reset or format change in probe sequence')
        expected_directory = f"rvm_video_{report['diagnostic_process']}_{report['session_id']}"
        if (pair['evidence_directory'] != expected_directory or
                not re.fullmatch(r'rvm_video_[a-f0-9-]{36}_[0-9]+', expected_directory)):
            raise ValueError('Binary evidence belongs to another process/session')
        expected_names = {f'{eye}_{kind}' for eye in ('left', 'right') for kind in ('rgb', 'alpha')}
        if set(pair['evidence_files']) != expected_names:
            raise ValueError('Missing or extra evidence buffers')
        for name, record in pair['evidence_files'].items():
            if record['file'] != f"pair_{ordinal}_{pair['frame_id']}_{name}.f32":
                raise ValueError('Binary filename/source frame association mismatch')
        if pair['alpha_gpu_uploaded']:
            if (not pair['alpha_fence_ready'] or pair['alpha_texture_id'] <= 0 or
                    pair['alpha_width'] != pair['input_width']*2 or pair['alpha_height'] != pair['input_height'] or
                    pair['alpha_texture_format'] != 'GL_R8_numeric' or pair['alpha_slot_token'] != pair['slot_token'] or
                    pair['alpha_frame_id'] != pair['frame_id'] or pair['alpha_pts_us'] != pair['pts_us'] or
                    pair['alpha_gpu_evidence']['file'] != f"pair_{ordinal}_{pair['frame_id']}_alpha_gpu.u8"):
                raise ValueError('Alpha GPU/source slot identity mismatch')
    return pairs


def read_buffer(path: Path, record: dict, shape: list[int]) -> np.ndarray:
    blob = path.read_bytes()
    if len(blob) != record['bytes'] or len(blob) != int(np.prod(shape)) * 4 or zlib.crc32(blob) != record['crc32']:
        raise ValueError(f'Buffer size/CRC mismatch: {path.name}')
    values = np.frombuffer(blob, dtype='<f4').reshape(shape)
    if not np.isfinite(values).all() or values.min() < 0 or values.max() > 1:
        raise ValueError(f'Expected finite numeric [0,1] buffer: {path.name}')
    return values


def collect(args: argparse.Namespace, report: dict) -> None:
    pairs = validate(report)
    for pair in pairs:
        directory = pair['evidence_directory']
        if not re.fullmatch(r'rvm_video_[a-f0-9-]{36}_[0-9]+', directory):
            raise ValueError('Invalid device evidence directory')
        records = list(pair['evidence_files'].values())
        if pair['alpha_gpu_uploaded']:
            records.append(pair['alpha_gpu_evidence'])
        for record in records:
            filename = record['file']
            if not re.fullmatch(r'pair_[1-8]_[0-9]+_(?:(?:left|right)_(?:rgb|alpha)\.f32|alpha_gpu\.u8)', filename):
                raise ValueError('Invalid evidence filename')
            # subprocess bytes preserve Float32 data, including zero/non-UTF8 bytes.
            process = subprocess.run([args.adb, '-s', args.serial, 'exec-out', 'run-as',
                                      'org.vrpassthroughplayer.quest', 'cat',
                                      f'files/diagnostics/{directory}/{filename}'],
                                     check=True, capture_output=True, timeout=20)
            blob = process.stdout
            if len(blob) != record['bytes'] or zlib.crc32(blob) != record['crc32']:
                raise ValueError('Device binary missing, incomplete or changed')
            target = args.report.parent / directory / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(blob)
    print(json.dumps({'state': 'collected', 'pairs': len(pairs), 'buffers': sum(4+int(p['alpha_gpu_uploaded']) for p in pairs)}))


def verify_gpu(args: argparse.Namespace, report: dict) -> None:
    pairs = validate(report)
    required = {'no_mask_before_upload', 'wrong_right_capacity', 'overlapping_eyes',
                'bad_right_no_partial_upload', 'immutable_mask_rejects_second_upload', 'wrong_readback_capacity',
                'upload_gl_state_restore', 'readback_gl_state_restore'}
    results = []
    for pair in pairs:
        if not pair['alpha_gpu_uploaded']:
            raise ValueError('Expected actual Alpha GPU upload evidence')
        checks = pair['alpha_upload_checks']
        wanted = required if pair['probe_ordinal'] == 1 else {'upload_gl_state_restore', 'readback_gl_state_restore'}
        if {c['case'] for c in checks} != wanted or any(c['state'] != 'passed' for c in checks):
            raise ValueError('Missing/failed actual JNI Alpha rejection or pixel-store/PBO restoration checks')
        w, h = pair['input_width'], pair['input_height']
        directory = args.report.parent / pair['evidence_directory']
        record = pair['alpha_gpu_evidence']
        blob = (directory/record['file']).read_bytes()
        if len(blob) != w*h*2 or len(blob) != record['bytes'] or zlib.crc32(blob) != record['crc32']:
            raise ValueError('GPU Alpha size/CRC mismatch')
        actual = np.frombuffer(blob, dtype=np.uint8).reshape(h,w*2)
        planes = []
        for eye in ('left', 'right'):
            raw = pair['evidence_files'][f'{eye}_alpha']
            planes.append(read_buffer(directory/raw['file'], raw, [1,1,h,w])[0,0])
        values = np.concatenate(planes, axis=1)
        # Match the specified positive nearest-byte rounding after the FP32 product.
        expected = np.floor((values*np.float32(255)).astype(np.float64)+.5).astype(np.uint8)
        mismatches = int(np.count_nonzero(expected != actual))
        maximum = float(np.abs(actual.astype(np.float64)/255-values.astype(np.float64)).max())
        passed = mismatches == 0 and maximum <= 1/510+1e-7
        results.append({'frame_id':pair['frame_id'], 'pts_us':pair['pts_us'], 'pixels':w*h*2,
                        'byte_mismatches':mismatches, 'quantization_max_abs':maximum,
                        'jni_and_state_checks':len(checks), 'state':'passed' if passed else 'failed'})
    result = {'schema_version':1, 'state':'passed' if all(r['state']=='passed' for r in results) else 'failed',
              'diagnostic_process':report['diagnostic_process'], 'session_id':report['session_id'],
              'quantization_limit':1/510, 'pairs':8, 'pixels':sum(r['pixels'] for r in results),
              'scope':'Native R8 GPU upload/fence/readback, exact eye/row packing and JNI/GL state; Godot display pending',
              'results':results}
    output = args.report.with_name(args.report.stem+'_alpha_gpu.json')
    output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'state':result['state'], 'report':str(output), 'pixels':result['pixels'],
                      'max_quantization_abs':max(r['quantization_max_abs'] for r in results)}))
    if result['state'] != 'passed':
        raise ValueError('Alpha GPU roundtrip failed; preserve original evidence')


def verify_rgb(args: argparse.Namespace, report: dict) -> None:
    from r02_controlled_probes import FIXTURES, surface_color_reference
    pairs = validate(report)
    fixture = args.report.stem.removeprefix('controlled_')
    if fixture not in FIXTURES:
        raise ValueError('Only owned fixtures have an independent source reference')
    results = []
    limit = .08  # Unchanged R02 SDR conversion/interpolation bound.
    for pair in pairs:
        w,h,iw,ih = pair['width'],pair['height'],pair['input_width'],pair['input_height']
        command = [args.ffmpeg,'-hide_banner','-loglevel','error','-ss',str(pair['pts_us']/1e6),
                   '-i',str(ROOT/'app/godot/media'/f'{fixture}.mp4'),'-frames:v','1',
                   '-f','rawvideo','-pix_fmt','yuv420p','pipe:1']
        blob = subprocess.run(command,check=True,capture_output=True,timeout=30).stdout
        size = w*h
        if w % 2 or h % 2 or len(blob) != size*3//2:
            raise ValueError('Expected one complete independently decoded YUV420 source frame')
        raw = np.frombuffer(blob,dtype=np.uint8).astype(np.float32)
        planes = raw[:size].reshape(h,w),raw[size:size*5//4].reshape(h//2,w//2),raw[size*5//4:].reshape(h//2,w//2)
        color, reference = surface_color_reference(np.empty((h,w,3),np.float32),pair,fixture,args.ffmpeg,planes)
        rect = pair['model_content_rect']
        px = ((np.arange(iw,dtype=np.float32)+.5)/iw-rect[0])/rect[2]
        py = ((np.arange(ih,dtype=np.float32)+.5)/ih-rect[1])/rect[3]
        ew = w//2 if pair['stereo_sbs'] else w
        inside = (px[None,:]>=0)&(px[None,:]<=1)&(py[:,None]>=0)&(py[:,None]<=1)
        for eye, label in enumerate(('left','right')):
            xmap = np.broadcast_to((np.clip(px*ew-.5,0,ew-1)+(eye*ew if pair['stereo_sbs'] else 0))[None,:],(ih,iw)).copy()
            ymap = np.broadcast_to(np.clip(py*h-.5,0,h-1)[:,None],(ih,iw)).copy()
            expected = cv2_remap(color,xmap,ymap)
            expected[~inside] = 0
            expected = np.rint(expected*255).clip(0,255).astype(np.float32)/255
            record = pair['evidence_files'][f'{label}_rgb']
            actual = read_buffer(args.report.parent/pair['evidence_directory']/record['file'],record,[1,3,ih,iw])[0].transpose(1,2,0)
            errors = np.abs(actual-expected)
            maximum = float(errors.max())
            results.append({'eye':label,'frame_id':pair['frame_id'],'pts_us':pair['pts_us'],
                            'values':int(errors.size),'max_abs':maximum,'rms':float(np.sqrt(np.mean(errors**2))),
                            'source_reference':reference,'state':'passed' if maximum<=limit else 'failed'})
    result = {'schema_version':1,'state':'passed' if all(r['state']=='passed' for r in results) else 'failed',
              'diagnostic_process':report['diagnostic_process'],'session_id':report['session_id'],'rgb_max_abs_limit':limit,
              'values':sum(r['values'] for r in results),'results':results,
              'scope':'All captured model RGB values vs explicit centered bilinear YUV420/BT709, SPS and actual producer transform; generic format/visual quality pending'}
    output = args.report.with_name(args.report.stem+'_rgb_yuv.json')
    output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'state':result['state'],'report':str(output),'values':result['values'],
                      'max_abs':max(r['max_abs'] for r in results)}))
    if result['state'] != 'passed':
        raise ValueError('Independent full RGB source comparison failed')


def cv2_remap(color: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    import cv2
    return cv2.remap(color,x,y,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)


def verify(args: argparse.Namespace, report: dict) -> None:
    pairs = validate(report)
    profile_key = pairs[0]['profile_key']
    allowed = json.loads((ROOT/'models/manifest/rvm_profiles.json').read_text())
    if profile_key not in [p['key'] for p in allowed['profiles']]:
        raise ValueError('Unknown RVM profile')
    profile_dir = ROOT / 'build/rvm' / profile_key
    profile = json.loads((profile_dir / 'profile.json').read_text())
    model = profile_dir / 'rvm.fixed.onnx'
    if hashlib.sha256(model.read_bytes()).hexdigest() != profile['onnx_fixed_sha256']:
        raise ValueError('ONNX reference differs from conversion manifest')
    session = ort.InferenceSession(str(model), providers=['CPUExecutionProvider'])
    states = {eye: {name: np.zeros(shape, dtype=np.float32) for name, shape in profile['input_shapes'].items()
                    if name != 'src'} for eye in ('left', 'right')}
    results = []
    desktop = None
    if args.desktop_cpu:
        from rvm_ncnn_reference import NcnnRvm
        desktop = NcnnRvm(profile_dir, profile)
    limit = 1e-5  # Fixed before execution; stricter than the desktop R01 1e-4 bound.
    for pair in pairs:
        if [pair['input_width'], pair['input_height']] != [profile['input_shapes']['src'][3], profile['input_shapes']['src'][2]]:
            raise ValueError('Descriptor/input shape mismatch')
        directory = args.report.parent / pair['evidence_directory']
        for eye in ('left', 'right'):
            rgb_record = pair['evidence_files'][f'{eye}_rgb']
            alpha_record = pair['evidence_files'][f'{eye}_alpha']
            rgb = read_buffer(directory/rgb_record['file'], rgb_record, profile['input_shapes']['src'])
            alpha = read_buffer(directory/alpha_record['file'], alpha_record, profile['output_shapes']['pha'])
            outputs = session.run(None, {'src': rgb, **states[eye]})
            states[eye] = {f'r{i+1}i': state for i, state in enumerate(outputs[2:])}
            error = np.abs(alpha-outputs[1])
            results.append({'eye': eye, 'frame_id': pair['frame_id'], 'pts_us': pair['pts_us'],
                            'max_abs': float(error.max()), 'rms': float(np.sqrt(np.mean(error ** 2))),
                            'state': 'passed' if error.max() < limit else 'failed'})
            if desktop is not None:
                cpu_alpha = desktop.process(eye, rgb)[1]
                results[-1]['desktop_cpu_onnx_max_abs'] = float(np.abs(cpu_alpha-outputs[1]).max())
                results[-1]['quest_desktop_cpu_max_abs'] = float(np.abs(cpu_alpha-alpha).max())
    result = {'schema_version': 1, 'state': 'passed' if all(r['state'] == 'passed' for r in results) else 'failed',
              'diagnostic_process': report['diagnostic_process'], 'session_id': report['session_id'],
              'profile_key': profile_key, 'alpha_max_abs_limit': limit, 'pairs': 8, 'eye_comparisons': 16,
              'scope': 'Exact captured RGB, independent full eye recurrence and Float32 Alpha; GPU roundtrip checked separately; display/audio/quality pending',
              'results': results}
    if desktop is not None:
        desktop.close()
    output = args.report.with_name(args.report.stem+('_onnx_cpu_analysis.json' if args.desktop_cpu else '_onnx.json'))
    output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'state': result['state'], 'report': str(output), 'max_abs': max(r['max_abs'] for r in results)}))
    if result['state'] != 'passed':
        raise ValueError('Video Alpha ONNX comparison failed; preserve original evidence')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('collect', 'verify', 'verify-gpu', 'verify-rgb'))
    parser.add_argument('report', type=Path)
    parser.add_argument('--adb', default=str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'android-sdk/platform-tools/adb.exe'))
    parser.add_argument('--serial', default='2G0YC5ZF7V0664')
    parser.add_argument('--desktop-cpu', action='store_true', help='Add independent desktop ncnn FP32 analysis; keep original acceptance threshold')
    parser.add_argument('--ffmpeg',default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    report = json.loads(args.report.read_text(encoding='utf-8-sig'))
    {'collect':collect, 'verify':verify, 'verify-gpu':verify_gpu,'verify-rgb':verify_rgb}[args.action](args, report)


if __name__ == '__main__':
    main()
