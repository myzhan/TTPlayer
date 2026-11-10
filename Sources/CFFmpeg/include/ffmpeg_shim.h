#ifndef TTPLAYER_CFFMPEG_SHIM_H
#define TTPLAYER_CFFMPEG_SHIM_H

// Swift 侧 `import CFFmpeg` 拿到的唯一入口：把 FFmpeg 用到的公开头一次聚齐。
// 具体头由 scripts/build_ffmpeg.sh 装到 3rd/ffmpeg-build/include 下，
// Package.swift 用 -I 把该目录喂给编译器。

#ifdef __cplusplus
extern "C" {
#endif

#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/dict.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/mathematics.h>
#include <libavutil/frame.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libswresample/swresample.h>

#ifdef __cplusplus
}
#endif

// 下面几个不是 FFmpeg 自带，而是本项目在 shim.c 里包的 C 辅助：
// 把函数式宏 / 复合字面量包成普通函数，供 Swift 调用。
#ifdef __cplusplus
extern "C" {
#endif

int  cff_averror(int e);
int  cff_averror_eof(void);
int  cff_averror_invalid_data(void);
int  cff_averror_eagain(void);
void cff_errstr(int err, char *buf, int buf_size);
void cff_channel_layout_default(AVChannelLayout *layout, int nb_channels);
void cff_freep(void *arg);

#ifdef __cplusplus
}
#endif

#endif // TTPLAYER_CFFMPEG_SHIM_H
