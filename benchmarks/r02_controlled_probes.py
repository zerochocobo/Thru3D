"""Compare Quest model-size RGB samples with independently decoded project fixtures."""
from __future__ import annotations
import os
from pathlib import Path
import argparse
import json
from pathlib import Path
import subprocess
import re
import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = {'c03_sbs_grid', 'c04_alpha_f180', 'c04_independent_alpha'}

def surface_color_reference(source: np.ndarray, frame: dict, fixture: str, ffmpeg: str,
                            yuv: tuple[np.ndarray,np.ndarray,np.ndarray] | None = None) -> tuple[np.ndarray, dict]:
    """Use independently parsed AVC SPS plus the recorded producer matrix.
    This fixture reference supports progressive 4:2:0, axis-aligned crop/flip only.
    Require the observed matrix to agree with Android's YUV crop-border rule.
    """
    trace = subprocess.run([ffmpeg, '-hide_banner', '-i', str(ROOT/'app/godot/media'/f'{fixture}.mp4'),
                            '-map', '0:v:0', '-c', 'copy', '-bsf:v', 'trace_headers', '-f', 'null', '-'],
                           check=True, capture_output=True, text=True, encoding='utf-8', timeout=30).stderr
    def field(name: str, default: int | None = None) -> int:
        values = [int(v) for v in re.findall(r'\b'+re.escape(name)+r'\s+[01]+\s*=\s*(\d+)', trace)]
        if not values and default is not None:
            return default
        if not values or len(set(values)) != 1:
            raise ValueError(f'Missing/dynamic AVC SPS field: {name}')
        return values[0]
    if field('frame_mbs_only_flag') != 1 or field('chroma_format_idc', 1) != 1:
        raise ValueError('This independent reference requires progressive YUV420 AVC fixtures')
    bw = (field('pic_width_in_mbs_minus1')+1)*16
    bh = (field('pic_height_in_map_units_minus1')+1)*16
    left, right = field('frame_crop_left_offset',0)*2, field('frame_crop_right_offset',0)*2
    top, bottom = field('frame_crop_top_offset',0)*2, field('frame_crop_bottom_offset',0)*2
    h, w = source.shape[:2]
    if (bw-left-right, bh-top-bottom) != (w,h) or frame['source_crop'] != [left,top,left+w-1,top+h-1]:
        raise ValueError('SPS decoded crop differs from the exact captured frame descriptor')
    matrix = np.asarray(frame['surface_texture_transform'], dtype=np.float32).reshape(4,4,order='F')
    expected = np.eye(4,dtype=np.float32)
    expected[0,0] = (w-2)/bw if w < bw else 1
    expected[0,3] = (left+1)/bw if w < bw else 0
    expected[1,1] = -(h-2)/bh if h < bh else -1
    expected[1,3] = (top+h-1)/bh if h < bh else 1
    difference = float(np.abs(matrix-expected).max())
    if not np.isfinite(matrix).all() or difference > 1e-6:
        raise ValueError('Observed producer matrix requires another backing layout/transform; do not guess its dimensions')
    # OES -> visible RGBA8 copy first, then the separate per-eye model-size sampler.
    u = (np.arange(w,dtype=np.float32)+.5)/w
    v = (np.arange(h,dtype=np.float32)+.5)/h
    sx = (matrix[0,0]*u+matrix[0,3])*bw-left-.5
    sy = (matrix[1,1]*(1-v)+matrix[1,3])*bh-top-.5
    xmap = np.broadcast_to(sx[None,:],(h,w)).copy()
    ymap = np.broadcast_to(sy[:,None],(h,w)).copy()
    if yuv is None:
        color = cv2.remap(source,xmap,ymap,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
    else:
        if frame['color_standard'] != 1 or frame['color_range'] != 2:
            raise ValueError('This explicit YUV reference supports BT709 limited-range fixtures only')
        luma = (cv2.remap(yuv[0],xmap,ymap,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)-16)/219
        # Centered 4:2:0 chroma uses the same normalized UV as the luma plane.
        cb = (cv2.remap(yuv[1],xmap/2-.25,ymap/2-.25,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)-128)/224
        cr = (cv2.remap(yuv[2],xmap/2-.25,ymap/2-.25,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)-128)/224
        color = np.stack((luma+1.5748*cr,luma-.187324*cb-.468124*cr,luma+1.8556*cb),axis=2)
    color = np.rint(color*255).clip(0,255).astype(np.float32)/255
    return color, {'coded_width':bw,'coded_height':bh,'crop':[left,top,w,h],
                   'matrix_max_abs_from_android_yuv_rule':difference,
                   'reference':'AVC SPS + recorded SurfaceTexture + separate RGBA8/model-size bilinear stages',
                   'color_reference':'centered_bilinear_YUV420_BT709_limited' if yuv is not None else 'FFmpeg_default_RGB_conversion'}


def verify(report_path: Path, ffmpeg: str, apply_surface: bool = False, yuv_reference: bool = False) -> dict:
    fixture = report_path.stem.removeprefix('controlled_')
    if fixture not in FIXTURES:
        raise ValueError('Only project-owned calibration fixtures are allowed')
    report = json.loads(report_path.read_text(encoding='utf-8-sig'))
    frame = report['frame']
    if report['state'].get('state') != 'ended' or not frame['source_pts_verified'] or not frame['immutable_color_frame']:
        raise ValueError('Missing completed controlled capture evidence')
    width, height = frame['width'], frame['height']
    command = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-ss', str(frame['pts_us']/1e6),
               '-i', str(ROOT/'app/godot/media'/f'{fixture}.mp4'), '-frames:v', '1',
               '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1']
    pixels = subprocess.run(command, check=True, capture_output=True).stdout
    if len(pixels) != width*height*3:
        raise ValueError('Expected one full source frame at the captured PTS')
    source = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, 3).astype(np.float32)/255
    reference = {'reference':'decoded visible RGB; producer crop-border transform not applied'}
    if apply_surface or yuv_reference:
        planes = None
        if yuv_reference:
            yuv_command = command.copy(); yuv_command[yuv_command.index('rgb24')] = 'yuv420p'
            blob = subprocess.run(yuv_command,check=True,capture_output=True).stdout
            size = width*height
            if width % 2 or height % 2 or len(blob) != size*3//2:
                raise ValueError('Expected one complete YUV420 frame')
            raw = np.frombuffer(blob,dtype=np.uint8).astype(np.float32)
            planes = raw[:size].reshape(height,width),raw[size:size*5//4].reshape(height//2,width//2),raw[size*5//4:].reshape(height//2,width//2)
        source, reference = surface_color_reference(source,frame,fixture,ffmpeg,planes)
    iw, ih = frame['input_width'], frame['input_height']
    rect = frame['model_content_rect']
    probes = frame['rgb_probes']
    if len(probes) != 70:
        raise ValueError('Expected 35 spatial RGB probes per eye, including letterbox boundaries')
    errors = []
    worst = None
    for probe in probes:
        eye = probe['eye']
        x, y = probe['pixel']
        if eye not in (0, 1) or not (0 <= x < iw and 0 <= y < ih):
            raise ValueError('Invalid probe identity')
        p = ((x+.5)/iw-rect[0])/rect[2], ((y+.5)/ih-rect[1])/rect[3]
        if not (0 <= p[0] <= 1 and 0 <= p[1] <= 1):
            expected = np.zeros(3, dtype=np.float32)
        else:
            ew = width//2 if frame['stereo_sbs'] else width
            ex = eye*ew if frame['stereo_sbs'] else 0
            sx = np.clip(p[0]*ew-.5, 0, ew-1)+ex
            sy = np.clip(p[1]*height-.5, 0, height-1)
            expected = cv2.remap(source, np.array([[sx]], np.float32), np.array([[sy]], np.float32),
                                 cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)[0, 0]
        actual = np.asarray(probe['rgb'], dtype=np.float32)
        if actual.shape != (3,) or not np.isfinite(actual).all():
            raise ValueError('Invalid RGB sample')
        errors.append(float(np.abs(expected-actual).max()))
        if worst is None or errors[-1] > worst['max_abs']:
            worst = {'eye': eye, 'pixel': [x, y], 'expected_rgb': expected.tolist(),
                     'observed_rgb': actual.tolist(), 'max_abs': errors[-1]}
    maximum = max(errors)
    # Allow independent SDR YUV conversion and bilinear filter rounding; do not
    # use this broad pixel tolerance for RVM floating-point numerical validation.
    return {'fixture': fixture, 'pts_us': frame['pts_us'], 'samples': len(errors),
            'max_abs': maximum, 'worst_probe': worst, 'source_reference':reference,
            'limit': .08, 'state': 'passed' if maximum <= .08 else 'failed'}

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    parser.add_argument('--fixtures', nargs='+', choices=sorted(FIXTURES), default=sorted(FIXTURES))
    parser.add_argument('--apply-surface-transform',action='store_true',help='Use recorded crop-border matrix and independent AVC SPS; preserve original comparison')
    parser.add_argument('--yuv-reference',action='store_true',help='Explicit centered bilinear YUV420/BT709 source variant; separate report, unchanged error limit')
    args = parser.parse_args()
    results = [verify(args.evidence/f'controlled_{fixture}.json', args.ffmpeg,args.apply_surface_transform,args.yuv_reference) for fixture in args.fixtures]
    passed = all(result['state'] == 'passed' for result in results)
    output = {'schema_version': 1, 'state': 'passed' if passed else 'failed', 'results': results,
              'scope': 'Final-frame sampled RGB, eye separation, orientation and letterbox; no audio or RVM quality proof'}
    filename = 'rgb-probe-yuv-check.json' if args.yuv_reference else ('rgb-probe-transform-check.json' if args.apply_surface_transform else 'rgb-probe-check.json')
    (args.evidence/filename).write_text(json.dumps(output, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(output, indent=2))
    if not passed:
        raise SystemExit(1)

if __name__ == '__main__':
    main()
