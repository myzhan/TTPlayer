#pragma once

// FFmpeg 运行时薄包装：解码层底座（对齐 Swift 版 Audio/FFmpeg.swift）。
// 日志转接、错误码、编码展示名、demuxer 扩展名白名单。
// 归档条目（#archive-entry）与电台 URL 的自定义 AVIO 通路后续接进来。

#include <QString>
#include <QSet>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

namespace ff {

/// 一次性初始化 + 日志转 stderr（级别 > WARNING 丢弃，防刷屏）
void ensureInit();

QString versionString();

/// 负错误码 → 可读文本
QString errstr(int code);

/// 由 AVCodecID 取人类可读编码名（AAC 靠 profile 细分；PCM 家族必要时加容器前缀）
QString codecName(AVCodecID id, int profile = AV_PROFILE_UNKNOWN, const QString &container = QString());

/// DSD 展示名：位率折算 DSD64/128/… 并附 MHz
QString dsdLabel(AVCodecID codecId, int dsdBitRate);

/// 遍历注册的解复用器，收集声明的扩展名 → 可播白名单
QSet<QString> demuxerExtensions();

/// 完整可播扩展名 = demuxerExtensions() ∪ undeclaredExtensions ∪ floorExtensions。
/// 有些 demuxer（wav/w64/au/snd/dsf）没在 AVInputFormat.extensions 里声明后缀，
/// 枚举拿不到，目录扫描会漏掉它们，这里手动补齐（对齐 Swift 版 AudioFormats）。
const QSet<QString> &playableExtensions();

/// 是否 DSD 解码器（输出采样率要再 /8 的那一族）
bool isDSDCodec(AVCodecID id);

} // namespace ff
