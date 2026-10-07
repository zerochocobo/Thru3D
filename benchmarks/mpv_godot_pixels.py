"""Independently verify actual Godot readback of one pinned MPV/RVM pair.

The SubViewport selects eyes through swap on VIEW_INDEX=0. XR projection,
main viewport, ONNX quality, audio and sustained performance remain unverified.
"""
import os
from pathlib import Path
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def rotation(u, v, degrees):
    return {0: (u, v), 90: (v, 1-u), 180: (1-u, 1-v), 270: (1-v, u)}[degrees]


def verify(report, directory, reference, pts, ffmpeg=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), expect_normal=False):
    probe = report['pixel_probe']
    pair = probe['pair']
    if (probe['state'] != 'captured' or not probe['native_pin_released'] or not probe['wrappers_detached'] or
            probe['request_id'] != report['request_id'] or not report['diagnostic_2d'] or
            (pair['width'], pair['height'], pair['rotation_degrees']) != (1280, 640, 0) or not pair['stereo_sbs'] or
            not pair['alpha_fence_ready'] or not pair['consumer_copy_fence_ready']):
        raise ValueError('Pinned capture identity/state/scope failed')
    if expect_normal:
        native=report['native_status']
        if (pair['alpha_requested'] or pair['inference_ran'] or pair.get('alpha_kind')!='opaque_numeric_mask' or
                not native['normal_fast_path'] or native['rvm_model_created'] or native['bridge']['input_stages']!=0 or
                native['bridge']['regular_alpha_uploads']!=0 or native['bridge']['opaque_copies']<1):
            raise ValueError('Normal cached opaque path was not used')
    elif not pair['alpha_requested'] or not pair['inference_ran']:
        raise ValueError('RVM Alpha path was not used')
    index = min(range(len(pts)), key=lambda i: abs(pts[i]-pair['pts_us']))
    if index != 60 or abs(pts[index]-pair['pts_us']) > 1:
        raise ValueError('Expected exact paused frame at 2 seconds')
    mask = probe['mask_reference']
    if mask['state'] != 'ready' or mask['mask_origin'] != 'same_pinned_pair_native_R8_readback':
        raise ValueError('Missing actual same-pair numeric mask')
    for key in ('session_id', 'logical_session_id', 'generation', 'source_epoch', 'frame_id', 'pts_us',
                'slot_token', 'alpha_slot_token', 'alpha_frame_id', 'alpha_pts_us'):
        if pair[key] != mask['pair'][key]:
            raise ValueError('Mask identity differs from rendered pair')
    iw, ih = int(pair['input_width']), int(pair['input_height'])
    data = np.frombuffer((directory / mask['mask_file']).read_bytes(), np.uint8)
    if data.size != iw*ih*2 or mask['mask_bytes'] != data.size:
        raise ValueError('R8 mask byte count differs from model dimensions')
    data = data.reshape(ih, iw*2)
    if expect_normal and not np.all(data==255):
        raise ValueError('Ordinary playback R8 must be exactly opaque in every pixel')
    analytic = probe['analytic_material_probe']
    if (analytic['state'] != 'passed' or len(analytic['samples']) != 288 or analytic['failures'] or
            analytic['borrow_cycles'] != 3 or analytic['invalid_descriptors'] != 11 or
            any(s['max_abs'] > .012 for s in analytic['samples'])):
        raise ValueError('Nonuniform analytic Alpha/material checks failed')
    images = probe['images']
    expected_cases = {(eye, angle, masked) for eye in (0, 1) for angle in (0, 90, 180, 270) for masked in (False, True)}
    if len(images) != 16 or {(i['eye'], i['rotation'], i['alpha_enabled']) for i in images} != expected_cases:
        raise ValueError('Missing or duplicate rendered eye/rotation/Alpha case')
    loaded = {}
    for item in images:
        raw = subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(directory/item['file']),
            '-frames:v', '1', '-pix_fmt', 'rgba', '-f', 'rawvideo', 'pipe:1'])
        pixels = np.frombuffer(raw, np.uint8).reshape(640, 640, 4)
        if pixels.shape != (640, 640, 4):
            raise ValueError('Unexpected viewport readback dimensions')
        loaded[item['eye'], item['rotation'], item['alpha_enabled']] = pixels
    points = [(36+50*b, 96) for b in range(12)] + [(20, 20), (620, 20), (20, 620), (620, 620), (320, 320)]
    color_max = alpha_max = composite_max = 0.
    summaries = []
    u, v = np.meshgrid((np.arange(640)+.5)/640, (np.arange(640)+.5)/640)
    rect = np.asarray(pair['model_content_rect'], np.float64)
    valid = [((np.arange(size)+.5)/size)[((np.arange(size)+.5)/size >= rect[axis]) &
             ((np.arange(size)+.5)/size <= rect[axis]+rect[axis+2])] for axis, size in enumerate((iw, ih))]
    for eye in (0, 1):
        plane = data[:, eye*iw:(eye+1)*iw].astype(np.float64)/255
        for angle in (0, 90, 180, 270):
            opaque = loaded[eye, angle, False]
            actual = loaded[eye, angle, True].astype(np.float64)
            if np.any(opaque[:, :, 3] != 255):
                raise ValueError('Opaque pair failed full viewport coverage')
            for x, y in points:
                # Invert the rotation at exact source pixel centers.
                ou, ov = rotation((x+.5)/640, (y+.5)/640, (360-angle) % 360)
                ox, oy = min(639, int(ou*640)), min(639, int(ov*640))
                error = float(np.abs(opaque[oy, ox, :3].astype(np.int16)-reference[y, x+eye*640].astype(np.int16)).max())
                color_max = max(color_max, error)
                if error > 8:
                    raise ValueError(f'Decoded source/eye/UV mismatch: eye{eye} rot{angle} ({x},{y}) {error}/255')
            pu, pv = rotation(u, v, angle)
            ax = np.clip(rect[0]+pu*rect[2], valid[0][0], valid[0][-1])*iw-.5
            ay = np.clip(rect[1]+pv*rect[3], valid[1][0], valid[1][-1])*ih-.5
            x0, y0 = np.floor(ax).astype(int), np.floor(ay).astype(int)
            x1, y1 = np.minimum(x0+1, iw-1), np.minimum(y0+1, ih-1)
            dx, dy = ax-x0, ay-y0
            alpha = ((plane[y0, x0]*(1-dx)+plane[y0, x1]*dx)*(1-dy) +
                     (plane[y1, x0]*(1-dx)+plane[y1, x1]*dx)*dy)
            ae = float(np.abs(actual[:, :, 3]-alpha*255).max())
            ce = float(np.abs(actual[:, :, :3]-opaque[:, :, :3]*alpha[:, :, None]).max())
            alpha_max, composite_max = max(alpha_max, ae), max(composite_max, ce)
            if ae > 3 or ce > 3:
                raise ValueError(f'Numeric Alpha/composite mismatch: eye{eye} rot{angle} alpha={ae}, RGB={ce}/255')
            summaries.append(dict(eye=eye, rotation=angle, alpha_max_error_bytes=ae, composite_max_error_bytes=ce))
    return dict(state='passed', opaque_source_samples=136, numeric_alpha_pixels=3276800,
        analytic_samples=288, alpha_min_byte=int(data.min()), alpha_max_byte=int(data.max()),
        source_color_max_error_bytes=color_max, numeric_alpha_max_error_bytes=alpha_max,
        composite_max_error_bytes=composite_max, cases=summaries,
        scope='Pinned numbered H264 frame60 Godot SubViewport native textures; analytic material grid. No XR/main viewport/audio/performance/ONNX quality proof.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    parser.add_argument('--output-name', choices=['pixels-verified.json','normal-pixels-verified.json','alpha-after-normal-verified.json'], default='pixels-verified.json')
    parser.add_argument('--expect-normal', action='store_true')
    args = parser.parse_args()
    report = json.loads(args.report.read_text(encoding='utf-8-sig'))
    probe = report['pixel_probe']
    directory = args.report.parent / 'pixel-files'
    directory.mkdir(exist_ok=True)
    names = [probe['mask_reference']['mask_file']] + [i['file'] for i in probe['images']]
    for name in names:
        if not re.fullmatch(r'mpv_pixel_mask_\d+\.r8|mpv_pixels_\d+_rot(0|90|180|270)_eye[01]_(alpha|opaque)\.png', name):
            raise ValueError('Unexpected diagnostic filename')
        contents = subprocess.check_output([args.adb, '-s', args.serial, 'exec-out', 'run-as',
            'org.vrpassthroughplayer.quest', 'cat', 'files/diagnostics/'+name])
        (directory/name).write_bytes(contents)
    opened = next(c for c in report['commands'] if c['operation'] == 'open')
    fixture_name = opened['title']
    if fixture_name not in ('mp03_frame_identity', 'mp05_person_still'):
        raise ValueError('Unknown independent fixture')
    fixture = json.loads((ROOT/f'tests/fixtures/{fixture_name}.json').read_text())
    video = ROOT/fixture['file']
    if hashlib.sha256(video.read_bytes()).hexdigest() != fixture['sha256']:
        raise ValueError('Independent source fixture lock changed')
    reference = np.frombuffer(subprocess.check_output([args.ffmpeg, '-v', 'error', '-ss', '2', '-i', str(video),
        '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1']), np.uint8).reshape(640, 1280, 3)
    checked = verify(report, directory, reference, fixture['pts_us'], args.ffmpeg, args.expect_normal)
    if fixture_name == 'mp05_person_still' and probe['pair']['inference_ran'] and (checked['alpha_min_byte'] != 0 or checked['alpha_max_byte'] < 128):
        raise ValueError('Person fixture did not exercise foreground and background Alpha')
    checked['fixture'] = fixture_name
    checked['source_sha256'] = fixture['sha256']
    checked['nonzero_rvm_alpha_observed'] = probe['pair']['inference_ran'] and checked['alpha_max_byte'] > 0
    rejections = []
    for name in ('wrong_pts', 'wrong_mask_ticket', 'missing_rotation', 'unreleased_pin', 'analytic_error'):
        bad = copy.deepcopy(report)
        if name == 'wrong_pts': bad['pixel_probe']['pair']['pts_us'] += 33333
        elif name == 'wrong_mask_ticket': bad['pixel_probe']['mask_reference']['pair']['slot_token'] += 1
        elif name == 'missing_rotation': bad['pixel_probe']['images'].pop()
        elif name == 'unreleased_pin': bad['pixel_probe']['native_pin_released'] = False
        else: bad['pixel_probe']['analytic_material_probe']['samples'][0]['max_abs'] = .5
        try: verify(bad, directory, reference, fixture['pts_us'], args.ffmpeg, args.expect_normal)
        except ValueError: rejections.append(name)
        else: raise ValueError('Corrupted evidence accepted: '+name)
    checked['negative_cases_rejected'] = rejections
    args.report.with_name(args.output_name).write_text(json.dumps(checked, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(checked))


if __name__ == '__main__':
    main()
