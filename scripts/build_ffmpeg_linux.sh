#!/usr/bin/env bash
# Linux：从 3rd/ffmpeg 源码编译“音频最小化”静态 FFmpeg，产出到 3rd/ffmpeg-build/{lib,include}。
# 与 macOS 版同一份组件清单（scripts/ffmpeg_components.sh），只是 configure 的平台开关不同。
#
# 依赖（GitHub ubuntu runner）：build-essential nasm yasm zlib1g-dev pkg-config
# 幂等：源码 commit、本脚本、组件清单三者一致且库齐全才跳过；--force 强制重来。
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.."
ROOT=$(pwd)
source "$SCRIPT_DIR/ffmpeg_components.sh"

SRC="$ROOT/3rd/ffmpeg"
PREFIX="$ROOT/3rd/ffmpeg-build"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：3rd/ffmpeg 不存在或未初始化子模块（git submodule update --init --depth 1 3rd/ffmpeg）" >&2
    exit 1
fi

require_frozen_ffmpeg "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)
SCRIPT_HASH=$(sha256sum "$SCRIPT_DIR/build_ffmpeg_linux.sh" | awk '{print $1}')
COMP_HASH=$(sha256sum "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$(uname -m)|linux"

if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT"; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

ffmpeg_begin_build "$PREFIX"

BDIR="$PREFIX/.obj-linux"
rm -rf "$BDIR"
mkdir -p "$BDIR"
# out-of-tree：从独立目录调 configure，不污染 submodule 工作树
( cd "$BDIR" && "$SRC/configure" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared --enable-pic \
    --disable-doc --disable-programs --disable-debug \
    --disable-everything --disable-autodetect \
    --enable-zlib \
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
    --disable-avdevice --disable-swscale \
    "${COMPONENTS[@]}" )

ffmpeg_make_install "$BDIR" "$(nproc)"

ffmpeg_finish_build "$PREFIX" "$CONFIG_KEY" "$COMMIT"
echo "FFmpeg 静态库编译完成：$PREFIX"
