"""Generate a moving, frame-numbered SBS source for render/PTS verification."""
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
import cv2

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    output = ROOT/'app/godot/media/mp03_frame_identity.mp4'
    command = [args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '1280x640', '-r', '30', '-i', 'pipe:0',
               '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '16', '-pix_fmt', 'yuv420p',
               '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
               '-movflags', '+faststart', str(output)]
    with subprocess.Popen(command, stdin=subprocess.PIPE) as encoder:
        try:
            for index in range(180):
                image = np.empty((640, 1280, 3), dtype=np.uint8)
                image[:] = (20, 30, 60)
                checksum = (index ^ (index >> 4) ^ 0xA) & 15
                code = index | (checksum << 8)
                for eye in range(2):
                    offset = eye * 640
                    for bit in range(12):
                        value = 220 if code & (1 << bit) else 36
                        x = offset + 16 + bit * 50
                        image[72:121, x:x+41] = value
                    cv2.putText(image, f'EYE {eye} FRAME {index:03}', (offset+32, 220),
                                cv2.FONT_HERSHEY_SIMPLEX, 1.3, (255,)*3, 2)
                    x = offset + 24 + (index * 3) % 480
                    image[300:401, x:x+81] = (220,20,20) if eye == 0 else (20,20,220)
                    cv2.putText(image, 'BOTTOM', (offset+32, 580), cv2.FONT_HERSHEY_SIMPLEX,
                                1.3, (220,220,20), 2)
                encoder.stdin.write(image.tobytes())
        finally:
            encoder.stdin.close()
        if encoder.wait() != 0:
            raise RuntimeError('Frame identity fixture encoding failed')
    ffprobe = str(Path(args.ffmpeg).with_name('ffprobe.exe'))
    metadata = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(output)]))
    pts = [round(float(frame['best_effort_timestamp_time']) * 1e6) for frame in metadata['frames']]
    if len(pts) != 180 or pts[0] != 0 or pts[60] != 2000000 or pts[-1] != 5966667:
        raise ValueError('Encoded fixture time line differs')
    manifest = {
        'schema_version': 1, 'fixture': 'mp03_frame_identity',
        'file': 'app/godot/media/mp03_frame_identity.mp4',
        'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'bytes': output.stat().st_size,
        'width': 1280, 'height': 640, 'frames': 180, 'fps': 30, 'pts_us': pts,
        'rights': 'Project-generated calibration graphics; no external media',
        'identity': '12 grayscale squares per eye: 8 little-endian frame bits, 4 checksum bits',
        'checksum': '(frame ^ (frame >> 4) ^ 0xA) & 15', 'dark_rgb': 36, 'bright_rgb': 220,
        'sample_points': [[eye*640 + 36 + bit*50, 96] for eye in range(2) for bit in range(12)],
        'pixel_limit_bytes': 8,
        'scope': 'Frame identity/PTS/redraw/seek calibration, not RVM or real-person quality',
    }
    (ROOT/'tests/fixtures/mp03_frame_identity.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Generated {output}; sha256={manifest["sha256"]}')


if __name__ == '__main__':
    main()
