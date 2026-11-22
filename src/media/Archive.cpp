#include "Archive.h"
#include "FFmpeg.h"

extern "C" {
#include <archive.h>
#include <archive_entry.h>
}

#include <QFileInfo>
#include <QSet>
#include <QUrl>
#include <QByteArray>

extern "C" {
#include <libavutil/error.h>
}

#include <cstdio> // SEEK_SET/CUR/END
#include <algorithm>
#include <vector>

namespace {

int openArchive(struct archive *reader, const QString &path) {
#ifdef _WIN32
    return archive_read_open_filename_w(reader, reinterpret_cast<const wchar_t *>(path.utf16()), 16384);
#else
    return archive_read_open_filename(reader, path.toUtf8().constData(), 16384);
#endif
}

bool nextEntry(struct archive *reader, struct archive_entry **entry) {
    *entry = nullptr;
    const int status = archive_read_next_header(reader, entry);
    // Windows 的当前 C locale 不能表示 PAX UTF-8 名称时，header 仍可用、但返回 WARN。
    return *entry && (status == ARCHIVE_OK || status == ARCHIVE_WARN);
}

QString archiveEntryName(struct archive_entry *entry) {
    if (const char *name = archive_entry_pathname_utf8(entry)) return QString::fromUtf8(name);
    if (const wchar_t *name = archive_entry_pathname_w(entry)) return QString::fromWCharArray(name);
    return {};
}

// AVSEEK_SIZE：FFmpeg 用它查询流总大小（offset 参数无意义）
constexpr int kSeekSize = 0x10000;

const QSet<QString> &archiveExts() {
    static const QSet<QString> s = {
        QStringLiteral("zip"), QStringLiteral("7z"),  QStringLiteral("rar"), QStringLiteral("tar"),
        QStringLiteral("gz"),  QStringLiteral("tgz"), QStringLiteral("bz2"), QStringLiteral("tbz"),
        QStringLiteral("xz"),  QStringLiteral("txz"), QStringLiteral("zst"),
    };
    return s;
}

QString suffixOf(const QString &path) {
    return QFileInfo(path).suffix().toLower();
}

} // namespace

namespace Archive {

bool looksLikeArchive(const QString &path) {
    return archiveExts().contains(suffixOf(path));
}

QUrl entryUrl(const QString &archivePath, const QString &entryName) {
    QUrl u = QUrl::fromLocalFile(archivePath);
    // 条目名可能含空格/中文/斜杠，按 percent-encoding 塞进 fragment
    const QString enc = QString::fromUtf8(QByteArray(entryName.toUtf8()).toPercentEncoding());
    u.setFragment(QStringLiteral("archive-entry=%1").arg(enc));
    return u;
}

bool parseEntryUrl(const QUrl &url, QString &archivePath, QString &entryName) {
    const QString frag = url.fragment(QUrl::FullyDecoded);
    if (!frag.startsWith(QLatin1String("archive-entry="))) return false;
    archivePath = url.toLocalFile();
    entryName = frag.mid(QStringLiteral("archive-entry=").length());
    return !archivePath.isEmpty() && !entryName.isEmpty();
}

QStringList listAudioEntries(const QString &archivePath, QStringList *problems) {
    QStringList out;
    const auto reject = [problems, &archivePath](const QString &reason, const QString &entry = QString()) {
        if (problems)
            problems->append((entry.isEmpty() ? archivePath : archivePath + QStringLiteral(" → ") + entry) +
                             QStringLiteral("：") + reason);
    };
    const QSet<QString> &exts = ff::playableExtensions();
    struct archive *a = archive_read_new();
    if (!a) {
        reject(QStringLiteral("无法创建归档读取器"));
        return out;
    }
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    if (openArchive(a, archivePath) != ARCHIVE_OK) {
        const char *error = archive_error_string(a);
        reject(QStringLiteral("归档打开失败：%1").arg(error ? QString::fromUtf8(error) : QStringLiteral("未知错误")));
        archive_read_free(a);
        return out;
    }
    const qsizetype problemsBefore = problems ? problems->size() : 0;
    struct archive_entry *entry = nullptr;
    while (true) {
        entry = nullptr;
        const int status = archive_read_next_header(a, &entry);
        if (status == ARCHIVE_EOF) break;
        if (!entry || (status != ARCHIVE_OK && status != ARCHIVE_WARN)) {
            const char *error = archive_error_string(a);
            reject(
                QStringLiteral("归档读取失败：%1").arg(error ? QString::fromUtf8(error) : QStringLiteral("未知错误")));
            break;
        }
        const QString name = archiveEntryName(entry);
        const la_int64_t sz = archive_entry_size(entry);
        const bool enc = archive_entry_is_encrypted(entry) != 0;
        if (!name.isEmpty() && exts.contains(suffixOf(name))) {
            if (enc)
                reject(QStringLiteral("加密归档条目不支持"), name);
            else if (sz < 0)
                reject(QStringLiteral("归档条目大小无效"), name);
            else
                out.append(name);
        }
        // 不解数据，直接跳到下一条目
        archive_read_data_skip(a);
    }
    if (out.isEmpty() && (!problems || problems->size() == problemsBefore))
        reject(QStringLiteral("归档中没有可播放的音频条目"));
    archive_read_close(a);
    archive_read_free(a);
    return out;
}

} // namespace Archive

