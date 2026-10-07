#!/usr/bin/env bash
set -euo pipefail
# Run explicitly in a disposable Debian/Ubuntu build environment with apt privileges.
work=${THRU3D_MPV_WORK:-"$HOME/.cache/thru3d-mpv"}
downloads=${THRU3D_MPV_DOWNLOADS:-"$work/downloads"}
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential autoconf automake libtool pkg-config ninja-build meson cmake unzip curl wget git \
  gperf nasm python3 python3-venv python3-pip python3-jinja2 python3-packaging bison flex gettext ca-certificates
mkdir -p "$work"
python3 -m venv --system-site-packages "$work/host-venv"
"$work/host-venv/bin/python" -m pip install --require-hashes -r "$(dirname "${BASH_SOURCE[0]}")/host-tools.lock.txt"
export PATH="$work/host-venv/bin:$PATH"
printf '%s  %s\n' \
  753611f410d002cfcd3f3dc2ef49aad532089d3180b436c060a90bf0fcb64df2 "$downloads/android-ndk-r30-linux.zip" \
  5ca9265c8824d9afbd5d9c276db950a3b986d1b61972a95657f0d3dd72eddd89 "$downloads/mpv-android-fdf74f6.tar.gz" | sha256sum -c -
if [[ ! -f "$work/android-ndk-r30/source.properties" ]]; then unzip -q "$downloads/android-ndk-r30-linux.zip" -d "$work"; fi
if [[ ! -d "$work/mpv-android" ]]; then
  mkdir "$work/mpv-android"
  tar -xzf "$downloads/mpv-android-fdf74f6.tar.gz" --strip-components=1 -C "$work/mpv-android"
fi
mkdir -p "$work/mpv-android/buildscripts/sdk"
if [[ ! -e "$work/mpv-android/buildscripts/sdk/android-ndk-r30" ]]; then
  ln -s "$work/android-ndk-r30" "$work/mpv-android/buildscripts/sdk/android-ndk-r30"
fi
"$work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang" --version
dpkg-query -W > "$work/host-packages.tsv"
