"""Same-executable Quest Vulkan comparison of a separate ratio=1 model branch."""
import os
from pathlib import Path
import argparse
import copy
from datetime import datetime
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tarfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'benchmarks'))
from ncnn_performance.device import ADB, SERIAL, adb, require, sha, write
from ncnn_timestamp.device import validate

ORDER = [('baseline_before', 'baseline'), ('candidate_forward', 'candidate'),
         ('candidate_reverse', 'candidate'), ('baseline_after', 'baseline')]

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def audit(directory):
    receipt = read(directory / 'receipt.json')
    require(receipt['serial'] == SERIAL and len(receipt['cases']) == 4, 'Incomplete target/cases')
    actual = {line.split()[1]: line.split()[0] for line in (directory / 'device-files.sha256').read_text().splitlines()}
    require(actual == receipt['device_files'], 'Device payload bytes differ')
    require(sha(directory / 'rvm_timestamp') == actual['rvm_timestamp'], 'Changed executed ELF')
    require(sha(directory / 'acquisition-script.py') == receipt['acquisition_sha256'], 'Changed acquisition recipe')
    results = []
    for label, variant in ORDER:
        record = next(row for row in receipt['cases'] if row['label'] == label)
        require(record['variant'] == variant and record['returncode'] == 0, 'Wrong/failed executed case')
        require(sha(directory / (label + '.json')) == record['stdout_sha256'] and
                sha(directory / (label + '.stderr.log')) == record['stderr_sha256'], 'Changed device output')
        spec = read(directory / (variant + '-profile.json'))
        require(sha(directory / (variant + '-profile.json')) == receipt['profiles'][variant], 'Changed model specification')
        require(actual[variant + '/rvm.ncnn.param'] == spec['ncnn_param_sha256'] and
                actual[variant + '/rvm.ncnn.bin'] == spec['ncnn_bin_sha256'], 'Wrong model lineage')
        fixture = read(directory / (variant + '-fixtures.json'))
        require(sha(directory / (variant + '-fixtures.json')) == receipt['fixtures'][variant], 'Changed independent oracle')
        require(fixture['reference_backend'] == 'ONNX Runtime CPUExecutionProvider', 'Not independent ONNX oracle')
        for name, item in fixture['files'].items():
            require(actual[variant + '/' + name] == item['sha256'], 'Changed ONNX fixture')
        report = read(directory / (label + '.json'))
        validate(report, spec)
        rejected = []
        for field, value in [('cpu_layers', 1), ('gpu_elapsed_ms', 1e6), ('gpu_segments', []), ('total_ms', float('nan'))]:
            bad = copy.deepcopy(report)
            bad['calls'][9][field] = value
            try:
                validate(bad, spec)
            except (ValueError, KeyError):
                rejected.append(field)
            else:
                raise ValueError('Corrupted GPU evidence accepted: ' + field)
        measured = report['calls'][8:]
        stats = {name: dict(p50=statistics.median(row[name] for row in measured),
                           p95=sorted(row[name] for row in measured)[113], maximum=max(row[name] for row in measured))
                 for name in ['total_ms', 'gpu_elapsed_ms', 'submit_wall_ms', 'submissions', 'gpu_layers', 'pipelines']}
        results.append(dict(label=label, variant=variant, stats=stats, alpha_max_abs=report['validation']['alpha_max_abs'],
                            rejected=rejected, cpu_fallback_layers=0))
    result = dict(state='passed_separate_ratio_one_Quest_GPU_numerics_and_timing', cases=results,
        measured_stereo_calls=480, warmup_per_case=8, actual_GPU_timestamp_verified=True,
        production_enabled=False, video_fps_verified=False, quality_verified=False,
        scope='Same diagnostic executable, FP32, 512x512 and full independent eye recurrence; each model against its own ONNX branch oracle')
    write(directory / 'verification.json', result)
    print(json.dumps(result), flush=True)

