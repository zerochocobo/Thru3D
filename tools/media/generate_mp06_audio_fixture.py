"""Remux the locked numbered source with two project-generated AAC pulse tracks."""
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    original = json.loads((ROOT/'tests/fixtures/mp03_frame_identity.json').read_text())
    source = ROOT/original['file']
    if hashlib.sha256(source.read_bytes()).hexdigest() != original['sha256']:
        raise ValueError('Locked source changed')
    output = ROOT/'app/godot/media/mp06_audio_clock.mp4'
    command = [args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source)]
    for frequency in (440, 880):
        wave = f'0.1*sin(2*PI*{frequency}*t)*lt(mod(t\\,1)\\,0.1)'
        command += ['-f', 'lavfi', '-i', f'aevalsrc={wave}|{wave}:s=48000:d=6']
    command += ['-map', '0:v:0', '-map', '1:a:0', '-map', '2:a:0', '-c:v', 'copy',
                '-c:a', 'aac', '-b:a', '96k', '-metadata:s:a:0', 'language=eng',
                '-metadata:s:a:0', 'title=440 Hz calibration pulses',
                '-metadata:s:a:1', 'language=fra', '-metadata:s:a:1', 'title=880 Hz calibration pulses',
                '-disposition:a:0', 'default', '-disposition:a:1', '0', '-movflags', '+faststart', str(output)]
    subprocess.run(command, check=True)
    manifest = dict(schema_version=1, fixture='mp06_audio_clock', file=output.relative_to(ROOT).as_posix(),
                    sha256=hashlib.sha256(output.read_bytes()).hexdigest(), bytes=output.stat().st_size,
                    video_source_manifest='tests/fixtures/mp03_frame_identity.json',
                    audio_tracks=[dict(id=1, language='eng', frequency_hz=440), dict(id=2, language='fra', frequency_hz=880)],
                    audio_codec='aac', audio_samplerate=48000, audio_channels=2, duration_seconds=6,
                    pulse_seconds=[0, 1, 2, 3, 4, 5], pulse_duration_seconds=0.1,
                    rights='Project-generated numbered graphics and synthesized tones; no external media',
                    scope='MPV output/clock/control calibration; audible output and Godot/XR AV sync require separate evidence')
    (ROOT/'tests/fixtures/mp06_audio_clock.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    print(f'Generated {output}; SHA256={manifest["sha256"]}')


if __name__ == '__main__':
    main()
