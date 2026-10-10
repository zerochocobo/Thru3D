"""Apply and verify the independent PGS client extension, without changing the frame ABI."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_pgs_patch(mpv):
    directory = ROOT/'native/mpv/patches'
    patch = directory/'0003-mpv-pgs-bitmap.patch'
    record = json.loads((directory/'pgs-bitmap-manifest.json').read_text())
    if sha(patch) != record['patch_sha256']:
        raise ValueError('PGS patch hash differs')
    applied = all((mpv/name).exists() and sha(mpv/name) == digest
                  for name, digest in record['patched_files_sha256'].items())
    if not applied:
        if not all(sha(mpv/name) == digest for name, digest in record['base_files_sha256'].items()):
            old_manifest = mpv/'.quest-pgs-manifest.json'
            old_patch = mpv/'.quest-pgs-applied.patch'
            if not old_manifest.exists() or not old_patch.exists():
                raise ValueError('Modified mpv PGS source has no verified previous patch')
            previous = json.loads(old_manifest.read_text())
            if sha(old_patch) != previous['patch_sha256'] or not all(
                (mpv/name).exists() and sha(mpv/name) == digest
                for name, digest in previous['patched_files_sha256'].items()):
                raise ValueError('Previous PGS source bytes differ; refuse to overwrite')
            subprocess.run(['git', 'apply', '--reverse', '--check', str(old_patch)], cwd=mpv, check=True)
            subprocess.run(['git', 'apply', '--reverse', str(old_patch)], cwd=mpv, check=True)
        for name, digest in record['base_files_sha256'].items():
            if sha(mpv/name) != digest:
                raise ValueError(f'PGS source is not the pinned patch base: {name}')
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=mpv, check=True)
        subprocess.run(['git', 'apply', str(patch)], cwd=mpv, check=True)
    for name, digest in record['patched_files_sha256'].items():
        if not (mpv/name).exists() or sha(mpv/name) != digest:
            raise ValueError(f'Patched PGS source bytes differ: {name}')
    (mpv/'.quest-pgs-manifest.json').write_text(json.dumps(record, indent=2)+'\n')
    (mpv/'.quest-pgs-applied.patch').write_bytes(patch.read_bytes())
