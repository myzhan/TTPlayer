#pragma once

// 音频转码内核：用内嵌 libavcodec/libavformat 直接把一首曲子转成别的封装 / 编码，
// 不依赖外部 ffmpeg 命令行（本项目静态链的就是同一套库）。
//
// 解码复用 Decoder（统一输出立体声 float 平面帧），编码侧的采样率 / 声道 /
// 采样格式差异由 swr 一次转换补齐。
// AAC/ALAC/FLAC/PCM 用 FFmpeg 自带编码器；MP3/Vorbis/Opus 用 vendored 的
// libmp3lame / libvorbis / libopus（名字由各格式显式指定，避免 avcodec_find_encoder
// 按 codec id 碰到别的实现），源码与构建见 scripts/codec_deps.sh。

#include <QString>

#include <atomic>
#include <functional>

extern "C" {
#include <libavcodec/avcodec.h>
}

/// 一次转码的目标参数（codec 层口径，与 UI 文案解耦）。
struct EncodeTarget {
    AVCodecID codecId = AV_CODEC_ID_NONE;
    // 指定编码器实现名（libmp3lame / libvorbis / libopus）；nullptr = 按 codecId 找。
    const char *encoderName = nullptr;
    int sampleRate = 0;        // 0 = 跟源
    int channels = 0;          // 0 = 跟源，1 / 2 = 强制
    int bitrateKbps = 0;       // 0 = 编码器默认
    int compressionLevel = -1; // >=0 = 用编码器的压缩档（FLAC/ALAC）
    double gainDb = 0.0;       // 音量调整（重采样时乘增益），0 = 原样
};

/// 源音频区间（秒）；终点不包含在内，负终点表示读到实际 EOF。
struct EncodeRange {
    double start = 0;
    double end = -1;
};

class AudioEncoder {
public:
    struct Result {
        bool ok = false;
        bool cancelled = false;
        QString error; // 人话原因；ok 时为空
    };

    /// 进度回调（0..1），在工作线程里被调用，不要直接碰 UI。
    using Progress = std::function<void(double ratio)>;

    /// 同步转码 input → output；cancel 置位后在帧边界尽快收手（并删掉半截输出）。
    /// 调用方负责放到后台线程，并保证 output 的父目录已存在且不会覆盖已有文件。
    /// range 按源采样率截取，输出时间轴从 0 开始；省略时转换整首。
    static Result convert(const QString &input, const QString &output, const EncodeTarget &target,
                          const Progress &progress, const std::atomic<bool> &cancel, const EncodeRange &range = {});
};
