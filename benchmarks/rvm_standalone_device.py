"""Audit actual Quest traces against independent ONNX lineage and production transfer invariants."""
import copy
import hashlib
import json
import math
from pathlib import Path
import sys
import tarfile
import zipfile

from native_rvm_resident.verify import validate as validate_resident

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ('256x144','384x216','512x288','256x256','384x384','512x512')
MODES = ('cpu','vulkan','resident')
CHECKS = ['stereo_two_frame_oracle','duplicate_frame','equal_generation_reset','stale_generation',
          'invalid_right_eye','failed_stereo_no_state_commit','overlapping_output','wrong_buffer_size',
          'rejected_buffer_no_state_commit','closed_runtime','close_and_prepare_new_session']

def read(p): return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,d): Path(p).write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def lineage(key):
    model=ROOT/'build/rvm'/key
    fixture=ROOT/'build/rvm-resident-fixtures'/key
    manifest=read(fixture/'manifest.json')
    profile=read(model/'profile.json')
    assert manifest['reference_backend']=='ONNX Runtime CPUExecutionProvider'
    assert manifest['frames_per_eye']==4 and len(manifest['files'])==48 and manifest['profile']==key
    assert manifest['model_manifest_sha256']==sha(model/'profile.json')
    assert manifest['fixed_onnx_sha256']==sha(model/'rvm.fixed.onnx')
    for name,record in manifest['files'].items():
        assert (fixture/name).stat().st_size==record['bytes'] and sha(fixture/name)==record['sha256']
    return manifest,profile

def prepare(directory):
    manifests={key:lineage(key)[0] for key in PROFILES}
    with tarfile.open(directory/'fixtures.tar','w') as archive:
        for key in PROFILES:
            for name in manifests[key]['files']:
                archive.add(ROOT/'build/rvm-resident-fixtures'/key/name,arcname=key+'/'+name,recursive=False)
    write(directory/'fixture-lineage.json',manifests)

def number(value,bound):
    assert type(value) in (float,int) and math.isfinite(value) and 0<=value<=bound

