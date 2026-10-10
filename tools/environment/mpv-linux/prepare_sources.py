"""Validate/extract locked archives onto Linux ext4 and apply the frame patch."""
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_dovi_patch(ffmpeg):
    patch_dir = ROOT / 'native/mpv/patches'
    patch = patch_dir / '0002-ffmpeg-profile5-rpu.patch'
    record = json.loads((patch_dir / 'dovi-rpu-manifest.json').read_text())
    if sha(patch) != record['patch_sha256']:
        raise ValueError('Dolby RPU patch hash differs')
    applied = all((ffmpeg/name).exists() and sha(ffmpeg/name) == digest
                  for name, digest in record['patched_files_sha256'].items())
    if not applied:
        base_matches = all(sha(ffmpeg/name) == digest for name, digest
                           in record['base_files_sha256'].items())
        if not base_matches:
            previous_path = ffmpeg / '.quest-dovi-manifest.json'
            previous_patch = ffmpeg / '.quest-dovi-applied.patch'
            if not previous_path.exists() or not previous_patch.exists():
                raise ValueError('Modified FFmpeg tree has no verified Dolby patch')
            previous = json.loads(previous_path.read_text())
            if (sha(previous_patch) != previous['patch_sha256'] or
                not all((ffmpeg/name).exists() and sha(ffmpeg/name) == digest
                        for name, digest in previous['patched_files_sha256'].items())):
                raise ValueError('Previous Dolby patch/tree bytes differ')
            subprocess.run(['git', 'apply', '--reverse', '--check', str(previous_patch)], cwd=ffmpeg, check=True)
            subprocess.run(['git', 'apply', '--reverse', str(previous_patch)], cwd=ffmpeg, check=True)
        for name, digest in record['base_files_sha256'].items():
            if sha(ffmpeg/name) != digest:
                raise ValueError(f'FFmpeg is not the pinned Dolby patch base: {name}')
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=ffmpeg, check=True)
        subprocess.run(['git', 'apply', str(patch)], cwd=ffmpeg, check=True)
    for name, digest in record['patched_files_sha256'].items():
        if sha(ffmpeg/name) != digest:
            raise ValueError(f'Patched Dolby source bytes differ: {name}')
    (ffmpeg / '.quest-dovi-applied.patch').write_bytes(patch.read_bytes())
    (ffmpeg / '.quest-dovi-manifest.json').write_text(json.dumps(record, indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(os.environ.get('THRU3D_MPV_DOWNLOADS', str(Path.home() / '.cache/thru3d-mpv/downloads'))))
    parser.add_argument("--builder", type=Path, default=Path(str(Path(os.environ.get('THRU3D_MPV_WORK', str(Path.home() / '.cache/thru3d-mpv'))) / 'mpv-android/buildscripts')))
    args = parser.parse_args()
    lock = json.loads((ROOT/"third_party/mpv/source-lock.json").read_text())
    plan = json.loads((ROOT/"third_party/mpv/source-plan.json").read_text())
    if {p["name"] for p in lock["sources"]} != {p["name"] for p in plan["sources"]}:
        raise ValueError("Source resolution incomplete")
    base = (args.builder/"deps").resolve()
    base.mkdir(parents=True, exist_ok=True)
    for record in lock["sources"]:
        source = args.cache/record["archive"]
        if sha(source) != record["sha256"]:
            raise ValueError(f"Source SHA256 mismatch: {record['name']}")
        destination = (base/record["name"]).resolve()
        if not destination.is_relative_to(base):
            raise ValueError("Source path escapes the owned dependency directory")
        marker = destination/".quest-source.json"
        if marker.exists():
            if json.loads(marker.read_text()) != record:
                raise ValueError("Existing source tree belongs to a different locked archive")
            continue
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(source) as archive:
            for member in archive.getmembers():
                parts = PurePosixPath(member.name).parts
                if not parts or ".." in parts or PurePosixPath(member.name).is_absolute():
                    raise ValueError("Source archive path is unsafe")
        subprocess.run(["tar", "-xf", str(source), "--strip-components=1", "-C", str(destination)], check=True)
        marker.write_text(json.dumps(record, indent=2)+"\n")
        print(f"Extracted {record['name']} {record['revision']}", flush=True)
    mpv = base/"mpv"
    patch = ROOT/"native/mpv/patches/0001-quest-source-frame.patch"
    record = json.loads((patch.parent/"source-frame-manifest.json").read_text())
    if sha(patch) != record["patch_sha256"]:
        raise ValueError("Frame patch hash differs")
    already_applied = all(sha(mpv/name) == digest for name,digest in record["patched_files_sha256"].items()
                          if (mpv/name).exists())
    already_applied &= all((mpv/name).exists() for name in record["patched_files_sha256"])
    if not already_applied:
        base_matches = all(sha(mpv/name) == digest for name,digest in record["base_files_sha256"].items())
        if not base_matches:
            previous_path = mpv/".quest-frame-manifest.json"
            previous_patch = mpv/".quest-frame-applied.patch"
            if not previous_path.exists() or not previous_patch.exists():
                raise ValueError("Modified MPV tree has no verified previous frame patch")
            previous = json.loads(previous_path.read_text())
            if (sha(previous_patch) != previous["patch_sha256"] or
                not all((mpv/name).exists() and sha(mpv/name) == digest
                        for name,digest in previous["patched_files_sha256"].items())):
                raise ValueError("Previous MPV patch/tree bytes differ; refuse to overwrite")
            subprocess.run(["git", "apply", "--reverse", "--check", str(previous_patch)], cwd=mpv, check=True)
            subprocess.run(["git", "apply", "--reverse", str(previous_patch)], cwd=mpv, check=True)
        for name,digest in record["base_files_sha256"].items():
            if sha(mpv/name) != digest:
                raise ValueError(f"MPV source is not the pinned patch base: {name}")
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=mpv, check=True)
        subprocess.run(["git", "apply", str(patch)], cwd=mpv, check=True)
    for name,digest in record["patched_files_sha256"].items():
        if sha(mpv/name) != digest:
            raise ValueError(f"Patched source bytes differ: {name}")
    (mpv/".quest-frame-applied.patch").write_bytes(patch.read_bytes())
    (mpv/".quest-frame-manifest.json").write_text(json.dumps(record, indent=2)+"\n")
    apply_dovi_patch(base/'ffmpeg')
    from pgs_patch import apply_pgs_patch
    apply_pgs_patch(mpv)
    print("Locked sources, same-render frame patch and Profile 5 RPU patch verified")


if __name__ == "__main__":
    main()
