#!/usr/bin/env bash
# FFmpeg“音频最小化”configure 组件清单（三平台共用，唯一真相）。
# build_ffmpeg.sh / build_ffmpeg_linux.sh / build_ffmpeg_windows.sh 都 source 这一份，
# 保证 mac/linux/win 编出来的解码覆盖面完全一致，不会因为某个平台漏了某档而行为漂移。
#
# 只列“本项目解码用到的”解复用器 / 解码器 / 协议；configure 会自动补齐依赖（parser/bsf 等）。
# 电台与归档都不走 FFmpeg 内置网络/解包：前者由 QtNetwork 喂自定义 AVIOContext，
# 后者由 libarchive 喂条目，所以这里不 enable http/tls/zip 等协议。
#
# 兼容 zsh 与 bash：数组定义 + "${COMPONENTS[@]}" 展开在两者语义一致。
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
    # CAF/WAV 里的 IMA ADPCM（QuickTime 'ima4' fourcc）
    --enable-decoder=adpcm_ima_qt
    # 封面：内嵌图通常是 MJPEG/PNG，解出裸流字节交给平台图像解码器再解码
    --enable-decoder=mjpeg
    --enable-decoder=png
    --enable-decoder=bmp
    --enable-decoder=gif
    --enable-parser=mjpeg
)
