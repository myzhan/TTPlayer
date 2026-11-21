#!/bin/zsh
# 从 3rd/ffmpeg 源码编译“音频最小化”静态 FFmpeg，产出到 3rd/ffmpeg-build/{lib,include}。
#
# 只编本项目解码用到的解复用器/解码器/协议，编译时间从“全量几十分钟”压到几分钟；
# 产物是静态 .a，直接静态链进 TTPlayer，App 不依赖外部 dylib。
#
# 幂等：源码、脚本、架构及部署目标都一致且库齐全才跳过；用 --force 强制重来。
# 交叉编译：设 TTPLAYER_ARCHS="arm64 x86_64" 时对每个架构各编一遍再 lipo 合并（发版用）。
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR/.."
ROOT=$(pwd)
source "$SCRIPT_DIR/ffmpeg_components.sh"
source "$SCRIPT_DIR/codec_deps.sh"

SRC="$ROOT/3rd/ffmpeg"
PREFIX="$ROOT/3rd/ffmpeg-build"
# 与部署目标 macOS 12.0 一致，不能继承构建机器的系统版本。
DEPLOYMENT_TARGET=12.0
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：3rd/ffmpeg 不存在或未初始化子模块（git submodule update --init --depth 1 3rd/ffmpeg）" >&2
    exit 1
fi

require_frozen_ffmpeg "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)

# 目标架构列表：默认本机；发版可传多架构
ARCHS=(native)
if [[ -n "$TTPLAYER_ARCHS" ]]; then
    ARCHS=(${=TTPLAYER_ARCHS})
fi

# ---- 外部编码库（mp3 / vorbis / opus）先于 FFmpeg 编好 ----
# FFmpeg configure 阶段就要探测它们，所以不能等到 CMake 再编；多架构时逐架构
# install 到 stage，再 lipo 成 universal。幂等判断独立于 FFmpeg，避免旧产物被跳过。
codec_require_sources
CODEC_COMMIT=$(codec_sources_commit)
CODEC_HASH=$(shasum -a 256 "$SCRIPT_DIR/codec_deps.sh" | awk '{print $1}')
CODEC_KEY="$CODEC_COMMIT|$CODEC_HASH|${(j:,:)ARCHS}|macos=$DEPLOYMENT_TARGET"
CODEC_JOBS=$(sysctl -n hw.ncpu)
export CODEC_JOBS
if [[ "${1:-}" == "--force" ]] || ! codecs_is_built "$CODEC_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"; then
    codecs_begin_build "$CODEC_PREFIX"
    CODEC_STAGES=()
    for arch in "${ARCHS[@]}"; do
        stage="$CODEC_PREFIX/.stage-$arch"
        rm -rf "$stage"
        CODEC_BUILD="$CODEC_PREFIX/.obj-$arch"
        cmake_flags=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET")
        if [[ "$arch" != "native" ]]; then
            cmake_flags+=(-DCMAKE_OSX_ARCHITECTURES="$arch")
            export CFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET"
            export LDFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET"
        else
            export CFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET"
            export LDFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET"
        fi
        echo "=== 编译外部编码库（ogg/vorbis/opus/lame, $arch）==="
        codec_build_cmake ogg "$CODEC_3RD/ogg" "$stage" \
            -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF "${cmake_flags[@]}" || exit 1
        codec_build_cmake opus "$CODEC_3RD/opus" "$stage" \
            -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF "${cmake_flags[@]}" || exit 1
        codec_build_cmake vorbis "$CODEC_3RD/vorbis" "$stage" \
            -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_PREFIX_PATH="$stage" "${cmake_flags[@]}" || exit 1
        codec_build_lame "$stage" || exit 1
        CODEC_STAGES+=("$stage")
    done
    codecs_merge_libs "$CODEC_PREFIX" "${CODEC_STAGES[@]}" || exit 1
    rm -rf "$CODEC_PREFIX"/.stage-* "$CODEC_PREFIX"/.obj-*
    codecs_finish_build "$CODEC_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"
else
    echo "外部编码库已就绪（$CODEC_PREFIX），跳过编译"
fi

