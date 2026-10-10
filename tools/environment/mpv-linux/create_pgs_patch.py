"""Generate an independent PGS client patch against the locked mpv archive."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[3]
ARCHIVE = Path(str(Path(os.environ.get('THRU3D_MPV_DOWNLOADS', str(Path.home() / '.cache/thru3d-mpv/downloads'))) / 'mpv-0b7ed67.tar.gz'))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    lock = json.loads((ROOT/'third_party/mpv/source-lock.json').read_text())
    expected = next(p['sha256'] for p in lock['sources'] if p['name'] == 'mpv')
    if sha(ARCHIVE.read_bytes()) != expected:
        raise ValueError('PGS archive differs from locked mpv')
    with tarfile.open(ARCHIVE) as archive:
        member = next(p for p in archive.getnames() if p.endswith('/player/client.c'))
        original = archive.extractfile(member).read().decode()
    anchor = '#include "client.h"\n'
    if original.count(anchor) != 1:
        raise ValueError('PGS client include anchor changed')
    edited = original.replace(anchor, anchor + '#include "sub/dec_sub.h"\n'
                              '#include "mpv/quest_subtitle.h"\n', 1)
    edited += '\n' + (ROOT/'native/mpv/pgs/quest_pgs_client.c.inc').read_text()
    header = (ROOT/'native/mpv/include/mpv/quest_subtitle.h').read_text()
    patch = ''.join(difflib.unified_diff(original.splitlines(True), edited.splitlines(True),
                                      fromfile='a/player/client.c', tofile='b/player/client.c'))
    patch += ''.join(difflib.unified_diff([], header.splitlines(True), fromfile='/dev/null',
                                       tofile='b/include/mpv/quest_subtitle.h'))
    directory = ROOT/'native/mpv/patches'
    (directory/'0003-mpv-pgs-bitmap.patch').write_text(patch, newline='\n')
    manifest = {'api_version': 1, 'base_archive_sha256': expected,
                'base_files_sha256': {'player/client.c': sha(original.encode())},
                'patched_files_sha256': {'player/client.c': sha(edited.encode()),
                                        'include/mpv/quest_subtitle.h': sha(header.encode())},
                'patch_sha256': sha(patch.encode()), 'private_header_sha256': sha(header.encode())}
    (directory/'pgs-bitmap-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('Independent PGS bitmap patch generated')


if __name__ == '__main__':
    main()