ArchiveEntrySource::ArchiveEntrySource(const QString &archivePath, const QString &entryName)
    : m_archivePath(archivePath), m_entryName(entryName) {}

ArchiveEntrySource::~ArchiveEntrySource() {
    close();
}

void ArchiveEntrySource::close() {
    if (m_a) {
        struct archive *a = static_cast<struct archive *>(m_a);
        archive_read_close(a);
        archive_read_free(a);
        m_a = nullptr;
    }
    m_pos = 0;
    m_entrySize = -1;
}

bool ArchiveEntrySource::openAt(int64_t skipBytes) {
    close();
    struct archive *a = archive_read_new();
    if (!a) return false;
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    if (openArchive(a, m_archivePath) != ARCHIVE_OK) {
        archive_read_free(a);
        return false;
    }
    struct archive_entry *entry = nullptr;
    bool found = false;
    while (nextEntry(a, &entry)) {
        if (archiveEntryName(entry) == m_entryName) {
            m_entrySize = archive_entry_size(entry);
            found = true;
            break;
        }
        archive_read_data_skip(a);
    }
    if (!found) {
        archive_read_close(a);
        archive_read_free(a);
        return false;
    }
    m_a = a;
    // 丢弃到目标偏移（seek 靠这笔 O(offset) 重放，条目通常不大）
    if (skipBytes > 0) {
        std::vector<char> scratch(std::size_t{64} * 1024);
        int64_t left = skipBytes;
        while (left > 0) {
            const int chunk = int(std::min<int64_t>(left, int64_t(scratch.size())));
            const la_ssize_t r = archive_read_data(a, scratch.data(), chunk);
            if (r <= 0) break;
            left -= r;
        }
    }
    m_pos = skipBytes;
    return true;
}

int64_t ArchiveEntrySource::read(uint8_t *buf, int buf_size) {
    if (!m_a && !openAt(0)) return AVERROR(EIO);
    struct archive *a = static_cast<struct archive *>(m_a);
    const la_ssize_t r = archive_read_data(a, buf, size_t(buf_size));
    if (r == 0) return 0;           // 条目结束 → EOF
    if (r < 0) return AVERROR(EIO); // 底层错误
    m_pos += r;
    return r;
}

int64_t ArchiveEntrySource::seek(int64_t offset, int whence) {
    if (whence == kSeekSize) return m_entrySize; // 尚未定位过则 -1，FFmpeg 退顺序读
    int64_t target = offset;
    if (whence == SEEK_CUR)
        target = m_pos + offset;
    else if (whence == SEEK_END && m_entrySize >= 0)
        target = m_entrySize + offset;
    if (target < 0) return -1;
    if (!openAt(target)) return -1;
    return m_pos;
}
