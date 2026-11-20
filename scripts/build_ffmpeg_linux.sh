#!/usr/bin/env bash
# Linux：从 3rd/ffmpeg 源码编译“音频最小化”静态 FFmpeg，产出到 3rd/ffmpeg-build/{lib,include}。
# 与 macOS 版同一份组件清单（scripts/ffmpeg_components.sh），只是 configure 的平台开关不同。
#
# 依赖（GitHub ubuntu runner）：build-essential nasm yasm zlib1g-dev pkg-config
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
    echo "错误：$SRC 不存在或未初始化子模块（git submodule update --init --depth 1 3rd/ffmpeg）" >&2
    exit 1
fi

COMMIT=$(git -C "$SRC" rev-parse HEAD)
source "$(pwd)/scripts/ffmpeg_components.sh"
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$(uname -m)|linux"
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
BDIR="$PREFIX/.obj-linux"
rm -rf "$BDIR"; mkdir -p "$BDIR"
# out-of-tree：从独立目录调 configure，不污染 submodule 工作树
( cd "$BDIR" && "$SRC_DIR_ABS/configure" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared --enable-pic \
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
