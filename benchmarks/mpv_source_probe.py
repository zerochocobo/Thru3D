"""Verify same-render source identity against independently decoded frame codes."""
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
HAS_IMAGE, PTS_VALID, REDRAW, REPEAT, RENDER_VALID = 1, 2, 4, 8, 16


def verify(report, ffmpeg):
    manifest = json.loads((ROOT/'tests/fixtures/mp03_frame_identity.json').read_text())
    source = ROOT/manifest['file']
    if hashlib.sha256(source.read_bytes()).hexdigest() != manifest['sha256']:
        raise ValueError('Frame identity fixture bytes differ')
    if (report['state'] != 'passed' or report['fixture'] != 'mp03_frame_identity' or
            report['probe_kind'] != 'source' or not report['source_frame_extension'] or
            report['source_frame_api'] != 1 or report['seek_stage'] != 5 or
            not report['context_disposed'] or not report['ended'] or report['end_reason'] != 0 or
            report['playback_error'] != 0 or (report['fbo_width'], report['fbo_height']) != (1280, 640) or
            report['flip_y'] != 0 or report['cscale'] != 'bilinear'):
        raise ValueError('Native source-frame/seek/EOS/disposal probe did not pass')
    backend = 'mediacodec' if report['requested_hardware'] else 'no'
    if report['hwdec_current'] != backend or report['godot_context_shared'] or report['audio_enabled']:
        raise ValueError('Unexpected probe backend/scope')
    metadata = json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe.exe')),
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=best_effort_timestamp_time',
        '-of', 'json', str(source)]))
    pts = [round(float(frame['best_effort_timestamp_time'])*1e6) for frame in metadata['frames']]
    if pts != manifest['pts_us']:
        raise ValueError('Independent encoded source PTS differ from the fixture manifest')
    # Decode all frames independently, then keep only two source rows. No
    # screenshot/OCR guess or delayed MPV property is used to identify a frame.
    raw = subprocess.check_output([ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', str(source),
        '-vf', 'crop=1280:2:0:96', '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1'])
    if len(raw) != 180*2*1280*3:
        raise ValueError('Independent decoder did not produce 180 complete code strips')
    reference = np.frombuffer(raw, np.uint8).reshape(180, 2, 1280, 3)
    coordinates = manifest['sample_points']
    expected = np.stack([reference[:, 0, x, :] for x, _ in coordinates], axis=1).astype(np.int16)
    for index in range(180):
        for eye in range(2):
            decoded = sum((int(expected[index, eye*12+bit, 0]) > 128) << bit for bit in range(12))
            if decoded & 255 != index or decoded >> 8 != (index ^ (index >> 4) ^ 0xA) & 15:
                raise ValueError('Independent decoder frame number/checksum mismatch')
    records = report['source_records']
    if not records or len(records) > 512:
        raise ValueError('Empty or unbounded source records')
    sequence = 0
    associations, epochs, identity_epochs = {}, {}, {}
    maximum = 0
    comparisons = []
    forced = []
    for record in records:
        flags = record['flags']
        if (record['render_sequence'] <= sequence or record['render_result'] != 0 or
                flags & (HAS_IMAGE | PTS_VALID | RENDER_VALID) != HAS_IMAGE | PTS_VALID | RENDER_VALID or
                (record['width'], record['height']) != (1280, 640) or record['rotation'] != 0):
            raise ValueError('Invalid render result, dimensions or transaction sequence')
        sequence = record['render_sequence']
        # MPV may describe uncropped images with the all-zero default rectangle.
        if record['crop'] not in ([0, 0, 1280, 640], [0, 0, 0, 0]):
            raise ValueError('Unexpected source crop')
        index = min(range(180), key=lambda i: abs(pts[i]-record['pts_us']))
        if abs(pts[index]-record['pts_us']) > 1:
            raise ValueError('Rendered PTS has no independent source frame')
        actual = np.asarray(record['pixels'], dtype=np.int16)
        if actual.shape != (24, 4) or np.any(actual[:, 3] != 255):
            raise ValueError('Missing identity samples or non-opaque colour output')
        error = int(np.abs(actual[:, :3]-expected[index]).max())
        maximum = max(maximum, error)
        if error > manifest['pixel_limit_bytes']:
            raise ValueError(f'Frame {index} pixel/source PTS mismatch: error {error}')
        for eye in range(2):
            decoded = sum((int(actual[eye*12+bit, 0]) > 128) << bit for bit in range(12))
            if decoded & 255 != index or decoded >> 8 != (index ^ (index >> 4) ^ 0xA) & 15:
                raise ValueError('FBO code/checksum disagrees with the same-render source PTS')
        key = (record['source_epoch'], record['frame_id'])
        if min(key) <= 0 or (key in associations and associations[key] != index):
            raise ValueError('Source identity reused for different image content')
        if key[1] in identity_epochs and identity_epochs[key[1]] != key[0]:
            raise ValueError('Retained source image was incorrectly relabelled with a new seek epoch')
        identity_epochs[key[1]] = key[0]
        associations[key] = index
        epoch_frames = epochs.setdefault(record['source_epoch'], {})
        if index in epoch_frames and epoch_frames[index] != record['frame_id']:
            raise ValueError('One epoch assigned multiple source identities to a retained image')
        epoch_frames[index] = record['frame_id']
        if record['forced']:
            if not flags & REDRAW:
                raise ValueError('Forced redraw is not marked as a redraw')
            forced.append((key, index))
        comparisons.append({'render_sequence': sequence, 'epoch': key[0], 'frame_id': key[1],
                            'source_index': index, 'pts_us': record['pts_us'], 'max_abs_bytes': error})
    if len(forced) != 2 or [item[1] for item in forced] != [0, 60]:
        raise ValueError('Both paused redraw/seek checks are required')
    initial_epoch, seek_epoch = forced[0][0][0], forced[1][0][0]
    playback_epoch = max(epochs)
    if not initial_epoch < seek_epoch < playback_epoch:
        raise ValueError('Seek/reset did not create separate source epochs')
    if sorted(epochs[playback_epoch]) != list(range(180)):
        raise ValueError('Full playback did not verify all 180 source frames including the final frame')
    ids = [epochs[playback_epoch][index] for index in range(180)]
    if any(a >= b for a, b in zip(ids, ids[1:])):
        raise ValueError('Source IDs did not advance with source images')
    return {'schema_version': 1, 'state': 'passed', 'source_pts_verified': True,
            'fixture_sha256': manifest['sha256'], 'requested_hardware': report['requested_hardware'],
            'actual_hwdec': backend, 'source_frames': 180, 'render_records': len(records),
            'seek_epochs': [initial_epoch, seek_epoch, playback_epoch], 'paused_redraws': len(forced),
            'max_abs_bytes': maximum, 'limit_bytes': manifest['pixel_limit_bytes'],
            'comparisons': comparisons,
            'scope': 'Numbered synthetic source: same-render PTS/identity/pixels, two seeks, paused redraws and final frame; Godot/RVM/audio/performance unverified'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    result = verify(json.loads(args.report.read_text(encoding='utf-8-sig')), args.ffmpeg)
    args.report.with_name(args.report.stem+'_identity.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'comparisons'}))


if __name__ == '__main__':
    main()
