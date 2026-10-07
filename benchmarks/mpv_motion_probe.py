"""Audit continuous moving MPV input, independent eye recurrence and actual R8.

Reference limits are fixed before execution: existing R02 SDR input bound .08,
existing R03 video Alpha max-abs 1e-5, plus R01 FP32 1e-4 reported separately.
Diagnostic I/O and sequential processing are not sustained playback evidence.
"""
import os
from pathlib import Path
import argparse
import copy
import hashlib
import json
from fractions import Fraction
from pathlib import Path
import re
import subprocess
import tarfile

import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
RGB_LIMIT = .08
ALPHA_LIMIT = 1e-5

def read(p): return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def require(value, reason):
    if not value: raise ValueError(reason)

def validate(report):
    require(report['state'] == 'passed_native_checks' and report['resources_closed'], 'Native run/cleanup incomplete')
    require(report['fixture'] == 'mp07_motion_4k' and report['profile'] in ('256x144','384x216','512x288','256x256','384x384','512x512'), 'Unexpected fixture/profile')
    require(not report['audio_enabled'] and not report['godot_context_shared'] and not report['xr_entry'], 'Scope changed')
    require(re.fullmatch(r'mpv_motion_[a-f0-9-]{36}_\d+',report['evidence_directory']), 'Unsafe evidence path')
    terminal=report['terminal_status']
    require(terminal['state']=='ended' and terminal['eof_source_resolved'] and not terminal['error'] and
            not terminal['render_failed'] and not terminal['render_error'] and
            terminal['details']['hwdec_current']=='mediacodec', 'Decode/EOF/hardware failure')
    records=report['records']; require(12 <= len(records) <= 180, 'Incomplete or unbounded motion sequence')
    if report.get('ordered_frames',False):
        require(len(records)==180 and [p['pts_us'] for p in records]==[round(i*1e6/30) for i in range(180)],
                'Ordered sequence must contain all 180 source frames')
        require(terminal['debug_step_images']==179 and terminal['debug_steps_applied'] in (179,180) and
                terminal['seeks_started']==terminal['seeks_completed']==0, 'Forward steps or no-seek contract differ')
    previous=(-1,-1); first=records[0]
    width,height=map(int,report['profile'].split('x'))
    for ordinal,pair in enumerate(records,1):
        k=pair['kernel']; current=(pair['frame_id'],pair['pts_us'])
        require(current[0]>previous[0] and current[1]>previous[1], 'Nonmonotonic source identity')
        require(pair['ordinal']==ordinal and (pair['width'],pair['height'],pair['rotation_degrees'])==(3840,2160,0), 'Wrong source dimensions/ordinal')
        require(pair['source_flags'] & 19 == 19 and pair['owner_context_shared'] and pair['producer_fence_ready'] and
                pair['immutable_color_frame'], 'Source render ticket/fence missing')
        require(pair['source_epoch']==first['source_epoch'] and pair['source_epoch']>0, 'Unexpected reset/seek')
        require(k['state']=='ready' and k['state_storage']=='VkMat_FP32' and k['profile_key']==report['profile'] and
                k['session_id']==1_000_000+report['request_id'] and k['generation']==1 and
                (k['frame_id'],k['pts_us'])==current, 'Wrong recurrent runtime/source association')
        transfers=k['explicit_gpu_transfer_totals']
        require(transfers['committed_stereo_frames']==ordinal and transfers['diagnostic_state_download_bytes']==0 and
                transfers['validation_download_bytes']==ordinal*32, 'Missing committed recurrence or state readback')
        require(pair['alpha_gpu_uploaded'] and pair['alpha_fence_ready'] and pair['alpha_byte_mismatches']==0 and
                pair['alpha_slot_token']>0 and (pair['input_width'],pair['input_height'])==(width,height), 'Wrong Alpha/input shape')
        require(np.isfinite(pair['rvm_process_ms']) and pair['rvm_process_ms']>0, 'Invalid process timing')
        require(set(pair['files'])=={'left_rgb','right_rgb','left_alpha','right_alpha','mask'}, 'Missing evidence buffer')
        for key,record in pair['files'].items():
            require(record['file']==f"frame_{ordinal}_{key}.{'r8' if key=='mask' else 'f32'}", 'Evidence filename mismatch')
            count=width*height*(2 if key=='mask' else 12 if key.endswith('rgb') else 4)
            require(record['bytes']==count and re.fullmatch('[0-9a-f]{64}',record['sha256']), 'Invalid evidence size/hash')
        previous=current
    target=terminal['eof_source_ticket']
    require(previous==(target['frame_id'],target['pts_us']) and previous[1]==5_966_667, 'Final source frame not processed')
    require(records[0]['pts_us']<500_000 and len({p['pts_us']//1_000_000 for p in records})==6, 'Motion did not span six seconds')
    return records

def collect(report,directory,adb,serial):
    records=validate(report); name=report['evidence_directory']; dest=directory/name; dest.mkdir(exist_ok=True)
    expected={r['file']:r for p in records for r in p['files'].values()}
    archive=directory/'motion-buffers.tar'
    with archive.open('wb') as output:
        subprocess.run([adb,'-s',serial,'exec-out','run-as','org.vrpassthroughplayer.quest',
            'tar','cf','-','-C','files/diagnostics',name],stdout=output,check=True,timeout=300 if report.get('ordered_frames') else 90)
    with tarfile.open(archive) as tar:
        seen=set()
        for item in tar:
            if item.isdir() and item.name.rstrip('/')==name: continue
            filename=Path(item.name).name
            require(item.isfile() and item.name==name+'/'+filename and filename in expected and filename not in seen,
                    'Unexpected archive member')
            record=expected[filename]; require(item.size==record['bytes'],'Archive buffer size changed')
            blob=tar.extractfile(item).read(); require(hashlib.sha256(blob).hexdigest()==record['sha256'],'Buffer SHA changed')
            (dest/filename).write_bytes(blob); seen.add(filename)
        require(seen==set(expected),'Missing archive buffers')
    return dest

def buffer(directory,record,shape,dtype='<f4'):
    require(sha(directory/record['file'])==record['sha256'],'Collected file changed')
    values=np.fromfile(directory/record['file'],dtype=dtype)
    require(values.size==np.prod(shape) and values.nbytes==record['bytes'],'Buffer shape differs')
    values=values.reshape(shape)
    require(np.isfinite(values).all() and (dtype=='u1' or (values.min()>=0 and values.max()<=1)), 'Nonfinite/range violation')
    return values

def source_references(video,records,width,height,ffmpeg,aspect_log=None,yuv_reference=False):
    """Independently decode source RGB then sample exact model pixel centers.
    FFmpeg YUV conversion can differ from MPV: preserve the existing SDR bound.
    Read one full frame at a time, never buffer the 4K sequence in memory.
    """
    metadata=json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe.exe')),'-v','error',
        '-select_streams','v:0','-show_entries','frame=best_effort_timestamp_time','-of','json',str(video)]))
    pts=[round(float(f['best_effort_timestamp_time'])*1e6) for f in metadata['frames']]
    require(len(pts)==180 and pts==[round(i*1e6/30) for i in range(180)],'Encoded motion timeline differs')
    display_height=2160
    require(not yuv_reference or aspect_log is not None, 'YUV reference requires recorded aspect/shader evidence')
    if aspect_log is not None:
        stream=json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe.exe')),'-v','error',
            '-select_streams','v:0','-show_entries','stream=width,height,sample_aspect_ratio','-of','json',str(video)]))['streams'][0]
        sar=float(Fraction(stream['sample_aspect_ratio'].replace(':','/')))
        require((stream['width'],stream['height'])==(3840,2160) and 1<=sar<1.01,'Unsupported independent aspect geometry')
        display_height=int(2160/sar)
        require(f'Video display: (0, 0) 3840x2160 -> (0, 0) 3840x{display_height}' in aspect_log,
                'Encoded SAR aspect fit differs from actual MPV render geometry')
        require('pow(color.rgb, vec3(2.4))' in aspect_log and 'pow(color.rgb, vec3(1.0/2.4))' in aspect_log,
                'Expected actual MPV linear-light resize shaders missing')
        if yuv_reference:
            require(stream['width'] % 2 == 0 and stream['height'] % 2 == 0, 'YUV420 dimensions must be even')
            color=json.loads(subprocess.check_output([str(Path(ffmpeg).with_name('ffprobe.exe')),'-v','error',
                '-select_streams','v:0','-show_entries','stream=pix_fmt,color_range,color_space,color_transfer,color_primaries',
                '-of','json',str(video)]))['streams'][0]
            require(color == dict(pix_fmt='yuv420p', color_range='tv', color_space='bt709',
                                 color_transfer='bt709', color_primaries='bt709'), 'Explicit reference requires SDR BT709 limited YUV420')
            require('Using FBO format rgba16f.' in aspect_log and 'samplerExternalOES texture0' in aspect_log and
                    'mediacodec bt.709/bt.709/bt.1886/limited/display CL=mpeg1/jpeg' in aspect_log and
                    'color-standard = 1' in aspect_log and 'color-range = 2' in aspect_log,
                    'Observed OES/centered chroma/BT709/RGBA16F assumptions missing')
    indices=[]
    for pair in records:
        index=min(range(len(pts)),key=lambda i:abs(pts[i]-pair['pts_us']))
        require(abs(pts[index]-pair['pts_us'])<=1,'Source PTS has no decoded frame')
        indices.append(index)
    expression='+'.join(f'eq(n\\,{i})' for i in indices)
    process=subprocess.Popen([ffmpeg,'-v','error','-i',str(video),'-vf','select='+expression,'-fps_mode','passthrough',
        '-pix_fmt','yuv420p' if yuv_reference else 'rgb24','-f','rawvideo','pipe:1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    size=3840*2160*3//2 if yuv_reference else 3840*2160*3
    eye_width=1920; source_height=2160
    # Independent aspect-fit transform: each 1920x2160 eye fits centered inside
    # the model rectangle. Model rows and producer rows are canonical top first.
    scaled_width=eye_width/source_height*height; offset=(width-scaled_width)/2
    px=(np.arange(width)+.5-offset)/scaled_width
    py=(np.arange(height)+.5)/height
    inside=(px>=0)&(px<=1)
    x=np.clip(px*eye_width-.5,0,eye_width-1); y=np.clip(py*source_height-.5,0,source_height-1)
    x0=np.floor(x).astype(int); x1=np.minimum(x0+1,eye_width-1); dx=(x-x0)[None,:,None]
    y0=np.floor(y).astype(int); y1=np.minimum(y0+1,source_height-1); dy=(y-y0)[:,None,None]
    references={}
    try:
        for index in indices:
            parts=bytearray()
            while len(parts)<size:
                chunk=process.stdout.read(size-len(parts))
                require(chunk,'Independent decoder ended early'); parts.extend(chunk)
            raw=np.frombuffer(parts,np.uint8)
            if yuv_reference:
                plane_size=3840*source_height
                planes=(raw[:plane_size].reshape(source_height,3840),
                        raw[plane_size:plane_size*5//4].reshape(source_height//2,1920),
                        raw[plane_size*5//4:].reshape(source_height//2,1920))
                def centered_plane(plane,xs,ys):
                    cx=np.clip(xs/2-.25,0,plane.shape[1]-1)
                    cy=np.clip(ys/2-.25,0,plane.shape[0]-1)
                    ix=np.floor(cx).astype(int); iy=np.floor(cy).astype(int)
                    jx=np.minimum(ix+1,plane.shape[1]-1); jy=np.minimum(iy+1,plane.shape[0]-1)
                    bx=(cx-ix)[None,:]; by=(cy-iy)[:,None]
                    return ((plane[iy[:,None],ix[None,:]]*(1-bx)+plane[iy[:,None],jx[None,:]]*bx)*(1-by)+
                            (plane[jy[:,None],ix[None,:]]*(1-bx)+plane[jy[:,None],jx[None,:]]*bx)*by)
                def source_rgb(xs,ys):
                    luma=(planes[0][ys[:,None],xs[None,:]].astype(np.float64)-16)/219
                    cb=(centered_plane(planes[1],xs,ys)-128)/224
                    cr=(centered_plane(planes[2],xs,ys)-128)/224
                    return np.clip(np.stack([luma+1.5748*cr,luma-.187324*cb-.468124*cr,luma+1.8556*cb],axis=2),0,1)
            else:
                full=raw.reshape(source_height,3840,3)
            eyes=[]
            for eye in range(2):
                xo=x0+eye*eye_width; xn=x1+eye*eye_width
                def rendered(xs,ys):
                    if aspect_log is None: return full[ys[:,None],xs[None,:]]
                    # Independent source -> full-size MPV FBO, before the separate
                    # model-size GPU sampler. SAR makes this fixture's output
                    # one row shorter; MPV interpolates in linear light.
                    sy=(ys+.5)*source_height/display_height-.5
                    base=np.floor(sy).astype(int); blend=(sy-base)[:,None,None]
                    base=np.clip(base,0,source_height-1); following=np.minimum(base+1,source_height-1)
                    if yuv_reference:
                        # OES RGB -> logged linear-light RGBA16F intermediate;
                        # explicitly preserve that rounding before vertical filtering.
                        first=(source_rgb(xs,base)**2.4).astype(np.float16).astype(np.float64)
                        second=(source_rgb(xs,following)**2.4).astype(np.float16).astype(np.float64)
                        value=(first*(1-blend)+second*blend)**(1/2.4)
                    else:
                        first=full[base[:,None],xs[None,:]].astype(np.float64)/255
                        second=full[following[:,None],xs[None,:]].astype(np.float64)/255
                        value=(first**2.4*(1-blend)+second**2.4*blend)**(1/2.4)
                    value[ys>=display_height]=0
                    return np.floor(value*255+.5)
                small=(rendered(xo,y0)*(1-dx)+rendered(xn,y0)*dx)*(1-dy)+\
                      (rendered(xo,y1)*(1-dx)+rendered(xn,y1)*dx)*dy
                small[:,~inside]=0
                eyes.append(np.floor(small+.5).astype(np.float32).transpose(2,0,1)[None]/255)
            references[index]=eyes
        require(not process.stdout.read(1),'Unexpected extra independent frame')
        stderr=process.stderr.read().decode(errors='replace'); require(process.wait(timeout=30)==0,stderr)
    finally:
        if process.poll() is None: process.kill(); process.wait()
    return indices,references

def main():
    verifier_hash=sha(Path(__file__))
    parser=argparse.ArgumentParser(); parser.add_argument('report',type=Path)
    parser.add_argument('--adb',required=True); parser.add_argument('--serial',required=True)
    parser.add_argument('--ffmpeg',default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg')); parser.add_argument('--reuse-collected',action='store_true')
    parser.add_argument('--aspect-reference',action='store_true',help='Separate report using encoded SAR and logged MPV full-size linear-light aspect fit; limits unchanged')
    parser.add_argument('--yuv-aspect-reference',action='store_true',help='Separate centered YUV420/BT709 and RGBA16F reference; requires observed OES/aspect shaders; limits unchanged')
    args=parser.parse_args(); report=read(args.report); records=validate(report)
    installed=read(args.report.parent/'installed.json'); build=read(args.report.parent/'build_manifest.json')
    receipt=read(args.report.parent/'request.json')
    require(installed['apk_sha256']==installed['installed_sha256']==build['apk_sha256'],'APK identity mismatch')
    require(installed.get('ordered_frames',False)==report.get('ordered_frames',False),'Ordered mode receipt differs')
    require(receipt['state']=='accepted' and receipt['id']==report['request_id'] and
            receipt['diagnostic_process']==report['diagnostic_process'],'Process/request mismatch')
    fixture=read(ROOT/'tests/fixtures/mp07_motion_4k.json'); video=ROOT/fixture['file']
    require(sha(video)==fixture['sha256']==report['fixture_sha256'],'Motion fixture changed')
    directory=args.report.parent/report['evidence_directory'] if args.reuse_collected else collect(report,args.report.parent,args.adb,args.serial)
    profile_dir=ROOT/'build/rvm'/report['profile']; profile=read(profile_dir/'profile.json')
    require(sha(profile_dir/'rvm.fixed.onnx')==profile['onnx_fixed_sha256'],'ONNX model changed')
    width,height=map(int,report['profile'].split('x'))
    aspect_log=(args.report.parent/'logcat.txt').read_text(encoding='utf-8-sig') if args.aspect_reference or args.yuv_aspect_reference else None
    indices,references=source_references(video,records,width,height,args.ffmpeg,aspect_log,args.yuv_aspect_reference)
    options=ort.SessionOptions(); options.intra_op_num_threads=4
    session=ort.InferenceSession(str(profile_dir/'rvm.fixed.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
    states={eye:{key:np.zeros(shape,np.float32) for key,shape in profile['input_shapes'].items() if key!='src'} for eye in range(2)}
    results=[]; previous_inputs=None; motion=[]; foreground=[]
    for position,(pair,index) in enumerate(zip(records,indices)):
        rgb_eyes=[]; alpha_eyes=[]
        for eye,label in enumerate(('left','right')):
            rgb=buffer(directory,pair['files'][label+'_rgb'],[1,3,height,width])
            alpha=buffer(directory,pair['files'][label+'_alpha'],[1,1,height,width])
            outputs=session.run(['pha','r1o','r2o','r3o','r4o'],{'src':rgb,**states[eye]})
            states[eye]={f'r{i+1}i':v for i,v in enumerate(outputs[1:])}
            error=np.abs(alpha-outputs[0]); source_error=np.abs(rgb-references[index][eye])
            results.append(dict(ordinal=pair['ordinal'],eye=label,source_index=index,pts_us=pair['pts_us'],
                alpha_max_abs=float(error.max()),alpha_rms=float(np.sqrt(np.mean(error**2))),
                rgb_max_abs=float(source_error.max()),rgb_rms=float(np.sqrt(np.mean(source_error**2)))))
            rgb_eyes.append(rgb); alpha_eyes.append(alpha[0,0])
        gpu=buffer(directory,pair['files']['mask'],[height,width*2],'u1')
        values=np.concatenate(alpha_eyes,axis=1)
        foreground.append(dict(ordinal=pair['ordinal'],pts_us=pair['pts_us'],max_alpha=float(values.max()),
            foreground_pixels_above_half=int(np.count_nonzero(values>.5)),
            eyes=[dict(eye=label,max_alpha=float(a.max()),foreground_pixels_above_half=int(np.count_nonzero(a>.5)))
                  for label,a in zip(('left','right'),alpha_eyes)]))
        expected=np.floor((values*np.float32(255)).astype(np.float64)+.5).astype(np.uint8)
        require(np.array_equal(gpu,expected),'Independent packed-eye R8 readback differs')
        if previous_inputs is not None: motion.append(float(np.mean(np.abs(np.stack(rgb_eyes)-previous_inputs))))
        previous_inputs=np.stack(rgb_eyes)
        preview_positions={0,len(records)//2,len(records)-1}
        if report.get('ordered_frames'): preview_positions.update({29,59,89,106,119,149})
        if position in preview_positions:
            import cv2
            colors=np.concatenate([v[0].transpose(1,2,0) for v in rgb_eyes],axis=1)
            yy,xx=np.indices(values.shape); background=np.where(((xx//16+yy//16)%2)[...,None],.12,.25)
            composite=colors*values[...,None]+background*(1-values[...,None])
            preview=np.concatenate((colors,np.repeat(values[...,None],3,axis=2),composite),axis=0)
            cv2.imwrite(str(args.report.parent/f'motion_{position:03d}.png'),(np.clip(preview[:,:,::-1],0,1)*255).astype(np.uint8))
        print(json.dumps(dict(ordinal=pair['ordinal'],source_index=index,alpha_max_abs=max(r['alpha_max_abs'] for r in results[-2:]))),flush=True)
    require(max(motion)>.001,'Captured inputs do not show actual movement')
    rejected=[]
    negative_names=['old_frame','missing_commit','wrong_generation','wrong_eye_shape','missing_buffer','wrong_scope','no_final_frame','unfinished_cleanup']
    if report.get('ordered_frames'): negative_names+=['missing_middle_frame','wrong_step_count','wrong_step_images','unexpected_seek']
    for name in negative_names:
        bad=copy.deepcopy(report)
        if name=='old_frame': bad['records'][1]['frame_id']=bad['records'][0]['frame_id']
        elif name=='missing_commit': bad['records'][0]['kernel']['explicit_gpu_transfer_totals']['committed_stereo_frames']=2
        elif name=='wrong_generation': bad['records'][0]['kernel']['generation']=2
        elif name=='wrong_eye_shape': bad['records'][0]['input_width']=1
        elif name=='missing_buffer': del bad['records'][0]['files']['right_rgb']
        elif name=='wrong_scope': bad['xr_entry']=True
        elif name=='no_final_frame': bad['records'].pop()
        elif name=='missing_middle_frame': bad['records'].pop(90)
        elif name=='wrong_step_count': bad['terminal_status']['debug_steps_applied']=181
        elif name=='wrong_step_images': bad['terminal_status']['debug_step_images']=178
        elif name=='unexpected_seek': bad['terminal_status']['seeks_started']=1
        else: bad['resources_closed']=False
        try: validate(bad)
        except (ValueError,KeyError): rejected.append(name)
        else: raise ValueError('Polluted motion evidence accepted: '+name)
    maximum=max(r['alpha_max_abs'] for r in results); color=max(r['rgb_max_abs'] for r in results)
    passed=maximum<=ALPHA_LIMIT and color<=RGB_LIMIT
    checked=dict(state='passed_scoped_motion_numerics' if passed else 'failed_reference_limits',
        verifier_sha256=verifier_hash,fixture_manifest_sha256=sha(ROOT/'tests/fixtures/mp07_motion_4k.json'),
        apk_sha256=installed['apk_sha256'],report_sha256=sha(args.report),source_sha256=fixture['sha256'],
        fixed_onnx_sha256=profile['onnx_fixed_sha256'],profile=report['profile'],frames=len(records),
        acquisition_sha256=installed.get('acquisition_sha256'),acquisition_verifier_sha256=installed.get('verifier_sha256'),
        source_reference=('centered_YUV420_BT709_limited_logged_SAR_linear_light_RGBA16F_reference' if args.yuv_aspect_reference else
                          'encoded_SAR_and_actual_logged_MPV_linear_light_aspect_fit' if args.aspect_reference else 'FFmpeg_RGB_full_frame_no_aspect_transform'),
        native_log_sha256=sha(args.report.parent/'logcat.txt'),
        encoded_frames=180,processed_indices=indices,dropped_source_frames=180-len(indices),
        ordered_frames=report.get('ordered_frames',False),
        alpha_max_abs_limit=ALPHA_LIMIT,alpha_max_abs=maximum,rgb_max_abs_limit=RGB_LIMIT,rgb_max_abs=color,
        strict_video_alpha_state='passed' if maximum<=ALPHA_LIMIT else 'failed',
        rgb_reference_state='passed' if color<=RGB_LIMIT else 'failed',packed_R8_state='passed',
        r01_fp32_numeric_bound_passed=maximum<=1e-4,packed_R8_pixels_checked=len(records)*width*height*2,
        max_input_motion_mean_abs=max(motion),negative_cases_rejected=rejected,results=results,
        foreground_presence=foreground,frames_with_foreground_above_half=sum(f['foreground_pixels_above_half']>0 for f in foreground),
        quality_subjectively_verified=False,godot_display_verified=False,xr_verified=False,audio_verified=False,sustained_fps_verified=False,
        scope='All accepted moving-source inputs and complete independent eye recurrence; same-ticket GPU mask; dropped decoded frames explicit. Diagnostic I/O/worker scheduling are not production FPS')
    filename=('motion-yuv-aspect-verified.json' if args.yuv_aspect_reference else
              'motion-aspect-verified.json' if args.aspect_reference else 'motion-verified.json')
    (args.report.parent/filename).write_text(json.dumps(checked,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in checked.items() if k not in ('results','processed_indices','foreground_presence')}))
    require(passed,'Motion reference limits failed; preserve evidence and investigate')

if __name__=='__main__': main()
