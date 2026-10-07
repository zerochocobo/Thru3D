"""Validate the source-built ARM64 libraries before exporting a Debug candidate."""
import os
from pathlib import Path
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from build_receipt import inputs

ROOT = Path(__file__).resolve().parents[3]
WORK = Path(str(Path(os.environ.get('THRU3D_MPV_WORK', str(Path.home() / '.cache/thru3d-mpv')))))
BUILDER = WORK/'mpv-android/buildscripts'
TOOLCHAIN = WORK/'android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin'
DEST = Path(os.environ.get('THRU3D_MPV_EXPORT', str(ROOT / 'artifacts/mpv-source/arm64-v8a')))
LIBS = ['libmpv.so', 'libavcodec.so', 'libavdevice.so', 'libavfilter.so',
        'libavformat.so', 'libavutil.so', 'libswresample.so', 'libswscale.so']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(path):
    result = subprocess.check_output([str(TOOLCHAIN/'llvm-readelf'), '-h', '-lW', '-d', str(path)], text=True)
    if not re.search(r'Machine:\s+AArch64', result):
        raise ValueError(f'Not AArch64: {path}')
    loads = [line.split()[-1] for line in result.splitlines() if line.strip().startswith('LOAD ')]
    if not loads or any(int(value, 16) < 16384 for value in loads):
        raise ValueError(f'Not 16 KiB ELF aligned: {path}')
    needed = re.findall(r'\(NEEDED\).*\[([^]]+)\]', result)
    return result, needed


def main():
    # This repeats the source/patch checks; a successful old build cannot validate
    # a modified source tree. The current build must have compiled that tree.
    subprocess.run(['python3', str(ROOT/'tools/environment/mpv-linux/prepare_sources.py')], check=True)
    patch_manifest = json.loads((ROOT/'native/mpv/patches/source-frame-manifest.json').read_text())
    receipt_path = WORK/'source-build-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    if receipt['state'] != 'passed' or receipt['inputs'] != inputs():
        raise ValueError('No completed build for these exact inputs')
    exports = subprocess.check_output([str(TOOLCHAIN/'llvm-nm'), '-D', '--defined-only',
                                      str(BUILDER/'prefix/arm64/lib/libmpv.so')], text=True)
    if not re.search(r'\bT\s+mpv_quest_source_frame_api_version(?:@@?[^\s]+)?\s*$', exports, re.M):
        raise ValueError('Source-frame extension handshake is absent from libmpv')
    destination_base = DEST.parent
    destination_base.mkdir(parents=True, exist_ok=True)
    records = []
    system_stubs = TOOLCHAIN.parent/'sysroot/usr/lib/aarch64-linux-android/23'
    for name in LIBS:
        source = BUILDER/'prefix/arm64/lib'/name
        if receipt['libraries_sha256'][name] != sha(source):
            raise ValueError(f'Library differs from the completed source build: {name}')
        elf, needed = inspect(source)
        unknown = {dep for dep in needed if dep not in LIBS and dep != 'libc++_shared.so'
                   and not (system_stubs/dep).is_file()}
        if unknown:
            raise ValueError(f'Unresolved shared dependencies of {name}: {unknown}')
        temporary = destination_base/(name+'.export')
        shutil.copyfile(source, temporary)
        subprocess.run([str(TOOLCHAIN/'llvm-strip'), '--strip-unneeded', str(temporary)], check=True)
        inspect(temporary)
        DEST.mkdir(parents=True, exist_ok=True)
        target = DEST/name
        temporary.replace(target)
        records.append({'name': name, 'sha256': sha(target), 'bytes': target.stat().st_size,
                        'built_sha256': sha(source), 'needed': needed})
        (destination_base/(name+'.readelf.txt')).write_text(elf)
    host_packages = WORK/'host-packages.tsv'
    shutil.copyfile(host_packages, destination_base/'host-packages.tsv')
    scripts = {str(p.relative_to(BUILDER)): sha(p) for directory in ['scripts', 'include']
               for p in (BUILDER/directory).glob('*.sh')}
    scripts['buildall.sh'] = sha(BUILDER/'buildall.sh')
    manifest = {
        'schema_version': 1, 'candidate': 'source-frame',
        'state': 'compiled_and_exported; device_validation_pending',
        'source_lock_sha256': sha(ROOT/'third_party/mpv/source-lock.json'),
        'builder_revision': 'fdf74f6830c47dbaa8a22ac79726e8303f1db5af',
        'mpv_revision': patch_manifest['base_mpv_revision'],
        'patch_sha256': patch_manifest['patch_sha256'],
        'private_header_sha256': patch_manifest['private_header_sha256'],
        'api_version': 1, 'ndk': '30.0.16248370', 'android_api': 23,
        'architecture': 'arm64-v8a', 'elf_page_alignment': 16384,
        'build_command': 'buildall.sh --arch arm64 mpv',
        'build_scripts_sha256': scripts, 'packaged_libraries': LIBS,
        'libraries': records, 'export_directory': str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'mpv/source-frame/arm64-v8a'),
        'host_packages_sha256': sha(host_packages),
        'build_receipt_sha256': sha(receipt_path), 'meson': receipt['meson'], 'ninja': receipt['ninja'],
        'cxx_runtime_policy': 'Use the existing Godot/project libc++_shared; do not package a duplicate; device compatibility pending',
        'license_profile': 'Upstream default GPL MPV and FFmpeg gpl/version3; Debug candidate only',
        'reproducibility': 'Exact sources/options/toolchain recorded; independent second-build byte comparison pending',
    }
    target_manifest = ROOT/'third_party/mpv/source-build.json'
    temporary = target_manifest.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(manifest, indent=2)+'\n')
    temporary.replace(target_manifest)
    print('Source-frame Debug candidate exported; ARM64/16 KiB/dependency closure/handshake checked')


if __name__ == '__main__':
    main()
