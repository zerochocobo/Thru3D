"""Independent code/PTS checks for the production native source/shared RVM test.

The consumer is a debug pbuffer. This cannot validate Godot/OpenXR presentation,
audio, RVM accuracy against ONNX, every decoded frame or sustained performance.
"""
import os
from pathlib import Path
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def verify(report, ffmpeg):
    manifest = json.loads((ROOT / 'tests/fixtures/mp03_frame_identity.json').read_text())
    source = ROOT / manifest['file']
    if hashlib.sha256(source.read_bytes()).hexdigest() != manifest['sha256']:
        raise ValueError('Source fixture bytes changed')
    metadata = json.loads(subprocess.check_output([
        str(Path(ffmpeg).with_name('ffprobe.exe')), '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(source)]))
    pts = [round(float(f['best_effort_timestamp_time']) * 1e6) for f in metadata['frames']]
    if pts != manifest['pts_us']:
        raise ValueError('Encoded PTS differ from the fixture lock')
    raw = subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(source), '-vf', 'crop=1280:2:0:96',
                                  '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1'])
    reference = np.frombuffer(raw, np.uint8).reshape(180, 2, 1280, 3)
    expected = np.stack([reference[:, 0, x, :] for x, _ in manifest['sample_points']], axis=1)
    forbidden = ('godot_context_shared', 'godot_display_verified', 'xr_verified', 'audio_verified', 'performance_verified')
    if (report['schema_version'] != 4 or report['state'] != 'passed_native_checks' or not report['resources_closed'] or report['source_pts_verified'] or
            report['consumer_context_origin'] != 'debug_offscreen_GLES_pbuffer' or
            any(report[key] for key in forbidden) or report['profile'] != '384x216'):
        raise ValueError('Native run did not pass or its verification scope is incorrect')
    status = report['native_status']
    if (status['render_failed'] or status['error'] or status['render_error'] or status['state'] != 'ended' or
            status['details']['hwdec_current'] != ('mediacodec' if report['hardware_requested'] else 'no')):
        raise ValueError('Actual hardware backend/EOS/native render status failed')
    closed = report['closed_native_status']
    if (not closed['done'] or not closed['closing'] or closed['render_failed'] or closed['error'] or
            closed['render_error'] or closed['held_slots'] or closed['retiring_slots'] or
            closed['seeks_started'] != 4 or closed['seeks_completed'] != 4):
        raise ValueError('Native source/consumer teardown or seek transactions did not finish')
    associations = {}
    maximum_color = maximum_model = 0.0
    comparisons = []

    def code(record, key):
        nonlocal maximum_color
        index = min(range(180), key=lambda i: abs(pts[i] - record['pts_us']))
        if (abs(pts[index] - record['pts_us']) > 1 or record['source_flags'] & 19 != 19 or
                not record['owner_context_shared'] or not record['producer_fence_ready'] or
                not record['immutable_color_frame'] or (record['width'], record['height']) != (1280, 640) or
                record['rotation_degrees'] != 0 or record['source_crop'] not in ([0, 0, 1280, 640], [0, 0, 0, 0])):
            raise ValueError('Invalid source ticket, dimensions, shared context or fence')
        identity = record['source_epoch'], record['frame_id']
        if min(identity) <= 0 or record['producer_token'] <= 0 or record['render_sequence'] <= 0:
            raise ValueError('Invalid source identity')
        if identity in associations and associations[identity] != record['pts_us']:
            raise ValueError('A retained frame was relabelled with a new PTS')
        associations[identity] = record['pts_us']
        pixels = np.asarray(record[key], dtype=np.int16)
        if pixels.shape != (24, 4) or np.any(pixels[:, 3] != 255):
            raise ValueError('Missing source code samples')
        error = float(np.abs(pixels[:, :3] - expected[index].astype(np.int16)).max())
        maximum_color = max(maximum_color, error)
        if error > manifest['pixel_limit_bytes']:
            raise ValueError(f'Source ticket/PTS mismatch at encoded frame {index}: {error}/255')
        for eye in range(2):
            decoded = sum((int(pixels[eye * 12 + bit, 0]) > 128) << bit for bit in range(12))
            if decoded & 255 != index or decoded >> 8 != (index ^ (index >> 4) ^ 10) & 15:
                raise ValueError('Source counter/checksum differs from its PTS')
        return index

    bounds = report['bounded_slots']
    if len(bounds) != 3 or len({x['producer_token'] for x in bounds}) != 3 or report['bounded_pool_status']['skipped'] < 3:
        raise ValueError('Three held slots did not exercise producer backpressure')
    for held in bounds:
        code(held, 'before')
        code(held, 'after')
        if held['before'] != held['after']:
            raise ValueError('A held producer color was overwritten')
    records = report['records']
    retirement = report['retirement_ack_checks']
    tokens = retirement['tokens']
    if (len(tokens) != 3 or len(set(tokens)) != 3 or min(tokens) <= 0 or
            retirement['fences_finished'] is not True or retirement['capture_before_ack'] != 0 or
            retirement['all_tokens_acknowledged'] is not True or retirement['capture_after_ack'] <= max(tokens) or
            retirement['reused_slot_retired'] is not True):
        raise ValueError('Consumer slot reused before owner retirement acknowledgement')
    if len(records) != 14:
        raise ValueError('Expected 12 seek-phase pairs, one retained EOF pair and one paused EOF restart')
    phases, generations = {}, {}
    last_token = last_sequence = last_frame = 0
    total_alpha = 0
    for record in records:
        index = code(record, 'source_code')
        rgb = np.asarray(record['model_code_rgb'], dtype=np.float64)
        if rgb.shape != (24, 3) or not np.isfinite(rgb).all() or np.any((rgb < 0) | (rgb > 1)):
            raise ValueError('Invalid model-input code samples')
        error = float(np.abs(rgb * 255 - expected[index]).max())
        maximum_model = max(maximum_model, error)
        if error > manifest['pixel_limit_bytes']:
            raise ValueError('Copied/staged model RGB differs from the same source ticket')
        if record['producer_token'] <= last_token or record['render_sequence'] <= last_sequence or record['frame_id'] <= last_frame:
            raise ValueError('Out-of-order/repeated source image submitted to recurrent RVM')
        last_token, last_sequence, last_frame = record['producer_token'], record['render_sequence'], record['frame_id']
        kernel = record['kernel']
        if (kernel['state'] != 'ready' or kernel['profile_key'] != '384x216' or
                kernel['session_id'] != 900000 + report['request_id'] or kernel['generation'] != record['model_generation'] or
                kernel['frame_id'] != record['frame_id'] or kernel['pts_us'] != record['pts_us'] or
                record['alpha_byte_mismatches'] != 0 or record['alpha_pixels_checked'] != 165888 or
                record['consumer_color_texture_id'] == record['alpha_texture_id']):
            raise ValueError('RVM result/GPU Alpha differs from its immutable color ticket')
        total_alpha += record['alpha_pixels_checked']
        phases.setdefault(record['phase'], []).append(record['source_epoch'])
        generations.setdefault(record['phase'], set()).add(record['model_generation'])
        comparisons.append({'phase': record['phase'], 'frame_id': record['frame_id'], 'pts_us': record['pts_us'],
                            'encoded_index': index, 'model_code_error_bytes': error})
    names = ['seek_0_0', 'seek_1_2000', 'seek_2_0', 'eof_retained', 'restart_after_eof']
    if set(phases) != set(names) or any(len(phases[name]) != count for name, count in zip(names, [4, 4, 4, 1, 1])):
        raise ValueError('Missing required seek/EOF phases')
    epoch = [phases[name][0] for name in names]
    if not epoch[0] > bounds[-1]['source_epoch'] or not epoch[0] < epoch[1] < epoch[2] == epoch[3] < epoch[4]:
        raise ValueError('Seek did not invalidate the old source epoch')
    if any(len(set(phases[name])) != 1 for name in names) or [generations[name] for name in names] != [{2}, {3}, {4}, {4}, {5}]:
        raise ValueError('RVM processing generation/epoch was reused across seek')
    if comparisons[-2]['encoded_index'] != 179:
        raise ValueError('Retained EOF color/Alpha pair is not the real final frame')
    if comparisons[-1]['encoded_index'] != 0 or report['restart_native_status']['details']['paused'] != 'yes':
        raise ValueError('EOF restart did not produce the exact paused first color/Alpha pair')
    final = records[-2]
    terminal = report['resolved_eof_source']
    if (not status['eof_source_resolved'] or terminal != status['eof_source_ticket'] or
            terminal['render_sequence'] <= 0 or
            any(terminal[key] != final[key] for key in ('source_epoch', 'frame_id', 'pts_us'))):
        raise ValueError('Native EOF source resolution differs from the independently verified final pair')
    gate = report['eof_gate_checks']
    if (gate['context'] != 'synthetic_ack_after_real_alpha_fence' or
            gate['completed_slot'] != final['consumer_slot'] or
            not all(gate[key] for key in ('before_draw_rejected', 'opaque_alpha_rejected',
                'penultimate_rejected', 'stale_generation_rejected', 'unacknowledged_rejected', 'final_accepted')) or
            not report['seek_invalidated_eof'] or report['restart_native_status']['eof_source_resolved'] or
            report['restart_native_status']['eof_source_ticket'] is not None):
        raise ValueError('EOF logical completion or seek invalidation protocol failed')
    return {'state': 'passed', 'source_pts_verified': True, 'sampled_pairs': len(records), 'held_producer_slots': 3,
            'native_eof_source_verified': True, 'eof_logical_gate_verified': True,
            'eof_gate_scope': 'Synthetic acknowledgement after real Alpha GPU fence; Godot owner post-draw and pixels unverified',
            'source_pixel_max_error_bytes': maximum_color, 'model_code_max_error_bytes': maximum_model,
            'gpu_alpha_pixels_checked_by_device': total_alpha, 'comparisons': comparisons,
            'scope': 'Calibration ticket/PTS/shared consumer RGB and native R8 quantization checks; no Godot/XR/audio/performance or ONNX accuracy claim'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    report = json.loads(args.report.read_text(encoding='utf-8-sig'))
    result = verify(report, args.ffmpeg)
    rejected = []
    for name in ['pts', 'model_rgb', 'overwrite', 'epoch', 'kernel', 'eof', 'restart', 'cleanup',
                 'eof_unresolved', 'eof_target', 'eof_slot', 'eof_predraw', 'eof_seek_invalidation',
                 'retirement_early_reuse', 'retirement_unacknowledged', 'retirement_token_reuse']:
        bad = copy.deepcopy(report)
        if name == 'pts':
            bad['records'][0]['pts_us'] += 33333
        elif name == 'model_rgb':
            bad['records'][0]['model_code_rgb'][0] = [0.5, 0.5, 0.5]
        elif name == 'overwrite':
            bad['bounded_slots'][0]['after'][0] = [128, 128, 128, 255]
        elif name == 'epoch':
            for r in bad['records']:
                if r['phase'] == 'seek_1_2000':
                    r['source_epoch'] = bad['records'][0]['source_epoch']
        elif name == 'kernel':
            bad['records'][0]['kernel']['frame_id'] += 1
        elif name == 'eof':
            bad['records'] = [r for r in bad['records'] if r['phase'] != 'eof_retained']
        elif name == 'restart':
            bad['records'][-1]['source_epoch'] = bad['records'][-2]['source_epoch']
        elif name == 'cleanup':
            bad['closed_native_status']['render_failed'] = True
        elif name == 'eof_unresolved':
            bad['native_status']['eof_source_resolved'] = False
        elif name == 'eof_target':
            bad['resolved_eof_source']['frame_id'] -= 1
        elif name == 'eof_slot':
            bad['eof_gate_checks']['completed_slot'] += 1
        elif name == 'eof_predraw':
            bad['eof_gate_checks']['before_draw_rejected'] = False
        elif name == 'eof_seek_invalidation':
            bad['restart_native_status']['eof_source_resolved'] = True
        elif name == 'retirement_early_reuse':
            bad['retirement_ack_checks']['capture_before_ack'] = 1
        elif name == 'retirement_unacknowledged':
            bad['retirement_ack_checks']['all_tokens_acknowledged'] = False
        elif name == 'retirement_token_reuse':
            bad['retirement_ack_checks']['capture_after_ack'] = bad['retirement_ack_checks']['tokens'][0]
        try:
            verify(bad, args.ffmpeg)
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError(f'Corrupted {name} evidence was accepted')
    result['negative_cases_rejected'] = rejected
    args.report.with_name(args.report.stem + '_verified.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k != 'comparisons'}))


if __name__ == '__main__':
    main()