def run():
    output = ROOT / 'artifacts/rvm-ratio-one/device' / (datetime.now().strftime('%Y%m%d_%H%M%S') + '_' + uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    remote = '/data/local/tmp/quest_ratio_one_' + uuid.uuid4().hex
    build = read(ROOT / 'artifacts/ncnn-timestamp/build-verified.json')
    elf = ROOT / 'build/ncnn-timestamp-android/rvm_timestamp'
    require(sha(elf) == build['elf_sha256'], 'Changed instrumented executable')
    shutil.copy2(elf, output / 'rvm_timestamp')
    shutil.copy2(__file__, output / 'acquisition-script.py')
    runtime = Path(str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so'))
    files = {'rvm_timestamp': elf, 'libc++_shared.so': runtime}
    receipt = dict(serial=SERIAL, remote=remote, acquisition_sha256=sha(__file__), cases=[], profiles={}, fixtures={})
    for variant, model, fixtures in [('baseline', ROOT / 'build/rvm/512x512', ROOT / 'build/rvm-resident-fixtures/512x512'),
                                     ('candidate', ROOT / 'build/rvm-ratio-one/512x512', ROOT / 'build/rvm-ratio-one/fixtures/512x512')]:
        spec = read(model / 'profile.json')
        require(spec['input_shapes']['src'] == [1, 3, 512, 512] and spec['downsample_ratio'] == 1, 'Wrong static profile')
        for filename, key in [('rvm.ncnn.param', 'ncnn_param_sha256'), ('rvm.ncnn.bin', 'ncnn_bin_sha256')]:
            require(sha(model / filename) == spec[key], 'Changed model bytes')
            files[variant + '/' + filename] = model / filename
        fm = read(fixtures / 'manifest.json')
        require(sha(model / 'rvm.fixed.onnx') == fm['fixed_onnx_sha256'], 'Wrong reference model')
        for filename, entry in fm['files'].items():
            require(sha(fixtures / filename) == entry['sha256'], 'Changed source/oracle bytes')
            files[variant + '/' + filename] = fixtures / filename
        for kind, file in [('profile', model / 'profile.json'), ('fixtures', fixtures / 'manifest.json')]:
            shutil.copy2(file, output / (variant + '-' + kind + '.json'))
            receipt['profiles' if kind == 'profile' else 'fixtures'][variant] = sha(file)
    receipt['device_files'] = {name: sha(path) for name, path in files.items()}
    write(output / 'receipt.json', receipt)
    with tarfile.open(output / 'payload.tar', 'w') as tar:
        for name, path in files.items():
            tar.add(path, arcname=name)
    try:
        adb('shell', 'mkdir', '-p', remote)
        adb('push', str(output / 'payload.tar'), remote + '/payload.tar')
        adb('shell', f'tar -xf {remote}/payload.tar -C {remote} && chmod 700 {remote}/rvm_timestamp')
        raw = adb('shell', f'cd {remote} && sha256sum ' + ' '.join(files)).stdout
        (output / 'device-files.sha256').write_bytes(raw)
        require({line.split()[1]: line.split()[0] for line in raw.decode().splitlines()} == receipt['device_files'], 'Device payload hash mismatch')
        for label, variant in ORDER:
            (output / (label + '.battery-before.txt')).write_bytes(adb('shell', 'dumpsys', 'battery').stdout)
            command = f'LD_LIBRARY_PATH={remote} {remote}/rvm_timestamp {remote}/{variant}/rvm.ncnn.param {remote}/{variant}/rvm.ncnn.bin {remote}/{variant} 512x512'
            result = subprocess.run([ADB, '-s', SERIAL, 'shell', command], capture_output=True, timeout=180)
            stdout = output / (label + '.json')
            stderr = output / (label + '.stderr.log')
            stdout.write_bytes(result.stdout)
            stderr.write_bytes(result.stderr)
            receipt['cases'].append(dict(label=label, variant=variant, returncode=result.returncode,
                stdout_sha256=sha(stdout), stderr_sha256=sha(stderr)))
            write(output / 'receipt.json', receipt)
            require(result.returncode == 0, 'GPU candidate case failed: ' + label + '; ' + str(output))
            validate(read(stdout), read(output / (variant + '-profile.json')))
            (output / (label + '.battery-after.txt')).write_bytes(adb('shell', 'dumpsys', 'battery').stdout)
            print(json.dumps(dict(label=label, state='collected', trace=str(output))), flush=True)
        audit(output)
    finally:
        adb('shell', 'rm', '-rf', remote)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        audit(args.verify)
    else:
        run()
