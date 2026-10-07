"""Prepare a local-only ordinary stereo moving-person source for RVM/MPV tests."""
import os
from pathlib import Path
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4*1024*1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--start', type=float, default=30)
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    probe = str(Path(args.ffmpeg).with_name('ffprobe.exe'))
    source_info = json.loads(subprocess.check_output([probe, '-v', 'error', '-show_streams',
        '-show_format', '-of', 'json', str(source)], text=True))
    stream = next(s for s in source_info['streams'] if s['codec_type'] == 'video')
    # This fixture is the user-authorized STAYC VR180 fisheye SBS source.
    # Preserve its image aspect, pad to UHD, and keep the complete two eyes.
    assert (stream['width'], stream['height']) == (7350, 3972)
    assert 0 <= args.start <= float(source_info['format']['duration']) - 6
    output = ROOT/'artifacts/fixtures/mp07_motion_4k.mp4'
    output.parent.mkdir(parents=True, exist_ok=True)
    source_hash = sha(source)
    command = [args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-ss', str(args.start),
        '-i', str(source), '-t', '6', '-vf',
        'scale=3840:2076:flags=lanczos,pad=3840:2160:0:42,fps=30',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-threads', '4',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart',
        '-y', str(output)]
    subprocess.run(command, check=True, timeout=600)
    result = json.loads(subprocess.check_output([probe, '-v', 'error', '-count_frames',
        '-show_streams', '-show_format', '-of', 'json', str(output)], text=True))
    video = next(s for s in result['streams'] if s['codec_type'] == 'video')
    assert (video['width'], video['height'], video['avg_frame_rate'], int(video['nb_read_frames'])) == (3840,2160,'30/1',180)
    assert sha(source) == source_hash
    record = dict(schema_version=1, fixture='mp07_motion_4k',
        recorded_utc=datetime.now(timezone.utc).isoformat(),
        file=output.relative_to(ROOT).as_posix(), sha256=sha(output), bytes=output.stat().st_size,
        source_file=str(source), source_sha256=source_hash,
        source_use='User-authorized local test only; excluded from APK and release redistribution',
        source_start_seconds=args.start, duration_seconds=6, frames=180, fps=30,
        width=3840, height=2160, eye_layout='SBS', projection='VR180 fisheye',
        transform='7350x3972 -> 3840x2076 Lanczos, pad top/bottom42, fps30',
        alpha_input=False, green_screen_processing=False,
        original_probe=source_info, output_probe=result, command=command,
        ffmpeg_version=subprocess.check_output([args.ffmpeg,'-version'],text=True).splitlines()[0],
        pipeline_verified=False, quality_verified=False, performance_verified=False)
    (ROOT/'tests/fixtures/mp07_motion_4k.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:record[k] for k in ('file','sha256','bytes','frames','width','height')},ensure_ascii=False))

if __name__ == '__main__': main()
