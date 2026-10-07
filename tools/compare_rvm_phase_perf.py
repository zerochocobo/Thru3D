"""Compare a frozen Quest baseline with a fully verified phase-timed candidate."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import statistics
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'benchmarks'))
from native_rvm_resident.verify import validate

def read(p): return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    baseline = args.baseline.resolve(); candidate = args.candidate.resolve()
    old = read(baseline/'rvm-verified.json'); new = read(candidate/'rvm-verified.json')
    assert old['cases'] == new['cases'] == 18 and old['profiles'] == new['profiles']
    assert old['apk_sha256'] != new['apk_sha256']
    assert new['apk_sha256'] == sha(ROOT/'artifacts/quest3-player-debug.apk')
    frozen = read(ROOT/'artifacts/checkpoints'/('rvm-quest-'+old['apk_sha256'][:8])/
                  'artifacts/rvm-quest-candidate-verification.json')
    assert read(baseline/'fixture-lineage.json') == read(candidate/'fixture-lineage.json')
    gate = read(ROOT/'artifacts/rvm-standalone-build-check/verification.json')
    assert gate['apk_sha256'] == new['apk_sha256']
    assert gate['debug_rvm_native_optimization'] == 'O2' and gate['debug_rvm_fast_math'] is False
    rows = []; raw_hashes = {}
    for key in new['profiles']:
        before_path = baseline/('resident_'+key+'-report.json')
        assert sha(before_path) == frozen['evidence_sha256'][before_path.relative_to(ROOT).as_posix()]
        after_path = candidate/('resident_'+key+'-report.json')
        before = read(before_path); after = read(after_path)
        validate(after, read(ROOT/'build/rvm'/key/'profile.json'))
        assert before['state'] == 'passed' and before['state_storage'] == after['state_storage'] == 'VkMat_FP32'
        assert before['layer_count'] == after['layer_count']
        assert before['non_vulkan_layers'] == after['non_vulkan_layers'] == []
        assert before['identity_tile_contract_verified'] is True
        raw_hashes[after_path.relative_to(ROOT).as_posix()] = sha(after_path)
        old_median = statistics.median(before['stereo_ms'])
        new_median = statistics.median(after['stereo_ms'])
        rows.append(dict(profile=key,baseline_ms=before['stereo_ms'],candidate_ms=after['stereo_ms'],
            baseline_median_ms=old_median,candidate_median_ms=new_median,observed_median_ratio=old_median/new_median,
            phases_ms=after['phase_ms'],phase_medians_ms={phase: statistics.median(r[phase] for r in after['phase_ms'])
                for phase in after['phase_ms'][0] if phase != 'completed'},
            all_four_samples_under_33_333ms=max(after['stereo_ms']) < 1000/30))
    record = dict(recorded_utc=datetime.now(timezone.utc).isoformat(),
        state='compared_scoped_Quest_FP32_wrapper_optimization_and_wall_phases',
        baseline_apk_sha256=old['apk_sha256'],candidate_apk_sha256=new['apk_sha256'],rows=rows,
        source_sha256={str(Path(__file__).relative_to(ROOT).as_posix()):sha(Path(__file__))},
        candidate_raw_sha256=raw_hashes,unchanged_fixture_lineage=True,
        scope='Four synthetic stereo calls per profile including first call; snapshots excluded; submit_wait is CPU wall time, not GPU timestamps. Baseline has no phase instrumentation. Model/FP32/identity Tile unchanged; wrapper O2 plus optional timing are the candidate changes.',
        real_motion_quality_verified=False,sustained_performance_verified=False,video_XR_verified=False)
    (ROOT/'artifacts/rvm-phase-performance-comparison.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,indent=2))

if __name__ == '__main__': main()
