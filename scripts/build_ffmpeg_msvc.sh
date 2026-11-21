#!/usr/bin/env bash
# Windows（MSVC）：在继承了 MSVC 开发者环境的 MSYS2 shell 里，从 3rd/ffmpeg 源码现编静态 FFmpeg，
# 产出到 3rd/ffmpeg-build/{lib,include}（库名 avformat.lib 等，供 CMake 用 MSVC 链接）。
# 与 MinGW/mac/linux 同一份组件清单（scripts/ffmpeg_components.sh）。
#
# 前置条件：
#   - 已在同一 shell 里初始化 MSVC x64 developer environment（vcvars64）
#   - TTPLAYER_VCPKG_ROOT 指向 vcpkg 的 installed/x64-windows（提供 zlib）
#   - MSYS2 安装 pkgconf，用 vcpkg 的 zlib.pc 解析实际库名与链接路径
#
# 幂等：源码 commit、本脚本、组件清单、vcpkg 路径都一致且库齐全才跳过；--force 强制重来。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.."
ROOT=$(pwd)
source "$SCRIPT_DIR/ffmpeg_components.sh"

SRC="$ROOT/3rd/ffmpeg"
PREFIX="$ROOT/3rd/ffmpeg-build"
ZLIB_ROOT="${TTPLAYER_VCPKG_ROOT:?设置 TTPLAYER_VCPKG_ROOT 指向 vcpkg 的 installed/x64-windows}"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：3rd/ffmpeg 不存在或未初始化子模块" >&2
    exit 1
fi

require_frozen_ffmpeg "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)
ZLIB_NATIVE=$(cygpath -m "$ZLIB_ROOT")
export PKG_CONFIG_LIBDIR="$(cygpath -u "$ZLIB_ROOT/lib/pkgconfig")"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
if ! command -v pkgconf >/dev/null; then
    echo "错误：MSYS2 需要 pkgconf（pacman -S pkgconf）来读取 vcpkg 的 zlib.pc" >&2
    exit 1
fi
pkgconf --define-variable=prefix="$ZLIB_NATIVE" --exists zlib
echo "zlib $(pkgconf --modversion zlib): $(pkgconf --define-variable=prefix="$ZLIB_NATIVE" --libs zlib)"
SCRIPT_HASH=$(sha256sum "$SCRIPT_DIR/build_ffmpeg_msvc.sh" | awk '{print $1}')
COMP_HASH=$(sha256sum "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$(uname -m)|msvc|$(cygpath -m "$ZLIB_ROOT")"

# MSVC 的库名没有 lib 前缀、后缀是 .lib
if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT" "" lib; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

ffmpeg_begin_build "$PREFIX"

BDIR="$PREFIX/.obj-msvc"
rm -rf "$BDIR"
mkdir -p "$BDIR"
# extra-ldflags 在探测 MSVC 前原样保存；通过 pkg-config 输入的 -L/-l 才会转换为原生参数。
# vcpkg 的 zlib 1.4 使用 libz.lib，不能依赖 FFmpeg 的 zlib.lib 兜底名。
( cd "$BDIR" && "$SRC/configure" --toolchain=msvc --arch=x86_64 --target-os=win64 \
    --pkg-config=pkgconf \
    --pkg-config-flags="--define-variable=prefix=$ZLIB_NATIVE" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --disable-doc --disable-programs --disable-debug \
    --disable-everything --disable-autodetect \
    --enable-zlib \
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
    "${COMPONENTS[@]}" ) || {
        result=$?
        tail -n 100 "$BDIR/ffbuild/config.log" >&2
        exit "$result"
    }

ffmpeg_make_install "$BDIR" "$(nproc)"

ffmpeg_finish_build "$PREFIX" "$CONFIG_KEY" "$COMMIT"
echo "FFmpeg 静态库编译完成：$PREFIX"
