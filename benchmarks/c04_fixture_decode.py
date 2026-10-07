"""Measure host H.264 red-channel loss separately from lossless shader math."""
from __future__ import annotations
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    manifest = json.loads((ROOT/'tests/fixtures/c04_alpha.json').read_text())
    video = ROOT/'app/godot/media/c04_alpha_f180.mp4'
    item = next(x for x in manifest['assets'] if x['file'].endswith('c04_alpha_f180.mp4'))
    assert hashlib.sha256(video.read_bytes()).hexdigest() == item['sha256']
    w,h = manifest['width'],manifest['height']
    aw,ah = manifest['packed_dimensions']
    raw = subprocess.check_output([args.ffmpeg,'-hide_banner','-loglevel','error','-i',str(video),
                                   '-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','pipe:1'])
    decoded = np.frombuffer(raw,np.uint8).reshape(h,w,3)
    oracle = cv2.imread(str(ROOT/'app/godot/media/c04_packed_mask_oracle.png'),cv2.IMREAD_GRAYSCALE)
    errors = []
    interior = []
    for sy in range(h):
        # Reconstruct by inspecting destination rectangles, independently of shader/fixture inverse.
        for sx in range(w):
            y = sy-(h-ah//2) if sy >= h-ah//2 else (sy+ah//2 if sy < ah//2 else -1)
            if y < 0: continue
            center = w//2-aw//4
            x = sx-center if center <= sx < center+aw//2 else (
                sx-(w-aw//4)+aw//2 if sx >= w-aw//4 else (sx+aw*3//4 if sx < aw//4 else -1))
            if x < 0: continue
            difference = abs(int(decoded[sy,sx,0])-int(oracle[y,x]))/255
            errors.append(difference)
            if 2 <= sx < w-2 and 2 <= sy < h-2 and 2 <= x%(aw//4) < aw//4-2 and 2 <= y%(ah//2) < ah//2-2:
                # Also exclude steps in the known five-band mask, where 4:2:0 blends chroma.
                neighborhood = oracle[max(0,y-2):min(ah,y+3),max(0,x-2):min(aw,x+3)]
                if np.all(neighborhood == oracle[y,x]): interior.append(difference)
    def statistics(values: list[float]) -> dict:
        return {'samples':len(values),'max_abs':float(np.max(values)),
                'p95_abs':float(np.quantile(values,.95)),'mean_abs':float(np.mean(values))}
    result = {'schema_version':1,'scope':'Host FFmpeg first-frame H264 decode; no Android or XR evidence',
              'video_sha256':item['sha256'],'all_packed_texels':statistics(errors),'constant_mask_interior':statistics(interior),
              'ffmpeg':subprocess.check_output([args.ffmpeg,'-version'],text=True).splitlines()[0],
              'note':'4:2:0 and H264 introduce edge loss; report worst error without treating it as shader error',
              'android_execution':'not_run'}
    target = ROOT/'artifacts/c04-fixture-decode.json'
    target.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__ == '__main__': main()
