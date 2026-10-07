"""Compare unchanged FP32 model/fixtures on the same Quest; no sustained FPS claim."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import math

ROOT=Path(__file__).resolve().parents[1]
def read(p): return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args()
    baseline=args.baseline.resolve(); candidate=args.candidate.resolve()
    before=read(baseline/'rvm-verified.json'); after=read(candidate/'rvm-verified.json')
    assert before['cases']==after['cases']==18 and before['profiles']==after['profiles']
    assert before['apk_sha256']!=after['apk_sha256']
    assert before['apk_sha256']==read(baseline/'build_manifest.json')['apk_sha256']
    assert after['apk_sha256']==sha(ROOT/'artifacts/quest3-player-debug.apk')
    assert read(baseline/'fixture-lineage.json')==read(candidate/'fixture-lineage.json')
    # Verify raw baseline reports against the frozen prior checkpoint's hashes.
    frozen=read(ROOT/'artifacts/checkpoints'/('rvm-quest-'+before['apk_sha256'][:8])/
        'artifacts/rvm-quest-candidate-verification.json')
    rows=[]
    for key in after['profiles']:
        raw_before=baseline/('resident_'+key+'-report.json')
        relative=raw_before.relative_to(ROOT).as_posix()
        assert sha(raw_before)==frozen['evidence_sha256'][relative]
        a=read(raw_before); b=read(candidate/('resident_'+key+'-report.json'))
        assert a['state']==b['state']=='passed' and a['state_storage']==b['state_storage']=='VkMat_FP32'
        assert a['layer_count']==b['layer_count']
        assert a['layer_count']-a['vulkan_capable_layers']==4
        assert b['vulkan_capable_layers']==b['layer_count'] and b['non_vulkan_layers']==[]
        assert b['identity_tile_contract_verified'] is True
        for samples in (a['stereo_ms'],b['stereo_ms']):
            assert len(samples)==4 and all(type(x) in (int,float) and math.isfinite(x) and x>0 for x in samples)
        old=statistics.median(a['stereo_ms']); new=statistics.median(b['stereo_ms'])
        rows.append(dict(profile=key,baseline_ms=a['stereo_ms'],candidate_ms=b['stereo_ms'],
            baseline_median_ms=old,candidate_median_ms=new,observed_median_ratio=old/new,
            candidate_max_ms=max(b['stereo_ms']),all_four_samples_under_33_333ms=max(b['stereo_ms'])<1000/30))
    record=dict(state='compared_scoped_unchanged_model_Quest_synthetic_samples',
        baseline_apk_sha256=before['apk_sha256'],candidate_apk_sha256=after['apk_sha256'],
        independent_numeric_validation_passed=True,unchanged_fixture_lineage=True,rows=rows,
        scope='Four process_alpha_stereo samples per profile, same Quest static synthetic dataset; snapshots excluded from timer; no XR, video, thermal or sustained FPS claim',
        sustained_performance_verified=False,video_XR_verified=False)
    output=ROOT/'artifacts/rvm-identity-performance-comparison.json'
    output.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,indent=2))

if __name__=='__main__': main()
