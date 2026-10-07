#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=${THRU3D_MPV_WORK:-"$HOME/.cache/thru3d-mpv"}
builder="$work/mpv-android/buildscripts"
mkdir -p "$work/tmp" "$repo/artifacts/logs"
export TMPDIR="$work/tmp"
export PATH="$work/host-venv/bin:$PATH"
export cores=${QUEST_MPV_CORES:-8}
[[ "$cores" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid compile job count' >&2; exit 2; }

# The live flock, rather than a stale status file, prevents overlapping builds.
exec 9>"$work/build-source.lock"
flock -n 9 || { echo 'A source build already owns this environment' >&2; exit 3; }
python3 "$repo/tools/environment/mpv-linux/prepare_sources.py"

log="$repo/artifacts/logs/mpv-source-build-$(date -u +%Y%m%dT%H%M%SZ).log"
options=(--arch arm64)
if [[ "${1:-}" == '--mpv-only' ]]; then
    options+=(-n)
elif [[ $# != 0 ]]; then
    echo 'Only --mpv-only is accepted (uses already built dependencies)' >&2
    exit 2
fi
python3 "$repo/tools/environment/mpv-linux/build_receipt.py" start "$log"
printf 'ARM64 source build; jobs=%s; log=%s\n' "$cores" "$log"
cd "$builder"
set +e
./buildall.sh "${options[@]}" mpv >"$log" 2>&1
status=$?
set -e
printf '\nQUEST_BUILD_EXIT_CODE=%s\n' "$status" >>"$log"
printf 'Source build exited %s; log=%s\n' "$status" "$log"
if [[ "$status" != 0 ]]; then
    python3 "$repo/tools/environment/mpv-linux/build_receipt.py" fail "$status"
    tail -n 60 "$log"
    exit "$status"
fi
python3 "$repo/tools/environment/mpv-linux/build_receipt.py" finish
printf 'Library outputs:\n'
find "$builder/prefix/arm64/lib" -maxdepth 1 -name '*.so*' -printf '%f -> %l\n'
