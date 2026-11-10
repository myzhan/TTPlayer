// CFFmpeg 编译单元与 C 辅助。
//
// FFmpeg 里若干常用量是函数式宏（AVERROR / AVERROR_EOF / AVERROR_INVALIDDATA）或
// 复合字面量（av_err2str），Swift 的 ClangImporter 无法直接引用，这里包成普通函数。
// 其余 API 都是真函数/结构体，Swift 可直接调用。

#include "ffmpeg_shim.h"
#include <string.h>
#include <errno.h>

int cff_averror(int e) {
    return AVERROR(e);
}

int cff_averror_eof(void) {
    return AVERROR_EOF;
}

int cff_averror_invalid_data(void) {
    return AVERROR_INVALIDDATA;
}

int cff_averror_eagain(void) {
    return AVERROR(EAGAIN);
}

// 把 av_strerror 的返回值转成定长缓冲，供 Swift 读取可读错误文本。
void cff_errstr(int err, char *buf, int buf_size) {
    if (buf == NULL || buf_size <= 0) {
        return;
    }
    buf[0] = '\0';
    av_strerror(err, buf, (size_t)buf_size);
}

// AV_CODEC_FLAG_GLOBAL_HEADER 之类是枚举常量，Swift 能取；
// 但 av_channel_layout_default 需要一个可写结构体指针，Swift 里构造不便，包一层。
void cff_channel_layout_default(AVChannelLayout *layout, int nb_channels) {
    av_channel_layout_default(layout, nb_channels);
}

// 释放/引用常用组合，避免 Swift 侧到处对齐 av_free/av_freep。
void cff_freep(void *arg) {
    av_freep(arg);
}
