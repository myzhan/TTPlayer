#!/usr/bin/env bash
# FFmpeg“音频最小化”configure 组件清单与公共构建函数（唯一真相）。
# 四个平台脚本都 source 这一份：
#   build_ffmpeg.sh（macOS）、build_ffmpeg_linux.sh、build_ffmpeg_windows.sh（MinGW）、
#   build_ffmpeg_msvc.sh（MSVC）
# 保证各平台编出来的解码覆盖面完全一致，不会因为某个平台漏了某档而行为漂移。
#
# 只列“本项目用到的”解复用器 / 解码器 / 编码器 / 封装器；configure 会自动补齐依赖（parser/bsf 等）。
# 电台与归档都不走 FFmpeg 内置网络/解包：前者由 QtNetwork 喂自定义 AVIOContext，
# 后者由 libarchive 喂条目，所以这里不 enable http/tls/zip 等协议。
#
# 编码器：aac / flac / alac / pcm 用 FFmpeg 自带实现；mp3 / vorbis / opus 必须用外部库
# （FFmpeg 没有原生 mp3/opus 编码器，原生 vorbis 编码器是 experimental 且质量不可用），
# 三份外部源码以 submodule 冻结在 3rd/{lame,ogg,vorbis,opus}，由 scripts/codec_deps.sh
# 统一编到 3rd/codec-build 并在 configure 前探测（libmp3lame 用 lame/lame.h + -lmp3lame，
# libvorbis / libopus 走 pkg-config）。封装器对应 ipod/mp4/flac/wav/mp3/ogg。
#
# 兼容 zsh 与 bash：数组定义 + "${COMPONENTS[@]}" 展开在两者语义一致。

# 冻结的 FFmpeg 版本：源码子模块必须停在这个 tag，各平台构建脚本都会校验。
# 升级时一起改：git -C 3rd/ffmpeg checkout n9.0 → 改下面的 FFMPEG_RELEASE → 重编 → 同步 AGENTS.md。
FFMPEG_RELEASE="9.0"
FFMPEG_TAG="n$FFMPEG_RELEASE"

# 分发的对应源码包不带 Git 对象库，使用包内记录的源码版本；重编修改版用 --force。
source_revision() {
    if [[ -f "$1/.source-revision" ]]; then
        cat "$1/.source-revision"
    else
        git -C "$1" rev-parse HEAD
    fi
}

# 校验 3rd/ffmpeg 的 RELEASE 与冻结版本一致；不一致直接失败，
# 防止 CI / 打包在子模块被换到别的分支时悄悄编出另一个版本。
require_frozen_ffmpeg() {
    local src="$1"
    local release
    release="$(cat "$src/RELEASE" 2>/dev/null || true)"
    if [[ "$release" != "$FFMPEG_RELEASE" ]]; then
        echo "错误：3rd/ffmpeg 版本为 '${release:-未知}'，本项目冻结在 FFmpeg $FFMPEG_RELEASE（$FFMPEG_TAG）。" >&2
        echo "恢复：git -C $src checkout $FFMPEG_TAG && git submodule update --init --depth 1 3rd/ffmpeg" >&2
        return 1
    fi
}

COMPONENTS=(
    # 协议：本地文件 + 管道
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
    --enable-demuxer=dts
    --enable-demuxer=dtshd
    --enable-demuxer=mpc
    --enable-demuxer=mpc8
    --enable-demuxer=tak
    --enable-demuxer=shorten
    --enable-demuxer=amr
    --enable-demuxer=ac3
    --enable-demuxer=eac3
    --enable-demuxer=mlp
    --enable-demuxer=truehd
    --enable-demuxer=dsf
    --enable-demuxer=iff
    --enable-demuxer=wsd
    --enable-demuxer=image2
    # 解码器（音频）
    --enable-decoder=mp1
    --enable-decoder=mp2
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
    --enable-decoder=wmapro
    --enable-decoder=wmalossless
    --enable-decoder=wmavoice
    --enable-decoder=dca
    --enable-decoder=mpc7
    --enable-decoder=mpc8
    --enable-decoder=tak
    --enable-decoder=shorten
    --enable-decoder=amrnb
    --enable-decoder=amrwb
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
    # CAF/WAV 里的 IMA ADPCM（QuickTime 'ima4' fourcc）
    --enable-decoder=adpcm_ima_qt
    # 封面：内嵌图通常是 MJPEG/PNG，解出裸流字节交给平台图像解码器再解码
    --enable-decoder=mjpeg
    --enable-decoder=png
    --enable-decoder=bmp
    --enable-decoder=gif
    --enable-parser=mjpeg
    # 外部编码库开关：只开关 encoder 不够，库本身也要 enable，configure 才会做探测
    # （libmp3lame 验证 lame/lame.h + -lmp3lame；libvorbis/libopus 走 pkg-config）。
    --enable-libmp3lame
    --enable-libvorbis
    --enable-libopus
    # 编码器（格式转换：自带实现 + 三份 vendored 外部库）
    --enable-encoder=aac
    --enable-encoder=flac
    --enable-encoder=alac
    --enable-encoder=pcm_s16le
    --enable-encoder=libmp3lame
    --enable-encoder=libvorbis
    --enable-encoder=libopus
    # 封装器（转换输出）
    --enable-muxer=ipod
    --enable-muxer=mp4
    --enable-muxer=flac
    --enable-muxer=wav
    --enable-muxer=mp3
    --enable-muxer=ogg
)

# ---- 公共构建函数（各平台脚本共用） ----

# PREFIX 可复用条件：源码 commit 与配置指纹都匹配，且四个核心库齐全。
# pre/suf 对应各平台的库名：libavcodec.a（mac/linux/MinGW）、avcodec.lib（MSVC）。
ffmpeg_is_built() {
    local prefix="$1" key="$2" commit="$3" pre="${4-lib}" suf="${5-a}" lib
    [[ -f "$prefix/.built-config" && -f "$prefix/.built-commit" ]] || return 1
    [[ "$(cat "$prefix/.built-config")" == "$key" ]] || return 1
    [[ "$(cat "$prefix/.built-commit")" == "$commit" ]] || return 1
    for lib in avformat avcodec avutil swresample; do
        [[ -f "$prefix/lib/$pre$lib.$suf" ]] || return 1
    done
}

# 先删旧标记再编：失败或中断后不能把半套产物当成可复用的完整构建。
ffmpeg_begin_build() {
    mkdir -p "$1/lib" "$1/include"
    rm -f "$1/.built-commit" "$1/.built-config"
}

# 只有整套编译 + install 成功才写标记。
ffmpeg_finish_build() {
    printf '%s\n' "$3" > "$1/.built-commit"
    printf '%s\n' "$2" > "$1/.built-config"
}

# 在 out-of-tree 构建目录里编译，并 install 到 configure 时给的 prefix。
ffmpeg_make_install() {
    ( cd "$1" && make -j"$2" && make install )
}
