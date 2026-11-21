#pragma once

// 曲目封面唯一出入口（三条底线，跨平台版）：
// 内嵌 attached_pic 走 FFmpeg 拿原始图字节，外部图走同目录常用名 / 同名文件，
// 一律用 QImage 解码并按档位降采样（Qt 无 ImageIO 缩略图通道，解出后 scale）。
// 缓存按「内嵌=字节摘要 / 外部=路径+大小+mtime」做键，同专辑多曲共用一份。

#include "models/Track.h"

#include <QByteArray>
#include <QImage>
#include <QString>

namespace CoverArt {

// 常驻小档（显示区 56pt，2x 屏解 112px）与大图窗档（窗 240pt，解 512px 足够）
constexpr int kWellPixel = 112;
constexpr int kLargePixel = 256;

/// 内嵌封面原始字节（attached_pic）；没有则返回空
QByteArray embeddedBytes(const QString &filePath);

/// 代表这首曲目的外部封面文件路径；没有则空
QString externalImagePath(const Track &track);

/// 取封面图并降采样到 maxPixel 以内（保比例）；无封面返回空图。带缓存。
QImage imageForTrack(const Track &track, int maxPixel = kLargePixel);

/// 原图像素尺寸（属性面板用，"内嵌 1400×1400"）；无封面返回 {0,0}
QSize pixelSizeForTrack(const Track &track);

/// 清空缓存（自检 / 换皮肤用）
void clearCache();
qint64 cacheBytes();

} // namespace CoverArt
