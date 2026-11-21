#!/usr/bin/env bash
# Windows（MinGW）：在 MSYS2 UCRT64 shell 里从 3rd/ffmpeg 源码现编“音频最小化”静态 FFmpeg，
# 产出到 3rd/ffmpeg-build/{lib,include}（MinGW 产物同样是 libavformat.a 等）。
# 与 mac/linux 同一份组件清单（scripts/ffmpeg_components.sh）。
#
# 依赖（在 MSYS2 UCRT64 里先 pacman -S）：
#   mingw-w64-ucrt-x86_64-{toolchain,nasm,yasm,zlib,pkg-config} make
# 必须在 UCRT64 环境跑（不是 MSYS/MSVC），否则 gcc 产的是 POSIX 层，链不进 MinGW Qt。
#
# 幂等：源码 commit、本脚本、组件清单三者一致且库齐全才跳过；--force 强制重来。
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.."
ROOT=$(pwd)
source "$SCRIPT_DIR/ffmpeg_components.sh"

SRC="$ROOT/3rd/ffmpeg"
PREFIX="$ROOT/3rd/ffmpeg-build"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：3rd/ffmpeg 不存在或未初始化子模块" >&2
    exit 1
fi
# 明确警告：非 UCRT64 环境编出来的 .a ABI 对不上 MinGW Qt
case "$(uname -s)" in
    UCRT64*) ;;
    *) echo "警告：当前不在 UCRT64 shell（uname=$(uname -s)），请在 MSYS2 UCRT64 里运行本脚本" >&2 ;;
esac

require_frozen_ffmpeg "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)
SCRIPT_HASH=$(sha256sum "$SCRIPT_DIR/build_ffmpeg_windows.sh" | awk '{print $1}')
COMP_HASH=$(sha256sum "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$(uname -m)|windows"

if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT"; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

ffmpeg_begin_build "$PREFIX"

BDIR="$PREFIX/.obj-mingw"
rm -rf "$BDIR"
mkdir -p "$BDIR"
# MinGW 原生 x86_64：asm 交给 yasm/nasm，不 --disable-asm；不 --enable-cross-compile（本机即目标）
( cd "$BDIR" && "$SRC/configure" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --disable-doc --disable-programs --disable-debug \
    --disable-everything --disable-autodetect \
    --enable-zlib \
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
    --disable-avdevice --disable-swscale \
    "${COMPONENTS[@]}" )

ffmpeg_make_install "$BDIR" "$(nproc)"

ffmpeg_finish_build "$PREFIX" "$CONFIG_KEY" "$COMMIT"
echo "FFmpeg 静态库编译完成：$PREFIX"
