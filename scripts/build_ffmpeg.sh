#!/bin/zsh
# 从 3rd/ffmpeg 源码编译“音频最小化”静态 FFmpeg，产出到 3rd/ffmpeg-build/{lib,include}。
#
# 只编本项目解码用到的解复用器/解码器/协议，编译时间从“全量几十分钟”压到几分钟；
# 产物是静态 .a，直接静态链进 TTPlayer，App 不依赖外部 dylib。
#
# 幂等：commit 没变且库已存在就跳过；用 --force 强制重来。
# 交叉编译：设 TTPLAYER_ARCHS="arm64 x86_64" 时对每个架构各编一遍再 lipo 合并（发版用）。
set -e
cd "$(dirname "$0")/.."

SRC=3rd/ffmpeg
PREFIX=$(pwd)/3rd/ffmpeg-build
STAMP="$PREFIX/.built-commit"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：$SRC 不存在或未初始化子模块（git submodule update --init --depth 1 3rd/ffmpeg）" >&2
    exit 1
fi

COMMIT=$(git -C "$SRC" rev-parse HEAD)
NEED_BUILD=1
if [[ "$1" != "--force" && -f "$STAMP" && -f "$PREFIX/lib/libavformat.a" ]]; then
    if [[ "$(cat "$STAMP")" == "$COMMIT" ]]; then
        NEED_BUILD=0
    fi
fi

# 目标架构列表：默认本机；发版可传多架构
ARCHS=(native)
if [[ -n "$TTPLAYER_ARCHS" ]]; then
    ARCHS=(${=TTPLAYER_ARCHS})
fi

# ffmpeg 的 arch 名与 clang/universal 名对齐
ffmpeg_arch() {
    case "$1" in
        arm64) echo aarch64 ;;
        x86_64) echo x86_64 ;;
        *) echo "$1" ;;
    esac
}

# 一次性把组件清单集中在这里，configure 会自动补齐依赖（parser/bsf 等）
COMPONENTS=(
    # 协议：本地文件 + 管道；电台由 URLSession 喂自定义 AVIOContext，不需 http/tls
    --enable-protocol=file
    --enable-protocol=pipe
    # 解复用器（容器）
    --enable-demuxer=mp3
    --enable-demuxer=aac
    --enable-demuxer=flac
    --enable-demuxer=ogg
    --enable-demuxer=wav
    --enable-demuxer=aiff
    --enable-demuxer=caf
    --enable-demuxer=au
    --enable-demuxer=w64
    --enable-demuxer=mov
    --enable-demuxer=matroska
    --enable-demuxer=asf
    --enable-demuxer=ape
    --enable-demuxer=wv
    --enable-demuxer=tta
    --enable-demuxer=dsf
    --enable-demuxer=iff
    --enable-demuxer=wsd
    --enable-demuxer=image2
    # 解码器（音频）
    --enable-decoder=mp3
    --enable-decoder=mp3float
    --enable-decoder=aac
    --enable-decoder=aac_fixed
    --enable-decoder=aac_latm
    --enable-decoder=flac
    --enable-decoder=vorbis
    --enable-decoder=opus
    --enable-decoder=alac
    --enable-decoder=ape
    --enable-decoder=wavpack
    --enable-decoder=tta
    --enable-decoder=dsd_lsbf
    --enable-decoder=dsd_msbf
    --enable-decoder=dsd_lsbf_planar
    --enable-decoder=dsd_msbf_planar
    --enable-decoder=wmav1
    --enable-decoder=wmav2
    --enable-decoder=mlp
    --enable-decoder=truehd
    --enable-decoder=ac3
    --enable-decoder=eac3
    # PCM 全套（WAV/AIFF/CAF 里的各种位深/编码）
    --enable-decoder=pcm_s8
    --enable-decoder=pcm_s16le
    --enable-decoder=pcm_s16be
    --enable-decoder=pcm_s24le
    --enable-decoder=pcm_s24be
    --enable-decoder=pcm_s32le
    --enable-decoder=pcm_s32be
    --enable-decoder=pcm_u8
    --enable-decoder=pcm_f32le
    --enable-decoder=pcm_f32be
    --enable-decoder=pcm_f64le
    --enable-decoder=pcm_f64be
    --enable-decoder=pcm_mulaw
    --enable-decoder=pcm_alaw
    # CAF/WAV 里的 IMA ADPCM（QuickTime 'ima4'  fourcc），afconvert 转码矩阵会造这种
    --enable-decoder=adpcm_ima_qt
    # 封面：内嵌图通常是 MJPEG/PNG，解出裸流字节交给 ImageIO 再解码
    --enable-decoder=mjpeg
    --enable-decoder=png
    --enable-decoder=bmp
    --enable-decoder=gif
    --enable-parser=mjpeg
)

