"""Bind a completed source build to its inputs and exported library bytes."""
import os
from pathlib import Path
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
BUILDER = Path(str(Path(os.environ.get('THRU3D_MPV_WORK', str(Path.home() / '.cache/thru3d-mpv'))) / 'mpv-android/buildscripts'))
RECEIPT = Path(str(Path(os.environ.get('THRU3D_MPV_WORK', str(Path.home() / '.cache/thru3d-mpv'))) / 'source-build-receipt.json'))
LIBS = ['libmpv.so', 'libavcodec.so', 'libavdevice.so', 'libavfilter.so',
        'libavformat.so', 'libavutil.so', 'libswresample.so', 'libswscale.so']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    files = ['third_party/mpv/source-lock.json', 'native/mpv/patches/source-frame-manifest.json',
             'tools/environment/mpv-linux/host-tools.lock.txt']
    result = {name: sha(ROOT/name) for name in files}
    for directory in ['scripts', 'include']:
        for path in (BUILDER/directory).glob('*.sh'):
            result['builder/'+str(path.relative_to(BUILDER))] = sha(path)
    result['builder/buildall.sh'] = sha(BUILDER/'buildall.sh')
    result['ndk/source.properties'] = sha(Path(str(Path(os.environ.get('THRU3D_MPV_WORK', str(Path.home() / '.cache/thru3d-mpv'))) / 'android-ndk-r30/source.properties')))
    return result


def main():
    action = sys.argv[1]
    if action == 'start':
        record = {'state': 'running', 'log': sys.argv[2], 'inputs': inputs(),
                  'meson': subprocess.check_output(['meson', '--version'], text=True).strip(),
                  'ninja': subprocess.check_output(['ninja', '--version'], text=True).strip()}
    elif action == 'finish':
        record = json.loads(RECEIPT.read_text())
        if record['inputs'] != inputs():
            raise ValueError('Build inputs changed during compilation')
        record['state'] = 'passed'
        record['libraries_sha256'] = {name: sha(BUILDER/'prefix/arm64/lib'/name) for name in LIBS}
    elif action == 'fail':
        record = json.loads(RECEIPT.read_text())
        record['state'] = 'failed'
        record['exit_code'] = int(sys.argv[2])
    else:
        raise ValueError('Unknown build receipt action')
    temp = RECEIPT.with_suffix('.json.tmp')
    temp.write_text(json.dumps(record, indent=2)+'\n')
    temp.replace(RECEIPT)
    if action == 'finish':
        (ROOT/'artifacts/mpv-source-build-receipt.json').write_bytes(RECEIPT.read_bytes())


if __name__ == '__main__':
    main()
