#!/usr/bin/env bash
# Windows（MinGW）：在 MSYS2 UCRT64 shell 里从 3rd/ffmpeg 源码现编“音频最小化”静态 FFmpeg，
# 产出到 3rd/ffmpeg-build/{lib,include}（MinGW 产物同样是 libavformat.a 等）。
# 与 mac/linux 同一份组件清单（scripts/ffmpeg_components.sh）。
#
# 依赖（在 MSYS2 UCRT64 里先 pacman -S）：
#   mingw-w64-ucrt-x86_64-{toolchain,nasm,yasm,zlib,pkg-config} make
# 外部编码库（lame/ogg/vorbis/opus）由 scripts/codec_deps.sh 从 3rd/ 源码现编。
# 必须在 UCRT64 环境跑（不是 MSYS/MSVC），否则 gcc 产的是 POSIX 层，链不进 MinGW Qt。
#
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

# ---- 外部编码库（mp3 / vorbis / opus）先于 FFmpeg 编好 ----
codec_require_sources
CODEC_COMMIT=$(codec_sources_commit)
CODEC_HASH=$(sha256sum "$SCRIPT_DIR/codec_deps.sh" | awk '{print $1}')
CODEC_KEY="$CODEC_COMMIT|$CODEC_HASH|$(uname -m)|windows"
CODEC_JOBS=$(nproc)
export CODEC_JOBS
if [[ "${1:-}" == "--force" ]] || ! codecs_is_built "$CODEC_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"; then
    codecs_begin_build "$CODEC_PREFIX"
    CODEC_BUILD="$CODEC_PREFIX/.obj"
    unset CFLAGS LDFLAGS
    echo "=== 编译外部编码库（ogg/vorbis/opus/lame）==="
    codec_build_cmake ogg "$CODEC_3RD/ogg" "$CODEC_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
    codec_build_cmake opus "$CODEC_3RD/opus" "$CODEC_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
    codec_build_cmake vorbis "$CODEC_3RD/vorbis" "$CODEC_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_PREFIX_PATH="$CODEC_PREFIX"
    codec_build_lame "$CODEC_PREFIX"
    codecs_finish_build "$CODEC_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"
else
    echo "外部编码库已就绪（$CODEC_PREFIX），跳过编译"
fi

SCRIPT_HASH=$(sha256sum "$SCRIPT_DIR/build_ffmpeg_windows.sh" | awk '{print $1}')
COMP_HASH=$(sha256sum "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$CODEC_HASH|$(uname -m)|windows"

if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT"; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

ffmpeg_begin_build "$PREFIX"

BDIR="$PREFIX/.obj-mingw"
rm -rf "$BDIR"
mkdir -p "$BDIR"
# MinGW 原生 x86_64：asm 交给 yasm/nasm，不 --disable-asm；不 --enable-cross-compile（本机即目标）
# 与 Linux 一致要 --extra-libs="-lm"：pkg-config --libs 不展开 Libs.private 的 -lm。
( cd "$BDIR" && PKG_CONFIG_PATH="$CODEC_PREFIX/lib/pkgconfig" \
    "$SRC/configure" \
    --prefix="$PREFIX" \
    $(codecs_pkg_config_flag) \
    --extra-cflags="-I$CODEC_PREFIX/include" \
    --extra-ldflags="-L$CODEC_PREFIX/lib" \
    --extra-libs="-lm" \
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
