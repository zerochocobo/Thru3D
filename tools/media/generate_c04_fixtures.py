"""Deterministic, project-owned C04 RGB/Alpha samples; never processes user media."""
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

ROOT = Path(__file__).resolve().parents[2]
WIDTH, HEIGHT = 1280, 640

def packed_destination(x: int, y: int, aw: int, ah: int) -> tuple[int, int]:
    # Independent fixture transcription of PTMediaServer alpha_layout_source inverse.
    half, quarter = aw // 2, aw // 4
    dx = WIDTH // 2 - half // 2 + x if x < half else (
        WIDTH - quarter + x - half if x < half + quarter else x - half - quarter)
    dy = HEIGHT - ah // 2 + y if y < ah // 2 else y - ah // 2
    return dx, dy

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    media = ROOT / 'app/godot/media'
    media.mkdir(parents=True, exist_ok=True)
    aw, ah = max(4, round(WIDTH * .4) & ~3), max(2, round(HEIGHT * .4) & ~1)
    mask = np.empty((ah, aw), dtype=np.uint8)
    # Different eyes and top/bottom expose all six tiles, including outer wrapped quarters.
    for y in range(ah):
        for x in range(aw):
            eye, local = divmod(x, aw // 2)
            band = min(4, local * 5 // (aw // 2))
            value = ([0, 64, 128, 192, 255] if eye == 0 else [255, 192, 128, 64, 0])[band]
            mask[y, x] = value if y >= ah // 2 else round(value * .5)
    yy, xx = np.indices((HEIGHT, WIDTH))
    eye_x = xx % (WIDTH // 2)
    circle = ((eye_x + .5 - WIDTH / 4) ** 2 + (yy + .5 - HEIGHT / 2) ** 2) <= (HEIGHT / 2) ** 2
    colors = np.where((xx < WIDTH // 2)[..., None], [224, 48, 32], [32, 80, 224]).astype(np.uint8)
    flat = colors.copy()
    fisheye = np.where(circle[..., None], colors, 0).astype(np.uint8)
    # Markers stay away from numeric probe locations.
    for rgb in [flat, fisheye]:
        for eye in range(2):
            for y in [100, 540]:
                cv2.putText(rgb, ('LEFT' if eye == 0 else 'RIGHT') + (' TOP' if y == 100 else ' BOTTOM'),
                            (eye * 640 + 190, y), cv2.FONT_HERSHEY_SIMPLEX, .7, (255,255,255), 2)
    packed = fisheye.copy()
    for y in range(ah):
        for x in range(aw):
            dx, dy = packed_destination(x, y, aw, ah)
            packed[dy, dx] = [mask[y, x], 0, 0]
    full_mask = cv2.resize(mask, (WIDTH, HEIGHT), interpolation=cv2.INTER_LINEAR)
    images = {'c04_alpha_f180_rgb.png': packed, 'c04_independent_rgb.png': flat,
              'c04_packed_mask_oracle.png': mask, 'c04_independent_mask.png': full_mask}
    for name, pixels in images.items():
        target = media / name
        assert cv2.imwrite(str(target), pixels[..., ::-1] if pixels.ndim == 3 else pixels)
    version = subprocess.check_output([args.ffmpeg, '-version'], text=True).splitlines()[0]
    items = []
    for name in ['c04_alpha_f180', 'c04_independent_alpha']:
        image_name = 'c04_alpha_f180_rgb.png' if name == 'c04_alpha_f180' else 'c04_independent_rgb.png'
        path = media / (name + '.mp4')
        command = [args.ffmpeg,'-hide_banner','-loglevel','error','-y','-loop','1','-framerate','30','-i',str(media/image_name),
                   '-f','lavfi','-i','sine=frequency=660:sample_rate=48000:duration=6','-t','6',
                   '-vf','scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
                   '-c:v','libx264','-preset','fast','-crf','12','-profile:v','high','-pix_fmt','yuv420p',
                   '-color_range','tv','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709',
                   '-c:a','aac','-b:a','96k','-movflags','+faststart','-shortest',str(path)]
        subprocess.run(command,check=True)
        subprocess.run([args.ffmpeg,'-hide_banner','-loglevel','error','-i',str(path),'-f','null','NUL'],check=True)
        items.append({'file':str(path.relative_to(ROOT)).replace('\\','/'),'bytes':path.stat().st_size,
                      'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'geometry':'F180 SBS' if name == 'c04_alpha_f180' else 'flat SBS',
                      'alpha':'six-block red' if name == 'c04_alpha_f180' else 'independent static numeric texture'})
    assets = [*items,*[{'file':str((media/name).relative_to(ROOT)).replace('\\','/'),
                      'bytes':(media/name).stat().st_size,'sha256':hashlib.sha256((media/name).read_bytes()).hexdigest()} for name in images]]
    manifest = {'schema_version':1,'source':'Project-generated static RGB, known mask and 660 Hz tone',
                'rights':'Project-owned synthetic calibration media','generator':'tools/media/generate_c04_fixtures.py',
                'ffmpeg':version,'width':WIDTH,'height':HEIGHT,'fps':30,'frames':180,'duration_seconds':6,
                'packed_dimensions':[aw,ah],'pack_scale':.4,'radius_scale':1.0,'lens_fov':180,
                'rgb_per_eye':[[224,48,32],[32,80,224]],'alpha_values_left':[0,64,128,192,255],
                'alpha_values_right':[255,192,128,64,0],'top_alpha_scale':.5,'bottom_alpha_scale':1.0,
                'codec':'H264 high yuv420p BT709 SDR; AAC mono 48k','assets':assets,
                'android_validation':'not_run','scope':'Display/alpha fixture only; no RVM quality or performance evidence'}
    target = ROOT/'tests/fixtures/c04_alpha.json'
    target.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'manifest':str(target),'assets':len(assets)},indent=2))

if __name__ == '__main__':
    main()
