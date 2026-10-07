"""Independent audit of the diagnostic FP16-storage/FP32-arithmetic candidate.

R04_STORAGE_V1 is an early precision screen, not a video quality/FPS gate.
Original FP32 numerical limits are retained in verify.py.
"""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'benchmarks'))
from rvm_standalone_device import PROFILES, lineage

LIMITS = dict(alpha_max_abs=.005, recurrent_max_abs=.05, alpha_max_rms=.001,
              recurrent_max_rms=.005, reset_rollback_max_abs=1e-6,
              isolation_max_abs=.005, rejected_state_max_abs=0)


def read(p): return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p, d): Path(p).write_text(json.dumps(d, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
def require(condition, message):
    if not condition: raise ValueError(message)


def validate_half(report, profile, require_passed=True):
    require(report['state'] in ('passed','failed') and report['state_storage'] == 'VkMat_FP16', 'Half numerical/layout gate failed')
    require(report['precision'] == 'fp16_storage_fp32_arithmetic' and report['numeric_policy'] == 'R04_STORAGE_V1', 'Unexpected precision/policy')
    for k in ('alpha_max_abs','recurrent_max_abs','alpha_max_rms','recurrent_max_rms'):
        require(report[k+'_limit'] == LIMITS[k], 'Changed predeclared precision bound')
    require(report['gpu_state_scalar_bytes'] == 2 and report['host_io_scalar_bytes'] == 4 and
            report['finite_flags_scalar_bytes'] == 4 and report['fp16_arithmetic'] is False and
            report['fp16_storage_supported'] is True, 'Wrong actual storage, arithmetic, or capability')
    for k in LIMITS:
        require(type(report[k]) in (float,int) and math.isfinite(report[k]) and report[k] >= 0, 'Invalid numeric error: '+k)
    passed = all(report[k] <= bound for k,bound in LIMITS.items())
    require(report['state'] == ('passed' if passed else 'failed'), 'Native numeric label differs from independent audit')
    if require_passed: require(passed, 'Predeclared precision bounds exceeded')
    w, h = profile['input_shapes']['src'][-1], profile['input_shapes']['src'][-2]
    state_bytes = sum(s[1]*s[2]*s[3]*4 for k,s in profile['output_shapes'].items() if k.startswith('r'))
    expected = dict(committed_stereo_frames=6, rgb_upload_bytes=6*2*w*h*3*4,
        initial_state_upload_bytes=5*state_bytes, alpha_download_bytes=6*2*w*h*4,
        diagnostic_state_download_bytes=14*state_bytes, validation_upload_bytes=192,
        validation_download_bytes=192, production_explicit_recurrent_download_bytes=0)
    for k,v in expected.items(): require(type(report[k]) is int and report[k] == v, 'Logical transfer/commit count: '+k)
    for k in ('invalid_right_rejected','nonfinite_right_rejected','gpu_finite_guard_verified','identity_tile_contract_verified'):
        require(report[k] is True, 'Missing guard: '+k)
    require(report['non_vulkan_layers'] == [] and report['vulkan_capable_layers'] == report['layer_count'] > 0, 'CPU partition or missing model')
    require(len(report['stereo_ms']) == len(report['phase_ms']) == 4, 'Missing four actual calls')
    names = {'input_validation','setup','command_record','submit_wait','output_validation','commit','teardown'}
    for outer, row in zip(report['stereo_ms'], report['phase_ms']):
        require(type(outer) in (float,int) and math.isfinite(outer) and outer > 0, 'Invalid outer time')
        require(set(row) == names | {'total','completed'} and row['completed'] is True, 'Incomplete timing')
        require(all(type(row[k]) in (float,int) and math.isfinite(row[k]) and row[k] >= 0 for k in names | {'total'}), 'Invalid phase')
        require(abs(sum(row[k] for k in names)-row['total']) <= 1e-6*max(1,row['total']) and
                abs(row['total']-outer) <= 1e-3*max(1,outer), 'Timing sum/coverage mismatch')
    return passed


def negatives(report, profile):
    changes = dict(state='failed' if report['state'] == 'passed' else 'passed', state_storage='VkMat_FP32', precision='fp32', numeric_policy='R01_FP32',
        gpu_state_scalar_bytes=4, finite_flags_scalar_bytes=2, fp16_arithmetic=True,
        fp16_storage_supported=False, alpha_max_abs=float('nan'), recurrent_max_rms=.5,
        alpha_max_abs_limit=.05, rejected_state_max_abs=1e-7, reset_rollback_max_abs=.01,
        invalid_right_rejected=False, gpu_finite_guard_verified=False, identity_tile_contract_verified=False,
        committed_stereo_frames=7, validation_download_bytes=0, production_explicit_recurrent_download_bytes=1,
        non_vulkan_layers=['Tile:expand_146'], phase_ms=[])
    if report['state'] == 'failed':
        # These are valid numeric failures when the label is already failed.
        # Keep structural corruption checks independent of the numeric gate.
        for k in ('recurrent_max_rms','rejected_state_max_abs','reset_rollback_max_abs'):
            changes.pop(k)
    rejected = []
    for k,v in changes.items():
        bad = copy.deepcopy(report); bad[k] = v
        try: validate_half(bad, profile, require_passed=False)
        except (ValueError,KeyError): rejected.append(k)
        else: raise ValueError('Polluted candidate accepted: '+k)
    return rejected


def host(args):
    output = ROOT/'artifacts/rvm-half-storage-host'/(datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    executable = ROOT/'build/rvm-resident-host/Release/rvm_resident_oracle.exe'
    executable_hash = sha(executable)
    sources = {p.relative_to(ROOT).as_posix():sha(p) for p in (ROOT/'native/rvm').glob('*') if p.suffix in ('.cpp','.h')}
    reports = []
    for key in PROFILES:
        manifest, profile = lineage(key)
        folder = ROOT/'build/rvm'/key
        for filename, field in (('rvm.ncnn.param','ncnn_param_sha256'),('rvm.ncnn.bin','ncnn_bin_sha256')):
            require(sha(folder/filename) == profile[field], 'Changed model weights')
        run = subprocess.run([str(executable), str(folder/'rvm.ncnn.param'), str(folder/'rvm.ncnn.bin'),
            str(ROOT/'build/rvm-resident-fixtures'/key), key, '--half-storage'], capture_output=True, text=True, timeout=120)
        write(output/(key+'.reference.json'), manifest)
        (output/(key+'.json')).write_text(run.stdout, encoding='utf-8')
        (output/(key+'.stderr.log')).write_text(run.stderr, encoding='utf-8')
        require(run.returncode in (0,1), 'Half storage host execution failed: '+key+'; '+str(output))
        report = json.loads(run.stdout)
        require(report['profile'] == key, 'Wrong profile')
        passed = validate_half(report, profile, require_passed=False)
        require((run.returncode == 0) == passed, 'Exit status disagrees with numeric audit')
        reports.append(dict(profile=key, report=report, polluted_reports_rejected=negatives(report,profile),
            oracle_report_sha256=sha(output/(key+'.json')), reference_manifest_sha256=sha(ROOT/'build/rvm-resident-fixtures'/key/'manifest.json')))
        print(json.dumps(dict(profile=key, alpha_max_abs=report['alpha_max_abs'], recurrent_max_abs=report['recurrent_max_abs'],
            median_ms=statistics.median(report['stereo_ms']))), flush=True)
    require(executable_hash == sha(executable) and all(sha(ROOT/p) == h for p,h in sources.items()), 'Candidate source/binary changed')
    passed = all(r['report']['state'] == 'passed' for r in reports)
    record = dict(state='passed_scoped_storage_precision_screen' if passed else 'failed_precision_bounds', numeric_policy='R04_STORAGE_V1',
        source_sha256=sources, executable_sha256=executable_hash, profiles=reports,
        verifier_sha256=sha(Path(__file__)), android_execution_verified=False, quality_verified=False,
        sustained_fps_verified=False, scope='Windows NVIDIA Vulkan four-frame synthetic full-state candidate only')
    write(output/'verification.json', record)
    write(ROOT/'artifacts/rvm-half-storage-host-verification.json', record)
    print(str(output/'verification.json'))
    require(passed, 'Storage precision screen failed; preserve all profiles and bounds')


def device(args):
    directory = args.directory
    result = read(directory/'result.json')
    require(result['state'] == 'collected_scoped_rvm_trace' and result['activity_launched'] is False and
        result['apk_sha256'] == result['installed_sha256'], 'Uncollected or wrong candidate')
    require(result['apk_sha256'] == sha(ROOT/'artifacts/quest3-player-debug.apk'), 'Current APK differs')
    require(read(directory/'build_manifest.json')['apk_sha256'] == result['apk_sha256'], 'Build lineage mismatch')
    cases, ids = [], set()
    for key in PROFILES:
        manifest, profile = lineage(key)
        case = 'resident_fp16_storage_'+key
        receipt = read(directory/(case+'-receipt.json'))
        report = read(directory/(case+'-report.json'))
        identity = (receipt['diagnostic_process'], receipt['id'])
        require(identity not in ids and receipt['state'] == 'accepted' and receipt['action'].endswith('.DEBUG_RVM_STANDALONE'), 'Duplicate/missing receipt')
        ids.add(identity)
        require((report['diagnostic_process'],report['probe_id']) == identity and report['mode'] == 'resident_fp16_storage' and
            report['requested_profile'] == report['profile'] == key and report['standalone'] is True and
            report['activity_launched'] is False, 'Wrong runtime identity/scope')
        hashes = {}
        for line in (directory/(key+'-device-fixtures.sha256')).read_text(encoding='utf-8-sig').splitlines():
            digest, path = line.split(None,1); hashes[Path(path.strip()).name] = digest
        require(hashes == {n:r['sha256'] for n,r in manifest['files'].items()}, 'Actual device fixture bytes changed')
        passed = validate_half(report, profile, require_passed=False)
        cases.append(dict(profile=key, report=report, polluted_reports_rejected=negatives(report,profile),
            report_sha256=sha(directory/(case+'-report.json')), reference_manifest_sha256=sha(ROOT/'build/rvm-resident-fixtures'/key/'manifest.json')))
    passed = all(c['report']['state'] == 'passed' for c in cases)
    record = dict(state='passed_scoped_storage_precision_screen' if passed else 'failed_precision_bounds', apk_sha256=result['apk_sha256'],
        numeric_policy='R04_STORAGE_V1', profiles=cases, verifier_sha256=sha(Path(__file__)),
        quality_verified=False, XR_verified=False, sustained_fps_verified=False,
        scope='Quest Adreno Vulkan full-state four-frame synthetic diagnostic candidate; production remains FP32')
    write(directory/'half-storage-verified.json', record)
    print(json.dumps(dict(state=record['state'], apk_sha256=result['apk_sha256'], cases=len(cases),
        alpha_max_abs=max(c['report']['alpha_max_abs'] for c in cases), recurrent_max_abs=max(c['report']['recurrent_max_abs'] for c in cases))))
    require(passed, 'Quest storage precision screen failed; preserve all profiles and bounds')


def audit_host(args):
    record = read(args.directory/'verification.json')
    require(record['executable_sha256'] == sha(ROOT/'build/rvm-resident-host/Release/rvm_resident_oracle.exe'), 'Changed host executable')
    require(all(sha(ROOT/p) == h for p,h in record['source_sha256'].items()), 'Changed native source')
    for case in record['profiles']:
        key = case['profile']; _, profile = lineage(key)
        raw = args.directory/(key+'.json')
        require(case['oracle_report_sha256'] == sha(raw), 'Changed host raw evidence')
        report = read(raw)
        require(report == case['report'], 'Report differs from raw evidence')
        validate_half(report, profile, require_passed=False)
        case['polluted_reports_rejected'] = negatives(report, profile)
    record['verifier_sha256'] = sha(Path(__file__))
    record['host_timing_performance_comparison_valid'] = False
    record['host_timing_scope'] = 'Numerical validation only; host FP32 and FP16 jobs overlapped, no host speed comparison'
    write(args.directory/'verification-final.json', record)
    write(ROOT/'artifacts/rvm-half-storage-host-verification.json', record)
    print(record['state'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='operation', required=True)
    sub.add_parser('host')
    verify = sub.add_parser('verify'); verify.add_argument('directory', type=Path)
    audit = sub.add_parser('audit-host'); audit.add_argument('directory', type=Path)
    args = parser.parse_args()
    {'host':host, 'verify':device, 'audit-host':audit_host}[args.operation](args)
