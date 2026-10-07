"""Independent audit of actual MPV cue observations; no compositor/timing claim."""
import argparse
import copy
import json
import math
from pathlib import Path

STEPS = ('open', 'pause', 'seek_first', 'english', 'chinese', 'styled', 'off', 'restore_chinese',
         'gap', 'gap_check', 'seek_second', 'second_chinese', 'alpha', 'alpha_play', 'alpha_pause', 'alpha_back', 'normal', 'close')
TEXTS = {'english': 'Track A: first cue', 'chinese': '中文字幕 😀',
         'styled': 'Track C: styled\nPlain text overlay', 'restore_chinese': '中文字幕 😀',
         'second_chinese': '第二条字幕\n第二行', 'alpha': '第二条字幕\n第二行', 'normal': '第二条字幕\n第二行'}

def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))

def require(value, message):
    if not value:
        raise ValueError(message)

def verify(e):
    result, build, fixture = e['result'], e['build'], e['fixture']
    require(result['state'] == 'passed_scoped_subtitle_trace', 'Incomplete device trace')
    require(result['apk_sha256'] == result['installed_sha256'] == build['apk_sha256'], 'Wrong installed APK')
    require(result['fixture_sha256'] == fixture['sha256'], 'Wrong actual fixture bytes')
    tracks = {t['title']: t for t in result['tracks']}
    require([tracks[f'Text track {i}']['codec'] for i in (1, 2, 3)] == ['subrip', 'subrip', 'ass'], 'Actual codecs differ')
    handles = set()
    for step in STEPS:
        r, receipt = e['reports'][step], e['receipts'][step]
        require(receipt['state'] == 'accepted' and receipt['diagnostic_process'] == result['process'], 'Stale process receipt')
        require(r['request_id'] == receipt['id'] and not r['diagnostic_2d'], 'Wrong request/entry')
        commands = [c for c in r['commands'] if c['request_id'] == receipt['id'] and c['request_key'] == receipt['request']]
        require(len(commands) == 1, 'Command not consumed exactly once')
        media, layout = r['media'], r['layout']
        require(media['state'] != 'failed', 'Player failed')
        subtitle = layout['subtitles']
        if step == 'close':
            require(media['session_id'] <= 0 and subtitle['text'] == '' and subtitle['cue'] == {}, 'Close retained old cue')
            continue
        native, pair = r['native_status'], media['presentation_identity']
        require(native['session_id'] == media['session_id'] and native['generation'] == media['generation'], 'Stale native status')
        require(native['post_draw_frames'] > 0 and native['details']['hwdec_current'] == 'mediacodec', 'No actual hardware/owner presentation')
        bound = [p for p in r['pairs'] if p['session_id'] == media['session_id'] and p['slot_token'] == pair['slot_token']]
        require(len(bound) == 1, 'Current binding identity missing')
        handles.add(bound[0]['mpv_source_handle'])
        if step in ('off', 'gap_check'):
            require(subtitle['text'] == '' and subtitle['cue'] == {}, 'Old text visible in disabled/gap state')
        if step not in TEXTS:
            continue
        cue = subtitle['cue']
        title = 'Text track 1' if step == 'english' else ('Text track 3' if step == 'styled' else 'Text track 2')
        expected_id = tracks[title]['id']
        require(subtitle['requested_track'] == int(cue['track_id']) == expected_id, 'Wrong actual/desired track')
        require(cue['text'] == subtitle['text'] == TEXTS[step], 'Wrong Unicode/ASS plain text')
        require(cue['session_id'] == media['session_id'] and cue['generation'] == media['generation'], 'Old cue generation')
        require(cue['source_epoch'] == pair['source_epoch'] and cue['mpv_source_handle'] == bound[0]['mpv_source_handle'], 'Wrong cue source/epoch')
        require(cue['command_id'] >= cue['required_command_id'] > 0 and cue['sequence'] > 0, 'Unapplied subtitle choice')
        require(cue['timeline_valid'] and 0 <= cue['age_ms'] <= 1000, 'Invalid/stale cue')
        require(cue['rendered_into_video'] is False and cue['clock_scope'] == 'MPV_playback_observation_not_same_video_frame_ticket', 'Clock/render scope differs')
        times = [float(cue[k]) for k in ('start_seconds', 'end_seconds', 'position_seconds')]
        require(all(math.isfinite(x) for x in times) and times[0] <= times[2] < times[1], 'Cue outside MPV clock interval')
        interval = fixture['cue_intervals_seconds'][1 if step in ('second_chinese', 'alpha', 'normal') else 0]
        require(times[:2] == interval, 'Actual MPV cue interval differs from independent fixture packet times')
        require(native['details']['paused'] == 'yes', 'Paused cue test unexpectedly playing')
    require(len(handles) == 1 and next(iter(handles)) > 0, 'Source reopened across controls')
    first, second = e['reports']['seek_first']['media'], e['reports']['seek_second']['media']
    require(first['presentation_identity']['pts_us'] == 1000000 and second['presentation_identity']['pts_us'] == 2500000, 'Seek target not exact')
    require(second['generation'] > first['generation'] and second['presentation_identity']['source_epoch'] > first['presentation_identity']['source_epoch'], 'Seek did not invalidate old timeline')
    alpha, normal = e['reports']['alpha'], e['reports']['normal']
    require(alpha['layout']['alpha_ready'] and alpha['media']['presentation_identity']['inference_ran'], 'Alpha not ready')
    require(not normal['layout']['alpha_enabled'] and not normal['media']['presentation_identity']['inference_ran'], 'Normal mode still computing/displaying Alpha')
    require(alpha['media']['generation'] > second['generation'] and normal['media']['generation'] > alpha['media']['generation'], 'Mode revisions missing')
    playing = e['reports']['alpha_play']
    require(playing['layout']['alpha_ready'] and playing['media']['frame_counter'] >= 12 and
            playing['layout']['subtitles']['requested_track'] == tracks['Text track 2']['id'],
            'Alpha did not sustain decoded frames with subtitles selected')
    return dict(state='passed_scoped_native_subtitle_and_Godot_state', apk_sha256=result['apk_sha256'],
                operations=list(STEPS), actual_track_ids={title: t['id'] for title, t in tracks.items()},
                source_handle=next(iter(handles)), fixture_sha256=result['fixture_sha256'],
                compositor_pixels_verified=False, exact_subtitle_av_sync_verified=False,
                scope='Native MPV Unicode/plain ASS/cue clock intervals and current Godot state; no glyph pixels, physical tracking or sustained performance claim')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    d = args.directory
    e = dict(result=read(d/'result.json'), build=read(d/'build_manifest.json'), fixture=read(d/'mp06_text_subtitles.json'),
             reports={s: read(d/f'{s}-report.json') for s in STEPS}, receipts={s: read(d/f'{s}-receipt.json') for s in STEPS})
    checked = verify(e)
    mutations = {
        'wrong_installed_apk': lambda x: x['result'].update(installed_sha256='0'*64),
        'wrong_fixture': lambda x: x['result'].update(fixture_sha256='0'*64),
        'old_process': lambda x: x['receipts']['chinese'].update(diagnostic_process='old'),
        '2d_entry': lambda x: x['reports']['chinese'].update(diagnostic_2d=True),
        'unconsumed_command': lambda x: x['reports']['chinese'].update(commands=[]),
        'old_native_generation': lambda x: x['reports']['alpha']['native_status'].update(generation=-1),
        'old_cue_epoch': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(source_epoch=-1),
        'wrong_cue_source': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(mpv_source_handle=-1),
        'old_cue_generation': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(generation=-1),
        'unapplied_track': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(command_id=0),
        'wrong_actual_track': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(track_id='999'),
        'corrupt_unicode': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(text='?'),
        'stale_cue': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(age_ms=1001),
        'invalid_clock': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(position_seconds='nan'),
        'wrong_packet_interval': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(start_seconds='.6'),
        'wrong_clock_scope': lambda x: x['reports']['chinese']['layout']['subtitles']['cue'].update(clock_scope='same_frame'),
        'gap_retained_text': lambda x: x['reports']['gap_check']['layout']['subtitles'].update(text='old'),
        'alpha_unready': lambda x: x['reports']['alpha']['layout'].update(alpha_ready=False),
        'alpha_stopped_after_first_frame': lambda x: x['reports']['alpha_play']['media'].update(frame_counter=1),
        'alpha_lost_subtitle_selection': lambda x: x['reports']['alpha_play']['layout']['subtitles'].update(requested_track=0),
        'normal_inference': lambda x: x['reports']['normal']['media']['presentation_identity'].update(inference_ran=True),
        'close_retained_text': lambda x: x['reports']['close']['layout']['subtitles'].update(text='old'),
    }
    rejected = []
    for name, mutate in mutations.items():
        polluted = copy.deepcopy(e)
        mutate(polluted)
        try:
            verify(polluted)
        except (ValueError, KeyError, TypeError):
            rejected.append(name)
        else:
            raise ValueError('Polluted report accepted: '+name)
    checked['negative_cases_rejected'] = rejected
    (d/'subtitle-verified.json').write_text(json.dumps(checked, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    print(json.dumps(checked, ensure_ascii=False))

if __name__ == '__main__':
    main()
