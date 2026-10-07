"""Local MP06 text-track fixture using only project-generated video/audio/cues."""
import os
from pathlib import Path
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    source = ROOT/'app/godot/media/mp06_audio_clock.mp4'
    manifest = json.loads((ROOT/'tests/fixtures/mp06_audio_clock.json').read_text())
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest['sha256']
    output_dir = ROOT/'artifacts/fixtures/mp06_subtitles'
    output_dir.mkdir(parents=True, exist_ok=True)
    texts = [
        ('english.srt', '1\n00:00:00,500 --> 00:00:01,500\nTrack A: first cue\n\n2\n00:00:02,000 --> 00:00:03,000\nTrack A: second cue\nSecond line\n\n3\n00:00:04,000 --> 00:00:05,500\nTrack A: final cue\n'),
        ('chinese.srt', '1\n00:00:00,500 --> 00:00:01,500\n中文字幕 😀\n\n2\n00:00:02,000 --> 00:00:03,000\n第二条字幕\n第二行\n\n3\n00:00:04,000 --> 00:00:05,500\n最后一条字幕\n'),
        ('styled.ass', '[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.50,0:00:01.50,Default,,0,0,0,,{\\b1}Track C: styled{\\b0}\\NPlain text overlay\nDialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,Track C: after seek\nDialogue: 0,0:00:04.00,0:00:05.50,Default,,0,0,0,,Track C: final cue\n')]
    command = [os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source)]
    for name, content in texts:
        path = output_dir/name
        path.write_text(content, encoding='utf-8')
        command += ['-i', str(path)]
    command += ['-map', '0:v', '-map', '0:a', '-map', '1:s', '-map', '2:s', '-map', '3:s', '-c', 'copy', '-avoid_negative_ts', 'disabled']
    for index, language in enumerate(['eng', 'chi', 'eng']):
        command += [f'-metadata:s:s:{index}', f'language={language}', f'-metadata:s:s:{index}', f'title=Text track {index+1}',
                    f'-disposition:s:{index}', '0']
    output = ROOT/'artifacts/fixtures/mp06_text_subtitles.mkv'
    # Matroska UIDs normally vary; bitexact fixes them for a locked local fixture.
    command += ['-fflags', '+bitexact']
    subprocess.run(command+[str(output)], check=True)
    first_hash = hashlib.sha256(output.read_bytes()).hexdigest()
    subprocess.run(command+[str(output)], check=True)
    assert hashlib.sha256(output.read_bytes()).hexdigest() == first_hash, 'Fixture mux must reproduce identical bytes'
    probe = subprocess.run([os.environ.get('THRU3D_FFPROBE', 'ffprobe'), '-v', 'error', '-show_streams', '-show_packets',
                            '-select_streams', 's', '-of', 'json', str(output)], check=True, capture_output=True)
    data = json.loads(probe.stdout)
    assert [s['codec_name'] for s in data['streams']] == ['subrip', 'subrip', 'ass']
    for stream in data['streams']:
        packets = [p for p in data['packets'] if p['stream_index'] == stream['index']]
        assert len(packets) == 3
        assert [float(p['pts_time']) for p in packets] == [.5, 2, 4]
        assert [float(p['duration_time']) for p in packets] == [1, 1, 1.5]
    (output_dir/'ffprobe.json').write_bytes(probe.stdout)
    result = dict(schema_version=1, file=output.relative_to(ROOT).as_posix(), sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                  bytes=output.stat().st_size, streams=[s['codec_name'] for s in data['streams']],
                  cue_intervals_seconds=[[.5, 1.5], [2, 3], [4, 5.5]],
                  stream_indexes=[s['index'] for s in data['streams']],
                  stream_indexes_are_not_mpv_track_ids=True,
                  rights='Project-generated graphics, synthesized tones and original subtitle text',
                  scope='FFmpeg mux and FFprobe packet times verified; native MPV text decoding/track ids/Quest rendering pending',
                  bundled_in_apk=False, repeated_mux_identical_bytes_verified=True)
    (ROOT/'tests/fixtures/mp06_text_subtitles.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(f'Subtitle fixture mux verified: {output}; SHA256={result["sha256"]}')

if __name__ == '__main__':
    main()
