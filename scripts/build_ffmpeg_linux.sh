#!/usr/bin/env bash
# Linux：从 3rd/ffmpeg 源码编译“音频最小化”静态 FFmpeg，产出到 3rd/ffmpeg-build/{lib,include}。
# 与 macOS 版同一份组件清单（scripts/ffmpeg_components.sh），只是 configure 的平台开关不同。
#
# 依赖（GitHub ubuntu runner）：build-essential nasm yasm zlib1g-dev pkg-config
# 外部编码库（lame/ogg/vorbis/opus）由 scripts/codec_deps.sh 从 3rd/ 源码现编，不靠系统包。
# 幂等：源码 commit、本脚本、组件清单三者一致且库齐全才跳过；--force 强制重来。
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.."
ROOT=$(pwd)
source "$SCRIPT_DIR/ffmpeg_components.sh"
source "$SCRIPT_DIR/codec_deps.sh"

SRC="$ROOT/3rd/ffmpeg"
PREFIX="$ROOT/3rd/ffmpeg-build"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：3rd/ffmpeg 不存在或未初始化子模块（git submodule update --init --depth 1 3rd/ffmpeg）" >&2
    exit 1
fi

require_frozen_ffmpeg "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)

# ---- 外部编码库（mp3 / vorbis / opus）先于 FFmpeg 编好 ----
codec_require_sources
CODEC_COMMIT=$(codec_sources_commit)
CODEC_HASH=$(sha256sum "$SCRIPT_DIR/codec_deps.sh" | awk '{print $1}')
CODEC_KEY="$CODEC_COMMIT|$CODEC_HASH|$(uname -m)|linux"
CODEC_JOBS=$(nproc)
export CODEC_JOBS
if [[ "${1:-}" == "--force" ]] || ! codecs_is_built "$CODEC_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"; then
    codecs_begin_build "$CODEC_PREFIX"
    CODEC_BUILD="$CODEC_PREFIX/.obj"
    export CFLAGS="-fPIC"
    export LDFLAGS=""
    echo "=== 编译外部编码库（ogg/vorbis/opus/lame）==="
    # Linux 的单构型要进 PIE 可执行文件，静态库必须带 -fPIC。
    codec_build_cmake ogg "$CODEC_3RD/ogg" "$CODEC_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    codec_build_cmake opus "$CODEC_3RD/opus" "$CODEC_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    codec_build_cmake vorbis "$CODEC_3RD/vorbis" "$CODEC_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_PREFIX_PATH="$CODEC_PREFIX" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    codec_build_lame "$CODEC_PREFIX"
    codecs_finish_build "$CODEC_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"
else
    echo "外部编码库已就绪（$CODEC_PREFIX），跳过编译"
fi

SCRIPT_HASH=$(sha256sum "$SCRIPT_DIR/build_ffmpeg_linux.sh" | awk '{print $1}')
COMP_HASH=$(sha256sum "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$CODEC_HASH|$(uname -m)|linux"

if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT"; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

ffmpeg_begin_build "$PREFIX"

BDIR="$PREFIX/.obj-linux"
rm -rf "$BDIR"
mkdir -p "$BDIR"
# out-of-tree：从独立目录调 configure，不污染 submodule 工作树
# --extra-libs="-lm"：glibc 的 libm 是独立库，而 FFmpeg 的 test_pkg_config 只调
# `pkg-config --libs`（不带 --static），不展开 opus.pc 的 Libs.private: -lm，
# 静态探测就会缺 log/pow 一类符号。追加到每个链接测试末尾，解析顺序也对。
( cd "$BDIR" && PKG_CONFIG_PATH="$CODEC_PREFIX/lib/pkgconfig" \
    "$SRC/configure" \
    --prefix="$PREFIX" \
    $(codecs_pkg_config_flag) \
    --extra-cflags="-I$CODEC_PREFIX/include" \
    --extra-ldflags="-L$CODEC_PREFIX/lib" \
    --extra-libs="-lm" \
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
