#pragma once

// 音频转码内核：用内嵌 libavcodec/libavformat 直接把一首曲子转成别的封装 / 编码，
// 不依赖外部 ffmpeg 命令行（本项目静态链的就是同一套库）。
//
// 解码复用 Decoder（统一输出立体声 float 平面帧），编码侧的采样率 / 声道 /
// 采样格式差异由 swr 一次转换补齐；只认 FFmpeg 自带编码器，零新增第三方库。

#include <QString>

#include <atomic>
#include <functional>

extern "C" {
#include <libavcodec/avcodec.h>
}

/// 一次转码的目标参数（codec 层口径，与 UI 文案解耦）。
struct EncodeTarget {
    AVCodecID codecId = AV_CODEC_ID_NONE;
    int sampleRate = 0;        // 0 = 跟源
    int channels = 0;          // 0 = 跟源，1 / 2 = 强制
    int bitrateKbps = 0;       // 0 = 编码器默认
    int compressionLevel = -1; // >=0 = 用编码器的压缩档（FLAC/ALAC）
    double gainDb = 0.0;       // 音量调整（重采样时乘增益），0 = 原样
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
    /// 调用方负责放到后台线程，并保证 output 的父目录已存在。
    static Result convert(const QString &input, const QString &output, const EncodeTarget &target,
                          const Progress &progress, const std::atomic<bool> &cancel);
};
