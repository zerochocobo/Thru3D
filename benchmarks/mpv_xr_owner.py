"""Audit actual XR owner/runtime snapshots; never infer compositor pixels or head tracking from focus."""
import argparse
import copy
import json
import math
from pathlib import Path


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def verify(evidence, require_live_head=False):
    result, installed, build, caps = (evidence[k] for k in ('result', 'installed', 'build', 'capabilities'))
    if result['state'] != 'passed_scoped_owner_trace' or result.get('xr_entry') is not True:
        raise ValueError('Not an actual completed XR owner trace')
    if not (installed['apk_sha256'] == installed['installed_sha256'] == build['apk_sha256']):
        raise ValueError('Installed/build APK identity mismatch')
    processes, source_handles, reports = set(), set(), evidence['reports']
    for step, report in reports.items():
        receipt = evidence['receipts'][step]
        if receipt['state'] != 'accepted' or receipt['id'] != report['request_id'] or report['diagnostic_2d']:
            raise ValueError('Wrong request or 2D entry')
        commands = [c for c in report['commands'] if c['request_key'] == receipt['request'] and c['request_id'] == receipt['id']]
        if len(commands) != 1:
            raise ValueError('Current command was not consumed exactly once')
        processes.add(receipt['diagnostic_process'])
        media, native = report['media'], report['native_status']
        if media['state'] == 'failed':
            raise ValueError('Player failed')
        if step == 'close':
            if media['session_id'] > 0 or report['layout']['alpha_enabled']:
                raise ValueError('Close did not clear the active display')
            continue
        if native['session_id'] != media['session_id'] or native['generation'] != media['generation'] or native['post_draw_frames'] <= 0:
            raise ValueError('Stale native scope or no owner draw')
        if media['logical_session_id'] != reports['open']['media']['logical_session_id']:
            raise ValueError('Logical media source changed')
        pairs = [p for p in report['pairs'] if p['session_id'] == media['session_id']]
        if not pairs or native['details']['hwdec_current'] != 'mediacodec':
            raise ValueError('No actual current hardware pair')
        source_handles.update(p['mpv_source_handle'] for p in pairs)
    if len(processes) != 1 or source_handles != {result['source_handle']}:
        raise ValueError('Process/source instance changed')
    end, final = reports['eof']['native_status'], reports['eof']['media']['presentation_identity']
    if not end['eof_source_resolved'] or not end['eof_pair_post_draw'] or end['eof_presented_slot'] != final['slot_token']:
        raise ValueError('EOF was not drawn in the current slot')
    if final['pts_us'] != 5966667 or any(end['eof_source_ticket'][k] != final[k] for k in ('source_epoch', 'frame_id', 'pts_us')):
        raise ValueError('Final source/pair identities differ')
    if reports['seek']['media']['presentation_identity']['pts_us'] != 2000000:
        raise ValueError('Exact paused seek was not presented')
    if reports['normal']['media']['presentation_identity']['inference_ran'] or not reports['alpha']['media']['presentation_identity']['inference_ran']:
        raise ValueError('Mode changes did not use normal/complete RVM pairs')
    if reports['restart']['media']['generation'] <= final['generation'] or reports['restart']['media']['presentation_identity']['source_epoch'] <= final['source_epoch']:
        raise ValueError('Restart reused the old processing/source epoch')
    xr = caps['xr']
    if caps['captured_unix_seconds'] < evidence['launch_unix_seconds']-5 or caps['captured_unix_seconds'] > evidence['finished_unix_seconds']+5:
        raise ValueError('XR capability snapshot lies outside this host collection interval')
    if caps['media']['session_id'] != reports['alpha']['media']['session_id'] or caps['media']['generation'] != reports['alpha']['media']['generation']:
        raise ValueError('XR snapshot belongs to a different processing generation')
    if (xr['preview'] or not xr['initialized'] or not xr['viewport_use_xr'] or xr['view_count'] != 2 or
            xr['session_state'] != 'session_focussed' or not xr['applied_passthrough'] or not xr['requested_passthrough'] or
            xr['actual_blend_mode'] != 2 or not xr['fb_passthrough_started'] or not xr['viewport_transparent_bg'] or xr['error_code']):
        raise ValueError('Actual focused two-view passthrough runtime was not enabled')
    for name, size in [('eye_origins', 3), ('eye_quaternions', 4)]:
        values = xr[name]
        if len(values) != 2 or any(len(row) != size or not all(math.isfinite(x) for x in row) for row in values):
            raise ValueError('Eye transforms are missing/nonfinite')
    if any(abs(sum(x*x for x in q)-1) > 0.01 for q in xr['eye_quaternions']):
        raise ValueError('Eye orientation is invalid')
    # Godot's current upstream tracking_state is not initialized. The valid
    # head pose confidence is separate from the mere presence of a pose object.
    head_live = xr.get('head_tracker_registered', False) and xr.get('head_has_tracking_data', False) and xr.get('head_tracking_confidence', 0) in (1, 2)
    if require_live_head:
        position = xr.get('head_position', [])
        if (result.get('launch_entry') != 'normal_vr_launcher' or not head_live or
                xr.get('head_tracking_confidence') != 2 or len(position) != 3 or
                not all(math.isfinite(x) for x in position)):
            raise ValueError('Normal VR entry did not provide a high-confidence finite head pose')
    return dict(state='passed_scoped_XR_runtime_and_owner_controls', apk_sha256=build['apk_sha256'],
                process_id=next(iter(processes)), source_handle=result['source_handle'], operations=list(reports),
                eof_identity=final, producer_copy_deferred=end.get('producer_copy_deferred'),
                focused_two_view_passthrough_runtime=True, head_pose_reports_live_tracking=head_live,
                head_tracking_confidence=xr.get('head_tracking_confidence'), tracking_status_raw=xr.get('tracking_status'),
                head_position=xr.get('head_position'), launch_entry=result.get('launch_entry'),
                high_confidence_head_pose_required=require_live_head,
                test_proximity_keep_awake=result.get('test_proximity_keep_awake', False),
                physical_head_tracking_verified=False, compositor_pixels_verified=False, audio_verified=False,
                performance_verified=False, scope='Actual XR runtime/owner state. No compositor pixel, physical tracking accuracy, audio, AV sync, motion quality or sustained-performance claim.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--require-live-head', action='store_true')
    args = parser.parse_args()
    d = args.directory
    steps = ('open', 'pause', 'seek', 'normal', 'alpha', 'eof', 'restart', 'close')
    evidence = dict(result=read(d/'result.json'), installed=read(d/'installed.json'), build=read(d/'build_manifest.json'),
                    capabilities=read(d/'xr-alpha-capabilities.json'), reports={s: read(d/f'{s}-report.json') for s in steps},
                    receipts={s: read(d/f'{s}-receipt.json') for s in steps},
                    launch_unix_seconds=read(d/'result.json')['launch_unix_seconds'],
                    finished_unix_seconds=(d/'result.json').stat().st_mtime)
    checked = verify(evidence, args.require_live_head)
    mutations = {
        'wrong_installed_apk': lambda e: e['installed'].update(installed_sha256='0'*64),
        '2d_entry': lambda e: e['reports']['open'].update(diagnostic_2d=True),
        'stale_native_generation': lambda e: e['reports']['alpha']['native_status'].update(generation=-1),
        'unconsumed_command': lambda e: e['reports']['seek'].update(commands=[]),
        'old_xr_session': lambda e: e['capabilities']['media'].update(session_id=-1),
        'stale_capability_clock': lambda e: e['capabilities'].update(captured_unix_seconds=1),
        'passthrough_layer_stopped': lambda e: e['capabilities']['xr'].update(fb_passthrough_started=False),
        'wrong_blend_mode': lambda e: e['capabilities']['xr'].update(actual_blend_mode=0),
        'one_view': lambda e: e['capabilities']['xr'].update(view_count=1),
        'opaque_viewport': lambda e: e['capabilities']['xr'].update(viewport_transparent_bg=False),
        'early_eof': lambda e: e['reports']['eof']['native_status'].update(eof_pair_post_draw=False),
    }
    rejected = []
    for name, mutate in mutations.items():
        polluted = copy.deepcopy(evidence)
        mutate(polluted)
        try:
            verify(polluted)
        except (ValueError, KeyError):
            rejected.append(name)
        else:
            raise ValueError('Polluted report accepted: '+name)
    no_tracking = copy.deepcopy(evidence)
    no_tracking['capabilities']['xr'].update(head_tracker_registered=True, head_has_tracking_data=True, head_tracking_confidence=0, tracking_status=0)
    if verify(no_tracking)['head_pose_reports_live_tracking']:
        raise ValueError('Default pose/raw status falsely proves live head tracking')
    checked['negative_cases_rejected'] = rejected
    checked['zero_confidence_head_pose_not_accepted_as_live_tracking'] = True
    if args.require_live_head:
        for label, mutate in {
            'zero_confidence': lambda e: e['capabilities']['xr'].update(head_tracking_confidence=0),
            'low_confidence': lambda e: e['capabilities']['xr'].update(head_tracking_confidence=1),
            'nonfinite_head': lambda e: e['capabilities']['xr'].update(head_position=[0, float('nan'), 0]),
            'wrong_launcher': lambda e: e['result'].update(launch_entry='direct_activity'),
        }.items():
            polluted = copy.deepcopy(evidence)
            mutate(polluted)
            try:
                verify(polluted, True)
            except ValueError:
                rejected.append(label)
            else:
                raise ValueError('Invalid live-head report accepted: '+label)
    (d/'xr-runtime-verified.json').write_text(json.dumps(checked, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(checked))


if __name__ == '__main__':
    main()
