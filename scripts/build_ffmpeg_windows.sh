#!/usr/bin/env bash
# Windows：在 MSYS2（UCRT64 shell）里从 3rd/ffmpeg 源码现编“音频最小化”静态 FFmpeg，
# 产出到 3rd/ffmpeg-build/{lib,include}（MinGW 产物同样是 libavformat.a 等）。
# 与 mac/linux 同一份组件清单（scripts/ffmpeg_components.sh）。
#
# 依赖（在 MSYS2 UCRT64 里先 pacman -S）：
#   mingw-w64-ucrt-x86_64-{toolchain,nasm,yasm,zlib,pkg-config} make
# 必须在 UCRT64 环境跑（不是 MSYS/MSVC），否则 gcc 产的是 POSIX 层，链不进 MinGW Qt。
#
# 幂等：源码 commit、本脚本、组件清单三者一致且库齐全才跳过；--force 强制重来。
set -e
SCRIPT_HASH=$(sha256sum "$0" | awk '{print $1}')
COMP_HASH=$(sha256sum "$(dirname "$0")/ffmpeg_components.sh" | awk '{print $1}')
cd "$(dirname "$0")/.."

SRC=3rd/ffmpeg
PREFIX=$(pwd)/3rd/ffmpeg-build
STAMP="$PREFIX/.built-commit"
CONFIG_STAMP="$PREFIX/.built-config"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：$SRC 不存在或未初始化子模块" >&2
    exit 1
fi
# 明确警告：非 UCRT64 环境编出来的 .a ABI 对不上 MinGW Qt
case "$(uname -s)" in
    UCRT64*) ;;
    *) echo "警告：当前不在 UCRT64 shell（uname=$(uname -s)），请在 MSYS2 UCRT64 里运行本脚本" >&2 ;;
esac

COMMIT=$(git -C "$SRC" rev-parse HEAD)
source "$(pwd)/scripts/ffmpeg_components.sh"
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$(uname -m)|windows"
NEED_BUILD=1
if [[ "${1:-}" != "--force" && -f "$CONFIG_STAMP" && -f "$STAMP" ]]; then
    if [[ "$(cat "$CONFIG_STAMP")" == "$CONFIG_KEY" && "$(cat "$STAMP")" == "$COMMIT" ]]; then
        NEED_BUILD=0
        for lib in avformat avcodec avutil swresample; do
            [[ -f "$PREFIX/lib/lib$lib.a" ]] || NEED_BUILD=1
        done
    fi
fi

if [[ $NEED_BUILD -eq 0 ]]; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

mkdir -p "$PREFIX/lib" "$PREFIX/include"
rm -f "$STAMP" "$CONFIG_STAMP"

SRC_DIR_ABS=$(cd "$SRC" && pwd)
BDIR="$PREFIX/.obj-mingw"
rm -rf "$BDIR"; mkdir -p "$BDIR"
# MinGW 原生 x86_64：asm 交给 yasm/nasm，不 --disable-asm；不 --enable-cross-compile（本机即目标）
( cd "$BDIR" && "$SRC_DIR_ABS/configure" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --disable-doc --disable-programs --disable-debug \
    --disable-everything --disable-autodetect \
    --enable-zlib \
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
    --disable-avdevice --disable-swscale \
    "${COMPONENTS[@]}" )

JOBS=$(nproc)
( cd "$BDIR" && make -j"$JOBS" && (make install-headers install-lib install-priv-headers 2>/dev/null || make install) )

echo "$COMMIT" > "$STAMP"
echo "$CONFIG_KEY" > "$CONFIG_STAMP"
echo "FFmpeg 静态库编译完成：$PREFIX"