# 旧版只记 commit，macOS/架构/编译参数变化后会误用旧库。
SCRIPT_HASH=$(shasum -a 256 "$SCRIPT_DIR/build_ffmpeg.sh" | awk '{print $1}')
COMP_HASH=$(shasum -a 256 "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$CODEC_HASH|${(j:,:)ARCHS}|$(uname -m)|macos=$DEPLOYMENT_TARGET"

if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT"; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 scripts/build_ffmpeg.sh --force"
    exit 0
fi

# ffmpeg 的 arch 名与 clang/universal 名对齐
ffmpeg_arch() {
    case "$1" in
        arm64) echo aarch64 ;;
        x86_64) echo x86_64 ;;
        *) echo "$1" ;;
    esac
}

build_one() {
    local arch="$1"
    local compiler_flags="-mmacosx-version-min=$DEPLOYMENT_TARGET -I$CODEC_PREFIX/include"
    local link_flags="-mmacosx-version-min=$DEPLOYMENT_TARGET -L$CODEC_PREFIX/lib"
    local pkg_flag
    pkg_flag=$(codecs_pkg_config_flag)
    local bdir="$PREFIX/.obj-$arch"
    local jobs
    local arch_arg=()
    if [[ "$arch" != "native" ]]; then
        # 交叉编译：单靠 --arch 不会让 clang 换 target；--disable-asm 避免同一份
        # inline asm 头（如 x86/mathops.h 里的 "c" 约束）在异架构 target 下编译失败。
        # -arch 同时递到 cflags 与 ldflags，否则 libtool/ar 会拼回 host arch（实测
        # 仅 CC 内嵌 -arch 不够，产出的 .a 还是 host 的，lipo 会“same architectures”失败）。
        arch_arg=(
            --arch="$(ffmpeg_arch "$arch")"
            --enable-cross-compile --target-os=darwin
            --disable-asm
        )
        compiler_flags+=" -arch $arch"
        link_flags+=" -arch $arch"
    fi

    rm -rf "$bdir"
    mkdir -p "$bdir"
    # 源码内 configure 会污染工作树，用 out-of-tree 构建：从独立目录调 ../configure
    # --extra-libs="-lm" 与 Linux/MinGW 保持一致：那两个平台 libm 是独立库，
    # 探测 opus/vorbis 时 pkg-config --libs 不展开 Libs.private，缺了会链接失败。
    ( cd "$bdir" && PKG_CONFIG_PATH="$CODEC_PREFIX/lib/pkgconfig" \
        "$SRC/configure" \
        "${arch_arg[@]}" \
        ${pkg_flag} \
        --extra-cflags="$compiler_flags" \
        --extra-ldflags="$link_flags" \
        --extra-libs="-lm" \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-doc --disable-programs --disable-debug \
        --disable-everything --disable-autodetect \
        --enable-zlib \
        --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
        --disable-avdevice --disable-swscale \
        "${COMPONENTS[@]}" )

    jobs=$(sysctl -n hw.ncpu)
    ffmpeg_make_install "$bdir" "$jobs"
}

ffmpeg_begin_build "$PREFIX"

if [[ ${#ARCHS[@]} -eq 1 && "${ARCHS[1]}" == "native" ]]; then
    build_one native
else
    # 多架构：各编一遍收到 stage/<arch>/，再对同名 .a 逐份 lipo 合并
    STAGE="$PREFIX/.stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    for arch in "${ARCHS[@]}"; do
        echo "=== 编译 FFmpeg ($arch) ==="
        build_one "$arch"
        mkdir -p "$STAGE/$arch"
        cp -a "$PREFIX/lib/"*.a "$STAGE/$arch/"
    done
    for first in "$STAGE/${ARCHS[1]}"/*.a; do
        base=$(basename "$first")
        inputs=()
        for arch in "${ARCHS[@]}"; do
            inputs+=("$STAGE/$arch/$base")
        done
        lipo -create "${inputs[@]}" -output "$PREFIX/lib/$base"
    done
    rm -rf "$STAGE"
fi

ffmpeg_finish_build "$PREFIX" "$CONFIG_KEY" "$COMMIT"
echo "FFmpeg 静态库编译完成：$PREFIX"