build_one() {
    local arch_arg=()
    local bdir="$PREFIX/.obj-$1"
    if [[ "$1" != "native" ]]; then
        # 交叉编译：单靠 --arch 不会让 clang 换 target；--disable-asm 避免同一份
        # inline asm 头（如 x86/mathops.h 里的 "c" 约束）在异架构 target 下编译失败。
        # -arch 同时递到 cflags 与 ldflags，否则 libtool/ar 会拼回 host arch（实测
        # 仅 CC 内嵌 -arch 不够，产出的 .a 还是 host 的，lipo 会“same architectures”失败）。
        arch_arg=(
            --arch="$(ffmpeg_arch "$1")"
            --enable-cross-compile --target-os=darwin
            --disable-asm
            --extra-cflags="-arch $1"
            --extra-ldflags="-arch $1"
        )
    fi

    rm -rf "$bdir"
    mkdir -p "$bdir"
    # 源码内 configure 会污染工作树，用 out-of-tree 构建：从独立目录调 ../configure
    ( cd "$bdir" && "$SRC_DIR_ABS/configure" \
        "${arch_arg[@]}" \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-doc --disable-programs --disable-debug \
        --disable-everything --disable-autodetect \
        --enable-zlib \
        --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
        --disable-avdevice --disable-swscale \
        "${COMPONENTS[@]}" )

    # out-of-tree 下 make 在构建目录里跑，install 到 PREFIX
    local jobs=$(sysctl -n hw.ncpu)
    ( cd "$bdir" && make -j"$jobs" && make install-headers install-lib install-priv-headers 2>/dev/null || make install )
}

SRC_DIR_ABS=$(cd "$SRC" && pwd)

if [[ $NEED_BUILD -eq 0 ]]; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 scripts/build_ffmpeg.sh --force"
    exit 0
fi

mkdir -p "$PREFIX/lib" "$PREFIX/include"

if [[ ${#ARCHS[@]} -eq 1 && "${ARCHS[1]}" == "native" ]]; then
    build_one native
else
    # 多架构：各编一遍，再把每个 .a 用 lipo 合并
    STAGE="$PREFIX/.stage"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    for a in "${ARCHS[@]}"; do
        echo "=== 编译 FFmpeg ($a) ==="
        build_one "$a"
        cp -a "$PREFIX/lib/"*.a "$STAGE/$a.a" 2>/dev/null || true
        for f in "$PREFIX"/lib/*.a; do
            base=$(basename "$f")
            mkdir -p "$STAGE/$a"
            cp -a "$f" "$STAGE/$a/$base"
        done
    done
    # 合并每个库的多架构版本
    for base in $(ls "$STAGE/${ARCHS[1]}"); do
        inputs=()
        for a in "${ARCHS[@]}"; do inputs+=("$STAGE/$a/$base"); done
        lipo -create "${inputs[@]}" -output "$PREFIX/lib/$base"
    done
    rm -rf "$STAGE"
fi

echo "$COMMIT" > "$STAMP"
echo "FFmpeg 静态库编译完成：$PREFIX"
