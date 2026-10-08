"""Check tracked public files for excluded assets, private paths and credentials."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

FORBIDDEN_PARTS = {'.git', '.cache', '.venv', '.godot', '.gradle', '.cxx', '__pycache__', 'prompt', 'artifacts'}
FORBIDDEN_SUFFIXES = {'.onnx', '.mnn', '.pt', '.pth', '.ckpt', '.safetensors', '.bin', '.param', '.apk', '.aar', '.so', '.keystore', '.jks', '.p12', '.pfx', '.hdr', '.log'}
# MIT-licensed glTF mesh buffers, not inference weights. Only these exact bytes qualify.
HAND_BUFFER_PINS = {
    'app/godot/models/hands/LeftHandHumanoid.bin': '05f96e5aae870c8f2fde8a1fea337b060c7fde3e659b124a5ed979f0ffa1222a',
    'app/godot/models/hands/RightHandHumanoid.bin': '89468a6868afbd6a9d5e545e7fdd5dadd7d7abab6d4389d8acc14a7804901e41',
}
PATTERNS = {
    'private machine path': re.compile(r'(?i)(?:[CG]:[/\\]+(?:Users[/\\]+dennis|devtools|GIT|code[/\\]+VRPassthroughPlayer)|/mnt/' + r'g/|/opt/' + r'quest-mpv)'),
    'GitHub credential': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'private signing key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'private handover link': re.compile(r'(?i)(?:HANDOVER_\d{8}|docs/(?:store|archive|branding)/)'),
}


def check_files(files):
    errors = []
    for name, data in files.items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
            errors.append(f'{name}: unsafe path')
        approved_mesh = name in HAND_BUFFER_PINS
        if approved_mesh and (len(data) != 38584 or hashlib.sha256(data).hexdigest() != HAND_BUFFER_PINS[name]):
            errors.append(f'{name}: hand mesh differs from reviewed MIT asset')
        if FORBIDDEN_PARTS.intersection(path.parts) or (path.suffix.lower() in FORBIDDEN_SUFFIXES and not approved_mesh):
            errors.append(f'{name}: excluded directory or binary asset')
        if name.startswith(tuple('docs/' + item + '/' for item in ('store', 'branding', 'archive'))) or name.startswith('tools/record_'):
            errors.append(f'{name}: private development or promotion content')
        if name.endswith('store_capture_debug.gd') or 'local.properties' == path.name:
            errors.append(f'{name}: local-only configuration/tool')
        if len(data) > 25 * 1024 * 1024:
            errors.append(f'{name}: unexpected file over 25 MiB')
        try:
            value = data.decode('utf-8')
        except UnicodeDecodeError:
            if path.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.webp', '.mp4', '.jar'} and not approved_mesh:
                errors.append(f'{name}: unreviewed binary type')
            continue
        for label, pattern in PATTERNS.items():
            if pattern.search(value):
                errors.append(f'{name}: {label}')  # Never print the matched credential.
    if HAND_BUFFER_PINS.keys() & files.keys():
        for name in ('LICENSE.txt', 'NOTICE.txt', 'hand.png', 'LeftHandHumanoid.gltf', 'RightHandHumanoid.gltf'):
            asset = 'app/godot/models/hands/' + name
            if asset not in files:
                errors.append(f'{asset}: hand mesh dependency/notice missing')
        for buffer in HAND_BUFFER_PINS:
            gltf = str(PurePosixPath(buffer).with_suffix('.gltf'))
            if gltf in files:
                try:
                    declared = json.loads(files[gltf])['buffers']
                    if declared != [{'byteLength': 38584, 'uri': PurePosixPath(buffer).name}]:
                        errors.append(f'{gltf}: unexpected hand buffer reference')
                except (ValueError, KeyError, TypeError):
                    errors.append(f'{gltf}: invalid hand buffer contract')
    required = {'LICENSE', 'README.md', 'docs/BUILD.md', 'docs/MODELS.md', 'docs/LICENSING.md',
                'app/godot/project.godot', 'android/player-plugin/build.gradle', 'native/mpv/CMakeLists.txt'}
    errors.extend(f'{name}: required public file missing' for name in sorted(required - files.keys()))
    if 'LICENSE' in files and b'Version 3, 29 June 2007' not in files['LICENSE']:
        errors.append('LICENSE: expected complete GPL v3 text')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    names = subprocess.check_output(['git', '-c', f'safe.directory={root.as_posix()}', '-C', str(root),
                                     'ls-files', '-z'], text=True).split('\0')
    files = {}
    for name in filter(None, names):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f'{name}: tracked file is missing or redirected')
        files[name] = path.read_bytes()
    errors = check_files(files)
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Public source boundary checks passed: {len(files)} tracked files')


if __name__ == '__main__':
    main()