def verify_trace(result,receipts,reports,profiles,device_hashes):
    assert result['state']=='collected_scoped_rvm_trace'
    assert result['apk_sha256']==result['installed_sha256'] and result['activity_launched'] is False
    ids=set()
    for mode in MODES:
        for key in PROFILES:
            name=mode+'_'+key
            receipt=receipts[name]; report=reports[name]
            assert receipt['state']=='accepted' and receipt['action'].endswith('.DEBUG_RVM_STANDALONE')
            assert receipt['request'].startswith('rvm_') and receipt['id']>0
            assert (receipt['diagnostic_process'],receipt['id']) not in ids
            ids.add((receipt['diagnostic_process'],receipt['id']))
            assert report['diagnostic_process']==receipt['diagnostic_process'] and report['probe_id']==receipt['id']
            assert report['requested_profile']==key and report['mode']==mode and report['state']=='passed'
            assert report['standalone'] is True and report['activity_launched'] is False
            assert 0<report['elapsed_ms']<180000
            if mode=='resident':
                assert report['profile']==key
                validate_resident(report,profiles[key])
                for field in ('alpha_max_abs','recurrent_max_abs','alpha_max_rms','recurrent_max_rms',
                              'reset_rollback_max_abs','isolation_max_abs','rejected_state_max_abs'):
                    number(report[field],1) # reject NaN/Infinity independently of native JSON labels
            else:
                assert report['backend']=='ncnn_'+mode and report['profile_key']==key
                assert report['requested_vulkan']==(mode=='vulkan') and report['frames_per_eye']==2
                assert report['state_storage']=='host_fp32_validation' and report['threads']==4
                assert report['quality_tested'] is report['thermal_tested'] is report['video_integrated'] is False
                assert set(report['errors'])=={'fgr','pha','r1o','r2o','r3o','r4o'}
                for output,error in report['errors'].items():
                    number(error['max_abs'],1e-4 if output in ('fgr','pha') else 1e-3)
                    number(error['rms'],1e-4)
                for field in ('isolation_max_abs','reset_max_abs','stereo_max_abs','rollback_max_abs'):
                    number(report[field],1e-6)
                assert report['invalid_eye_rejected'] is True
                assert len(report['validation_process_ms'])==4
                assert all(type(x) in (int,float) and math.isfinite(x) and x>0 for x in report['validation_process_ms'])
                bridge=report['runtime_bridge']
                assert bridge['state']=='passed' and bridge['checks']==CHECKS
                number(bridge['alpha_max_abs'],1e-4)
                assert len(bridge['frame_reports'])==5
                shape=profiles[key]['input_shapes']['src']; width,height=shape[-1],shape[-2]
                state_bytes=sum(s[1]*s[2]*s[3]*4 for k,s in profiles[key]['output_shapes'].items() if k.startswith('r'))
                for i,frame in enumerate(bridge['frame_reports']):
                    assert frame['state']=='ready' and frame['profile_key']==key
                    assert frame['state_storage']==('VkMat_FP32' if mode=='vulkan' else 'host_fp32')
                    assert frame['generation']==([1,1,2,2,1][i]) and frame['frame_id']==([0,1,0,1,0][i])
                    assert frame['pts_us']==([0,33333,0,33333,0][i]) and frame['session_id']==(2 if i==4 else 1)
                    assert frame['source_pts_verified'] is False and frame['video_integrated'] is False
                    assert frame['internal_ncnn_transfer_traffic_measured'] is False
                    totals=frame['explicit_gpu_transfer_totals']
                    if mode=='vulkan':
                        count=i+1 if i<4 else 1
                        assert totals==dict(rgb_upload_bytes=count*2*width*height*3*4,
                            initial_state_upload_bytes=state_bytes*(2 if i<2 or i==4 else 4),
                            alpha_download_bytes=count*2*width*height*4,validation_upload_bytes=count*32,
                            validation_download_bytes=count*32,committed_stereo_frames=count,diagnostic_state_download_bytes=0)
                    else:
                        assert all(type(v) is int and v==0 for v in totals.values())
            assert report.get('storage_error') is None
    for key,expected in device_hashes.items():
        assert expected['actual']==expected['expected'] and len(expected['actual'])==48

