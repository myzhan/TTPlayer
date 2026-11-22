#pragma once

// 格式转换的「格式表 + 参数」与 codec 层目标的翻译（唯一真相）。
//
// 转换走内嵌 libav*（见 media/AudioEncoder）：
//   有损 AAC / MP3 / OGG Vorbis / Opus；无损 ALAC / FLAC / PCM(WAV)。
// MP3 / Vorbis / Opus 的编码器来自 3rd/ 下 vendored 的 libmp3lame / libvorbis /
// libopus（静态链进同一份 libavcodec，见 scripts/codec_deps.sh），所以格式表里
// 能用它们；encoderName 显式钉死具体实现，不靠 codec id 碰运气。

#include "AudioEncoder.h"
#include "models/Track.h"

#include <QList>
#include <QString>

/// 一种可选输出格式：id 稳定（UI 选中项 / 自检用），label 给用户看。
struct ConvertFormat {
    QString id;
    QString label;
    QString extension; // 输出后缀（决定封装器）
    AVCodecID codecId = AV_CODEC_ID_NONE;
    bool lossless = false;
    bool supportsCompression = false;  // 有压缩档可调（FLAC/ALAC）
    int defaultKbps = 256;             // 有损格默认码率
    int maxCompression = 12;           // 压缩档上限（ALAC 编码器只认 0..2）
    const char *encoderName = nullptr; // 外部编码器实现名（libmp3lame 等）；nullptr = 按 codecId 找
};

/// 一次转换的音频参数；0 / -1 表示「跟源」。
struct ConvertParams {
    QString formatId = QStringLiteral("aac");
    int bitrateKbps = 256;     // 只对有损格生效
    int sampleRate = 0;        // 0 = 保持源采样率
    int channels = 0;          // 0 = 保持源声道，1 = 单声道，2 = 立体声
    int compressionLevel = -1; // >=0 且格式支持时生效
    double gainDb = 0.0;       // 音量调整（dB）
};

namespace AudioConvert {

/// 全部可选输出格式（固定顺序，UI 直接照此列项）
const QList<ConvertFormat> &formats();
const ConvertFormat *formatById(const QString &id);

/// 转换入口只收仍存在的本地文件（含 CUE 分轨），电台与归档条目不支持。
bool canConvert(const Track &track);
/// 普通文件转换整首，CUE 分轨沿用播放区间。
EncodeRange inputRange(const Track &track);

/// 输出文件名：沿用源文件主名换后缀（"a.flac" → "a.m4a"）。
QString outputName(const QString &inputPath, const QString &extension);

/// 输出路径：目标目录为空时用源目录；同名已存在则依次加 " (2)"、" (3)"，绝不覆盖源文件。
QString uniqueOutputPath(const QString &inputPath, const QString &dir, const QString &extension);

/// CUE 输出名附带轨号（"a - 01.flac"），同镜像各轨独立命名；不使用标题中的路径字符。
QString outputName(const Track &track, const QString &extension);
QString uniqueOutputPath(const Track &track, const QString &dir, const QString &extension);

/// 把 UI 参数翻译成编码器目标（格式不支持的项目自动忽略）。
EncodeTarget targetFor(const ConvertParams &params);

} // namespace AudioConvert
