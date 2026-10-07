"""Independent fixture/clock/control checks, with explicit muted AO scope."""
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


def fixture_reference(ffmpeg):
    manifest = json.loads((ROOT/'tests/fixtures/mp06_audio_clock.json').read_text())
    source = ROOT/manifest['file']
    if hashlib.sha256(source.read_bytes()).hexdigest() != manifest['sha256']:
        raise ValueError('Audio fixture bytes changed')
    metadata = json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe.exe')), '-v', 'error',
        '-show_streams', '-of', 'json', str(source)]))
    audio = [s for s in metadata['streams'] if s['codec_type'] == 'audio']
    if len(audio) != 2 or any(s['codec_name'] != 'aac' or int(s['sample_rate']) != 48000 or s['channels'] != 2 for s in audio):
        raise ValueError('Expected two AAC stereo 48 kHz tracks')
    for index, frequency in enumerate((440, 880)):
        data = np.frombuffer(subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(source), '-map', f'0:a:{index}',
            '-f', 'f32le', '-ac', '1', '-ar', '48000', 'pipe:1']), dtype='<f4')
        if data.size < 6*48000 or not np.isfinite(data).all():
            raise ValueError('Missing finite audio samples')
        for second in range(6):
            pulse = data[second*48000+960:second*48000+3840]
            peak = np.argmax(np.abs(np.fft.rfft(pulse*np.hanning(pulse.size))))*48000/pulse.size
            silence = data[second*48000+12000:second*48000+24000]
            if abs(peak-frequency) > 10 or np.sqrt(np.mean(pulse**2)) < 0.04 or np.max(np.abs(silence)) > 0.003:
                raise ValueError('Encoded tone/pulse timeline changed')
    original = json.loads((ROOT/manifest['video_source_manifest']).read_text())
    metadata = json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe.exe')), '-v', 'error',
        '-select_streams', 'v:0', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(source)]))
    pts = [round(float(f['best_effort_timestamp_time'])*1e6) for f in metadata['frames']]
    if pts != original['pts_us']:
        raise ValueError('Numbered video timeline changed after audio remux')
    raw = subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(source), '-vf', 'crop=1280:2:0:96', '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1'])
    pixels = np.frombuffer(raw, np.uint8).reshape(180, 2, 1280, 3)
    expected = np.stack([pixels[:, 0, x, :] for x, _ in original['sample_points']], axis=1)
    return manifest, pts, expected