def verify(directory):
    result=read(directory/'result.json')
    assert result['apk_sha256']==sha(ROOT/'artifacts/quest3-player-debug.apk')
    assert read(directory/'build_manifest.json')['apk_sha256']==result['apk_sha256']
    manifests=read(directory/'fixture-lineage.json')
    profiles={}; hashes={}
    with zipfile.ZipFile(ROOT/'artifacts/quest3-player-debug.apk') as apk:
        for key in PROFILES:
            manifest,profile=lineage(key)
            assert manifests[key]==manifest
            profiles[key]=profile
            bundle=read(ROOT/'android/player-plugin/src/main/assets/rvm/bundle_manifest.json')
            packaged=[p for p in bundle['profiles'] if p['key']==key][0]
            assert packaged['param_sha256']==profile['ncnn_param_sha256']
            assert bundle['bin_sha256']==profile['ncnn_bin_sha256']
            # Check all declared APK model/oracle assets, not a recomputed output label.
            actual={}
            for line in (directory/(key+'-device-fixtures.sha256')).read_text(encoding='utf-8-sig').splitlines():
                digest,path=line.split(None,1); actual[Path(path.strip()).name]=digest
            hashes[key]={'actual':actual,'expected':{n:r['sha256'] for n,r in manifest['files'].items()}}
        for asset in bundle['assets']:
            assert hashlib.sha256(apk.read('assets/'+asset['path'])).hexdigest()==asset['sha256']
    names=[m+'_'+p for m in MODES for p in PROFILES]
    receipts={n:read(directory/(n+'-receipt.json')) for n in names}
    reports={n:read(directory/(n+'-report.json')) for n in names}
    verify_trace(result,receipts,reports,profiles,hashes)
    rejected=[]
    data=[result,receipts,reports,profiles,hashes]
    def reject(name,mutate):
        bad=copy.deepcopy(data); mutate(bad)
        try: verify_trace(*bad)
        except (AssertionError,ValueError,KeyError,TypeError): rejected.append(name)
        else: raise AssertionError('Polluted RVM evidence accepted: '+name)
    reject('wrong_apk',lambda d:d[0].update(installed_sha256='0'*64))
    reject('activity_scope',lambda d:d[0].update(activity_launched=True))
    reject('stale_id',lambda d:d[2]['resident_256x144'].update(probe_id=99999))
    reject('stale_process',lambda d:d[2]['resident_256x144'].update(diagnostic_process='stale'))
    reject('wrong_profile',lambda d:d[2]['resident_256x144'].update(profile='512x512'))
    reject('cpu_instead_of_resident',lambda d:d[2]['resident_256x144'].update(state_storage='host_fp32'))
    reject('resident_bad_state',lambda d:d[2]['resident_256x144'].update(recurrent_max_abs=1))
    reject('resident_nan',lambda d:d[2]['resident_256x144'].update(alpha_max_abs=float('nan')))
    reject('guard_missing',lambda d:d[2]['resident_256x144'].update(gpu_finite_guard_verified=False))
    reject('rollback_committed',lambda d:d[2]['resident_256x144'].update(committed_stereo_frames=7))
    reject('fullstate_in_production',lambda d:d[2]['vulkan_256x144']['runtime_bridge']['frame_reports'][0]['explicit_gpu_transfer_totals'].update(diagnostic_state_download_bytes=4))
    reject('wrong_fresh_session',lambda d:d[2]['vulkan_256x144']['runtime_bridge']['frame_reports'][-1].update(session_id=1))
    reject('missing_jni_frames',lambda d:d[2]['vulkan_256x144']['runtime_bridge'].update(frame_reports=[]))
    reject('cpu_bad_recurrence',lambda d:d[2]['cpu_256x144']['errors']['r4o'].update(max_abs=1))
    reject('different_fixture',lambda d:d[4]['256x144']['actual'].update({'left_0.src.f32':'0'*64}))
    reject('identity_contract_missing',lambda d:d[2]['resident_256x144'].update(identity_tile_contract_verified=False))
    reject('CPU_state_Tile_fallback',lambda d:d[2]['resident_256x144'].update(non_vulkan_layers=['Tile:expand_146']))
    reject('missing_phase_samples',lambda d:d[2]['resident_256x144'].update(phase_ms=[]))
    reject('incomplete_phase',lambda d:d[2]['resident_256x144']['phase_ms'][0].update(completed=False))
    reject('nonfinite_phase',lambda d:d[2]['resident_256x144']['phase_ms'][0].update(submit_wait=float('nan')))
    reject('negative_phase',lambda d:d[2]['resident_256x144']['phase_ms'][0].update(input_validation=-1))
    reject('phase_total_mismatch',lambda d:d[2]['resident_256x144']['phase_ms'][0].update(total=1e9))
    output=dict(state='passed_scoped_six_profile_cpu_vulkan_resident_and_JNI',apk_sha256=result['apk_sha256'],
        cases=18,profiles=list(PROFILES),polluted_evidence_rejected=rejected,
        resident_alpha_max_abs=max(reports['resident_'+p]['alpha_max_abs'] for p in PROFILES),
        resident_recurrent_max_abs=max(reports['resident_'+p]['recurrent_max_abs'] for p in PROFILES),
        scope=result['scope'],quality_verified=False,video_XR_verified=False,thermal_verified=False,
        sustained_performance_verified=False,internal_ncnn_transfer_traffic_measured=False)
    write(directory/'rvm-verified.json',output)
    print(json.dumps(output,indent=2))

if __name__=='__main__':
    directory=Path(sys.argv[2]).resolve()
    {'prepare':prepare,'verify':verify}[sys.argv[1]](directory)
