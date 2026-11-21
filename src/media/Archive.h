#pragma once

// 归档流式播放（zip/tar/tar.gz/tar.bz2/7z/rar）——不落地解压，直接经 libarchive 读条目，
// 把条目包成自定义 StreamSource 喂给同一条 FFmpegDecoder（与电台同模式）。
// 条目 URL 一律用 file://<归档绝对路径>#archive-entry=<percentEncoded 条目名>。
// 归档条目的约束：
// 加密条目拒收，seek 走「重开+丢弃到偏移」（归档只做顺序读）。

#include "Decoder.h"

#include <QList>
#include <QString>
#include <QUrl>
#include <memory>

namespace Archive {

/// 按扩展名粗判是否归档容器（真正能否解由 libarchive 嗅探兜底）
bool looksLikeArchive(const QString &path);

/// 列出归档里的可播音频条目名（跳过加密条目与目录）。失败返回空。
QStringList listAudioEntries(const QString &archivePath);

/// 构造条目 URL：file://<archivePath>#archive-entry=<percentEncoded entryName>
QUrl entryUrl(const QString &archivePath, const QString &entryName);

/// 从条目 URL 解析出 (归档路径, 条目名)；不是归档条目返回 false
bool parseEntryUrl(const QUrl &url, QString &archivePath, QString &entryName);

} // namespace Archive

/// libarchive 条目读源：实现 Decoder 的 StreamSource，供 avio 回调按序取字节，
/// seek 通过「重开归档→定位条目→丢弃到目标偏移」实现（zip/tar 均可定位）。
class ArchiveEntrySource : public StreamSource {
public:
    ArchiveEntrySource(const QString &archivePath, const QString &entryName);
    ~ArchiveEntrySource() override;
    ArchiveEntrySource(const ArchiveEntrySource &) = delete;
    ArchiveEntrySource &operator=(const ArchiveEntrySource &) = delete;

    bool open() { return openAt(0); }
    int64_t read(uint8_t *buf, int buf_size) override;
    bool seekable() const override { return true; }
    int64_t seek(int64_t offset, int whence) override;

private:
    // (重)打开归档、定位到目标条目，并丢弃 skipBytes 字节
    bool openAt(int64_t skipBytes);
    void close();

    QString m_archivePath;
    QString m_entryName;
    void *m_a = nullptr;      // struct archive*
    int64_t m_pos = 0;        // 当前条目内已交付字节
    int64_t m_entrySize = -1; // <0 未知
};