def verify(report, reference):
    manifest, pts, pixels = reference
    if not isinstance(report.get('hardware_requested'), bool):
        raise ValueError('Decoder backend request is missing')
    expected_hwdec = 'mediacodec' if report['hardware_requested'] else 'no'
    forbidden = ['godot_display_verified', 'xr_verified', 'rvm_verified', 'audible_output_verified', 'av_sync_verified', 'performance_verified']
    if (report['schema_version'] != 1 or report['state'] != 'passed_native_checks' or not report['resources_closed'] or
        report['fixture'] != manifest['fixture'] or report['audio_owner'] != 'production_libmpv' or
        report['consumer_context_origin'] != 'debug_offscreen_GLES_pbuffer' or any(report[k] for k in forbidden) or
        not report['invalid_controls_rejected'] or report.get('audio_focus_initial') != 'held' or
        report.get('audio_focus_closed') != 'none' or report.get('audio_focus_changes') != []):
        raise ValueError('Native audio/control run failed or scope was enlarged')
    phases = {}
    for item in report['records']:
        status = item['native']; d = status['details']
        disabled = item['phase'] in ('audio_disabled', 'playing_without_audio')
        if (status['render_failed'] or status['error'] or status['render_error'] or
            d['hwdec_current'] != expected_hwdec or d['snapshot_sequence'] <= 0 or d['observed_monotonic_ns'] <= 0 or
            d['audio_clock_available'] != (d['audio_pts_us'] is not None)):
            raise ValueError('Real Android AO/AAC/clock observation is unavailable')
        if disabled:
            if d['audio_output'] or d['audio_track_id'] or d['audio_clock_available']:
                raise ValueError('Disabled audio retained an output or fabricated clock')
        elif (d['audio_output'] not in ('opensles', 'audiotrack', 'aaudio') or
              'AAC' not in d['audio_codec'].upper() or d['audio_samplerate'] != '48000' or d['audio_channels'] != '2'):
            raise ValueError('Real Android AO/AAC output was not initialized')
        if ([t['id'] for t in d['audio_tracks']] != [1, 2] or [t['language'] for t in d['audio_tracks']] != ['eng', 'fra']):
            raise ValueError('Actual MPV track enumeration differs from source')
        phases.setdefault(item['phase'], []).append(d)
        if item['phase'] in ('playing_track_1', 'paused_track_1', 'selected_track_2', 'playing_track_2', 'paused_track_2', 'audio_disabled', 'playing_without_audio', 'restored_track_2') and status['last_source_epoch'] != report['first_frame']['source_epoch']:
            raise ValueError('Audio controls changed the video epoch without a processing reset')
    required = ['initial_paused', 'playing_track_1', 'paused_track_1', 'selected_track_2', 'playing_track_2', 'paused_track_2',
                'audio_disabled', 'playing_without_audio', 'restored_track_2', 'paused_after_seek',
                'unmuted_zero_volume', 'restored_track_1', 'playing_after_seek', 'eof', 'restart_paused', 'playing_after_restart']
    if set(phases) != set(required):
        raise ValueError('Missing required clock/control phases')
    metrics = {}
    for name, data in phases.items():
        playing = name.startswith('playing_')
        if any(d['paused'] != ('no' if playing else 'yes') for d in data if name != 'eof'):
            raise ValueError('Actual pause state differs from requested phase')
        if len(data) > 1 and any(b['snapshot_sequence'] <= a['snapshot_sequence'] or b['observed_monotonic_ns'] <= a['observed_monotonic_ns'] for a,b in zip(data,data[1:])):
            raise ValueError('Clock samples are repeated or out of order')
        if playing or name in ('paused_track_1', 'paused_track_2', 'paused_after_seek', 'restart_paused'):
            if len(data) < 4:
                raise ValueError('Too few actual clock samples')
            elapsed = (data[-1]['observed_monotonic_ns']-data[0]['observed_monotonic_ns'])/1e6
            available = all(d['audio_clock_available'] for d in data)
            must_have_audio_clock = name in ('playing_track_1', 'playing_track_2', 'paused_track_1', 'paused_track_2', 'playing_after_seek', 'playing_after_restart')
            if must_have_audio_clock and not available:
                raise ValueError('Initialized audio playback/paused driver clock became unavailable')
            values = [d['audio_pts_us']/1000 for d in data] if available else [float(d['position_seconds'])*1000 for d in data]
            advance = values[-1]-values[0]
            if playing:
                if elapsed < 600 or abs(advance-elapsed) > 150 or any(b < a-2 for a,b in zip(values,values[1:])):
                    raise ValueError('Audio clock did not advance at real-time rate')
            elif elapsed < 250 or max(values)-min(values) > 25:
                raise ValueError('Paused audio clock continued advancing')
            metrics[name] = dict(samples=len(data),elapsed_ms=elapsed,advance_ms=advance,
                clock='actual_MPV_audio_pts_with_AO_delay' if available else 'MPV_playback_position;_audio_clock_explicitly_unavailable')
    controls = {'initial_paused':('1',25,'yes'), 'selected_track_2':('2',40,'yes'), 'restored_track_2':('2',40,'yes'),
                'unmuted_zero_volume':('2',0,'no'), 'restored_track_1':('1',25,'yes')}
    for name,(track,volume,mute) in controls.items():
        if any(d['audio_track_id'] != track or float(d['volume']) != volume or d['mute'] != mute for d in phases[name]):
            raise ValueError('Track, volume or mute control was not applied')
    if any(abs(float(d['position_seconds'])-2.0) > 0.01 for d in phases['paused_after_seek']) or any(abs(float(d['position_seconds'])) > 0.01 for d in phases['restart_paused']):
        raise ValueError('Paused MPV timeline did not follow exact seek/restart')
    if not 1900000 <= phases['playing_after_seek'][0]['audio_pts_us'] <= 2250000 or not -100000 <= phases['playing_after_restart'][0]['audio_pts_us'] <= 250000:
        raise ValueError('Real audio output did not start on the seek/restart timeline')
    frame_checks = []
    for key,index in [('first_frame',0),('seek_frame',60),('restart_frame',0)]:
        frame = report[key]
        sample = np.asarray(frame['source_code'], np.int16)
        if (frame['pts_us'] != pts[index] or frame['source_flags'] & 19 != 19 or sample.shape != (24,4) or
            np.any(sample[:,3] != 255) or np.abs(sample[:,:3]-pixels[index].astype(np.int16)).max() > 8):
            raise ValueError('Audio seek video pixels differ from actual source ticket')
        frame_checks.append(dict(phase=frame['phase'],source_epoch=frame['source_epoch'],encoded_index=index))
    if not report['first_frame']['source_epoch'] < report['seek_frame']['source_epoch'] < report['restart_frame']['source_epoch']:
        raise ValueError('Audio seek/restart reused an old video epoch')
    terminal = next(r['native'] for r in report['records'] if r['phase']=='eof')
    if not terminal['eof_source_resolved'] or terminal['eof_source_ticket']['pts_us'] != pts[-1] or terminal['details']['eof_reached'] != 'yes':
        raise ValueError('Audio/video EOF was not resolved')
    closed = report['closed_native_status']
    if not closed['done'] or closed['render_failed'] or closed['error'] or closed['render_error'] or closed['held_slots'] or closed['retiring_slots'] or closed['seeks_started'] != 2 or closed['seeks_completed'] != 2 or closed['audio_commands_applied'] != 6:
        raise ValueError('Audio/source controls or cleanup did not finish')
    return dict(state='passed',fixture_sha256=manifest['sha256'],actual_hwdec=expected_hwdec, actual_ao=phases['initial_paused'][0]['audio_output'],
                clock_control_metrics=metrics,video_seek_identity=frame_checks,audio_tracks=2,
                scope='Actual muted Android MPV AO, both AAC tracks/volume/mute/disabled audio, sampled initialized clock rate/pause and resumed seek/restart/EOF/cleanup; uninitialized audio clocks explicitly nullable. No audible speaker/RVM/Godot/XR AV sync or performance claim')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('report',type=Path)
    parser.add_argument('--ffmpeg',default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args=parser.parse_args()
    reference=fixture_reference(args.ffmpeg)
    report=json.loads(args.report.read_text(encoding='utf-8-sig'))
    result=verify(report,reference); rejected=[]
    for name in ('null_ao','missing_audio_clock','pause_advancing','wrong_track','volume','mute','seek_audio','seek_video','restart_epoch','track_epoch','cleanup','focus','backend','scope'):
        bad=copy.deepcopy(report)
        if name=='null_ao': bad['records'][0]['native']['details']['audio_output']='null'
        elif name=='missing_audio_clock':
            d=next(r for r in bad['records'] if r['phase']=='playing_track_1')['native']['details']
            d['audio_pts_us']=None; d['audio_clock_available']=False
        elif name=='pause_advancing':
            for i,r in enumerate(bad['records']):
                if r['phase']=='paused_track_1': r['native']['details']['audio_pts_us']+=i*100000
        elif name=='wrong_track': next(r for r in bad['records'] if r['phase']=='selected_track_2')['native']['details']['audio_track_id']='1'
        elif name=='volume': next(r for r in bad['records'] if r['phase']=='unmuted_zero_volume')['native']['details']['volume']='25'
        elif name=='mute': next(r for r in bad['records'] if r['phase']=='unmuted_zero_volume')['native']['details']['mute']='yes'
        elif name=='seek_audio': next(r for r in bad['records'] if r['phase']=='playing_after_seek')['native']['details']['audio_pts_us']=0
        elif name=='seek_video': bad['seek_frame']['pts_us']=reference[1][61]
        elif name=='restart_epoch': bad['restart_frame']['source_epoch']=bad['seek_frame']['source_epoch']
        elif name=='track_epoch': next(r for r in bad['records'] if r['phase']=='selected_track_2')['native']['last_source_epoch']+=1
        elif name=='cleanup': bad['closed_native_status']['retiring_slots']=1
        elif name=='focus': bad['audio_focus_initial']='denied'
        elif name=='backend': bad['hardware_requested']=not bad['hardware_requested']
        else: bad['av_sync_verified']=True
        try: verify(bad,reference)
        except ValueError: rejected.append(name)
        else: raise ValueError(f'Corrupted {name} evidence was accepted')
    result['negative_cases_rejected']=rejected
    args.report.with_name(args.report.stem+'_verified.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result))


if __name__=='__main__': main()
