"""Audit real paused six-profile and repeated-mode observations, without FPS claims."""
import argparse
import copy
import json
import math
from pathlib import Path

PROFILES = ('256x144', '384x216', '512x288', '256x256', '384x384', '512x512')


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def verify(e):
    result = e['result']
    require(result['state'] == 'passed_scoped_profile_and_mode_trace', 'Incomplete trace')
    require(result['apk_sha256'] == result['installed_sha256'] == e['build']['apk_sha256'], 'Wrong APK')
    require(result['profiles'] == list(PROFILES), 'Missing profile')
    count = result['requested_switches']
    require(result['completed_switches'] == count and 2 <= count <= 100, 'Missing switches')
    xr_entry = result['xr_entry']
    require(result['launch_entry'] == ('normal_vr_launcher' if xr_entry else 'diagnostic_2d'), 'Wrong entry')
    previous_generation = e['reports']['seek']['media']['generation']
    previous_epoch = e['reports']['seek']['media']['presentation_identity']['source_epoch']
    previous_frame = e['reports']['seek']['media']['presentation_identity']['frame_id']
    previous_seeks = e['reports']['seek']['native_status']['seeks_completed']
    handles = set()
    slots = set()
    observations = []
    for label, profile, alpha in e['revisions']:
        r, receipt = e['reports'][label], e['receipts'][label]
        require(receipt['state'] == 'accepted' and receipt['diagnostic_process'] == result['process'], 'Old process')
        require(r['request_id'] == receipt['id'] and bool(r['diagnostic_2d']) != xr_entry, 'Wrong request/entry')
        consumed = [c for c in r['commands'] if c['request_key'] == receipt['request'] and c['request_id'] == receipt['id']]
        require(len(consumed) == 1, 'Command not consumed once')
        media, native, identity = r['media'], r['native_status'], r['media']['presentation_identity']
        require(media['state'] == 'paused' and native['details']['paused'] == 'yes', 'Unexpected playback')
        require(native['session_id'] == media['session_id'] and native['generation'] == media['generation'], 'Stale native status')
        require(native['post_draw_frames'] > 0 and not native['render_failed'] and not native['render_error'], 'No completed current draw')
        require(native['details']['hwdec_current'] == 'mediacodec', 'Not actual hardware decode')
        require(media['generation'] > previous_generation and identity['source_epoch'] >= previous_epoch, 'Old processing/source epoch')
        require(native['epoch_floor'] <= identity['source_epoch'] and native['seeks_completed'] >= previous_seeks, 'Uncompleted seek/source floor')
        # requestFrame republishes a paused immutable frame without seeking.
        # A processing revision must advance; an unchanged source epoch must
        # still refer to exactly the prior source frame with no intervening seek.
        if identity['source_epoch'] == previous_epoch:
            require(identity['frame_id'] == previous_frame and native['seeks_completed'] == previous_seeks, 'Changed paused source without a new epoch')
        previous_generation, previous_epoch = media['generation'], identity['source_epoch']
        previous_frame, previous_seeks = identity['frame_id'], native['seeks_completed']
        require(identity['pts_us'] == 1000000 and identity['source_pts_verified'] and identity['pair_identity_verified'], 'Wrong source frame')
        require(r['layout']['profile'] == profile and r['layout']['alpha_enabled'] == alpha and identity['inference_ran'] == alpha, 'Wrong mode')
        bound = [p for p in r['pairs'] if p['session_id'] == media['session_id'] and p['slot_token'] == identity['slot_token']]
        require(len(bound) == 1, 'Current binding missing')
        pair = bound[0]
        require(pair['slot_token'] not in slots, 'Old consumer lease reused across processing revisions')
        slots.add(pair['slot_token'])
        for field in ('frame_id', 'pts_us', 'generation', 'source_epoch'):
            require(pair[field] == identity[field], 'Pair/ticket mismatch: '+field)
        require(pair['source_ticket_valid'] and pair['immutable_color_frame'] and pair['pair_identity_verified'], 'Unverified source pair')
        require(pair['profile_key'] == profile and pair['inference_ran'] == alpha and pair['alpha_requested'] == alpha, 'Wrong native pair mode')
        require(pair['owner_context_shared'] and pair['godot_context_shared'] and pair['consumer_copy_fence_ready'], 'Owner sharing/fence absent')
        handles.add(pair['mpv_source_handle'])
        observation = dict(label=label, profile=profile, alpha=alpha, generation=media['generation'], source_epoch=identity['source_epoch'])
        if alpha:
            width, height = map(int, profile.split('x'))
            require(r['layout']['alpha_ready'] and pair['rvm_backend'] == 'vulkan', 'Alpha not ready on Vulkan')
            require(pair['input_width'] == width and pair['input_height'] == height, 'Wrong actual model shape')
            require(pair['alpha_width'] == 2*width and pair['alpha_height'] == height and pair['alpha_texture_format'] == 'GL_R8_numeric', 'Wrong packed stereo mask')
            require(pair['alpha_gpu_uploaded'] and pair['alpha_fence_ready'] and pair['alpha_texture_id'] > 0, 'Missing actual Alpha texture/fence')
            require(pair['alpha_frame_id'] == pair['frame_id'] and pair['alpha_pts_us'] == pair['pts_us'] and pair['alpha_slot_token'] == pair['slot_token'], 'Alpha/color mismatch')
            kernel = pair['kernel']
            require(kernel['state'] == 'ready' and kernel['state_storage'] == 'VkMat_FP32' and kernel['profile_key'] == profile, 'Not resident-state kernel')
            transfer = kernel['explicit_gpu_transfer_totals']
            require(transfer['committed_stereo_frames'] > 0 and transfer['diagnostic_state_download_bytes'] == 0 and
                    transfer['validation_download_bytes'] == 32*transfer['committed_stereo_frames'], 'Unexpected production state readback')
            require(math.isfinite(pair['rvm_process_ms']) and pair['rvm_process_ms'] > 0, 'Invalid isolated inference time')
            observation['single_pair_process_ms'] = pair['rvm_process_ms']
        observations.append(observation)
    require(len(handles) == 1 and next(iter(handles)) > 0, 'MPV source replaced')
    close = e['reports']['close']
    require(close['media']['session_id'] <= 0 and not close['layout']['alpha_enabled'], 'Display retained after close')
    return dict(state='passed_scoped_six_profile_and_repeated_mode_trace', apk_sha256=result['apk_sha256'],
                source_handle=next(iter(handles)), profiles=list(PROFILES), completed_switches=count,
                observations=observations, resident_state_storage='VkMat_FP32',
                test_proximity_keep_awake=result.get('test_proximity_keep_awake', False),
                xr_entry=xr_entry,
                device_numerical_oracle_verified=False, sustained_fps_verified=False, memory_leak_verified=False,
                physical_tracking_verified=False, compositor_pixels_verified=False,
                scope='Paused hardware source/current Godot pair/post-draw/shape/stereo mask/resident-state metadata across six profiles and repeated revisions')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('directory', type=Path)
    d = p.parse_args().directory
    result = read(d/'result.json')
    revisions = [(f'profile_{profile}', profile, True) for profile in PROFILES]
    revisions += [('stress_profile', '256x144', True)]
    revisions += [(f'switch_{index:03}', '256x144', index % 2 == 0) for index in range(1, result['requested_switches']+1)]
    labels = ['seek', 'close'] + [label for label, _, _ in revisions]
    e = dict(result=result, build=read(d/'build_manifest.json'), revisions=revisions,
             reports={label: read(d/f'{label}-report.json') for label in labels},
             receipts={label: read(d/f'{label}-receipt.json') for label in labels})
    checked = verify(e)
    first = e['reports']['profile_256x144']
    # Find the actual current bound pair, independently of its list position.
    pair_index = next(i for i, pair in enumerate(first['pairs']) if pair['slot_token'] == first['media']['presentation_identity']['slot_token'])
    def reused_lease(x):
        target = x['reports']['profile_384x216']
        pair = next(p for p in target['pairs'] if p['slot_token'] == target['media']['presentation_identity']['slot_token'])
        token = x['reports']['profile_256x144']['media']['presentation_identity']['slot_token']
        pair['slot_token'] = token
        target['media']['presentation_identity']['slot_token'] = token
    mutations = {
        'wrong_apk': lambda x: x['result'].update(installed_sha256='0'*64),
        'missing_switch': lambda x: x['result'].update(completed_switches=0),
        'old_process': lambda x: x['receipts']['profile_256x144'].update(diagnostic_process='old'),
        'wrong_entry': lambda x: x['reports']['profile_256x144'].update(diagnostic_2d=x['result']['xr_entry']),
        'old_generation': lambda x: x['reports']['profile_256x144']['native_status'].update(generation=-1),
        'source_epoch_regressed': lambda x: x['reports']['profile_256x144']['media']['presentation_identity'].update(source_epoch=0),
        'paused_frame_changed': lambda x: x['reports']['profile_256x144']['media']['presentation_identity'].update(
            source_epoch=x['reports']['seek']['media']['presentation_identity']['source_epoch'], frame_id=-1),
        'seek_without_epoch': lambda x: (x['reports']['profile_256x144']['media']['presentation_identity'].update(
            source_epoch=x['reports']['seek']['media']['presentation_identity']['source_epoch']),
            x['reports']['profile_256x144']['native_status'].update(seeks_completed=x['reports']['seek']['native_status']['seeks_completed']+1)),
        'source_below_floor': lambda x: x['reports']['profile_256x144']['native_status'].update(epoch_floor=1e9),
        'reused_consumer_lease': reused_lease,
        'no_draw': lambda x: x['reports']['profile_256x144']['native_status'].update(post_draw_frames=0),
        'wrong_shape': lambda x: x['reports']['profile_256x144']['pairs'][pair_index].update(input_width=1),
        'stale_alpha': lambda x: x['reports']['profile_256x144']['pairs'][pair_index].update(alpha_frame_id=-1),
        'wrong_backend': lambda x: x['reports']['profile_256x144']['pairs'][pair_index].update(rvm_backend='cpu'),
        'host_states': lambda x: x['reports']['profile_256x144']['pairs'][pair_index]['kernel'].update(state_storage='Mat_FP32'),
        'state_readback': lambda x: x['reports']['profile_256x144']['pairs'][pair_index]['kernel']['explicit_gpu_transfer_totals'].update(diagnostic_state_download_bytes=1),
        'wrong_frame': lambda x: x['reports']['switch_001']['media']['presentation_identity'].update(pts_us=0),
        'normal_inference': lambda x: x['reports']['switch_001']['media']['presentation_identity'].update(inference_ran=True),
        'retained_close': lambda x: x['reports']['close']['media'].update(session_id=1),
    }
    rejected = []
    for label, mutate in mutations.items():
        polluted = copy.deepcopy(e)
        mutate(polluted)
        try:
            verify(polluted)
        except (ValueError, KeyError, TypeError):
            rejected.append(label)
        else:
            raise ValueError('Polluted evidence accepted: '+label)
    checked['negative_cases_rejected'] = rejected
    (d/'modes-verified.json').write_text(json.dumps(checked, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in checked.items() if k != 'observations'}))


if __name__ == '__main__':
    main()
