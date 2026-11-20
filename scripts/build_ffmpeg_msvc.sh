#!/usr/bin/env bash
# Run in an MSYS2 shell inheriting an initialized MSVC developer environment.
set -euo pipefail
cd "$(dirname "$0")/.."
task_prefix="$(pwd)/3rd/ffmpeg-build"
task_source="$(pwd)/3rd/ffmpeg"
task_zlib="${TTPLAYER_VCPKG_ROOT:?Set TTPLAYER_VCPKG_ROOT to installed/x64-windows}"
mkdir -p "$task_prefix/.obj-msvc"
source scripts/ffmpeg_components.sh
cd "$task_prefix/.obj-msvc"
"$task_source/configure" --toolchain=msvc --arch=x86_64 --target-os=win64 \
  --prefix="$task_prefix" --enable-static --disable-shared --disable-programs \
  --disable-doc --disable-debug --disable-everything --disable-autodetect \
  --enable-avformat --enable-avcodec --enable-swresample --enable-avutil --enable-zlib \
  --extra-cflags="-I$(cygpath -m "$task_zlib/include")" \
  --extra-ldflags="-LIBPATH:$(cygpath -m "$task_zlib/lib")" \
  "${COMPONENTS[@]}"
make -j4
make install
