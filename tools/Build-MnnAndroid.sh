#!/usr/bin/env bash
set -euo pipefail
tool_root=${THRU3D_TOOL_ROOT:-"$HOME/.cache/thru3d-toolchain"}
sdk="$tool_root/android-sdk"
ndk="$sdk/ndk/29.0.14206865"
c="$sdk/cmake/3.31.6/bin"
pristine="$tool_root/mnn/source-3.6.1"
source="$tool_root/mnn/source-3.6.1-vrpp"
build="$tool_root/mnn/build-android-arm64-lib-vrpp"
install="$tool_root/mnn/install-3.6.1-vrpp-android-arm64"
"${PYTHON:-python}" "$(dirname "$0")/mnn/patch_mnn_vrpp.py" "$pristine" "$source"
"$c/cmake.exe" -S "$source" -B "$build" -G Ninja -DCMAKE_MAKE_PROGRAM="$c/ninja.exe" -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$install" -DMNN_BUILD_SHARED_LIBS=OFF -DMNN_SEP_BUILD=OFF -DMNN_OPENCL=ON -DMNN_VULKAN=OFF \
  -DMNN_ARM82=ON -DMNN_USE_LOGCAT=ON -DMNN_BUILD_TOOLS=OFF -DMNN_BUILD_BENCHMARK=OFF -DMNN_BUILD_TEST=OFF \
  -DMNN_BUILD_CONVERTER=OFF -DMNN_KLEIDIAI=OFF -DCMAKE_CXX_FLAGS="-Wl,-z,max-page-size=16384"
"$c/cmake.exe" --build "$build" --parallel "${THRU3D_BUILD_JOBS:-8}"
printf 'MNN_LIB=%s/libMNN.a\n' "$build"
