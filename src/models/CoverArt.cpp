#include "CoverArt.h"
#include "decoder/FFmpeg.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QCache>
#include <QBuffer>
#include <QImageReader>

extern "C" {
#include <libavformat/avformat.h>
}

namespace {

const QStringList &preferredNames() {
    static const QStringList names = {QStringLiteral("cover"), QStringLiteral("folder"),
                                      QStringLiteral("front"), QStringLiteral("album"),
                                      QStringLiteral("show"), QStringLiteral("thumb")};
    return names;
}

const QStringList &imageExts() {
    static const QStringList exts = {QStringLiteral("jpg"), QStringLiteral("jpeg"),
                                     QStringLiteral("png"), QStringLiteral("gif"),
                                     QStringLiteral("bmp"), QStringLiteral("tif"),
                                     QStringLiteral("tiff"), QStringLiteral("webp")};
    return exts;
}

// 内嵌字节摘要键 / 外部文件「路径+大小+mtime」键
QString embeddedKey(const QByteArray &bytes) {
    return QStringLiteral("d:") + QString::fromLatin1(
        QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex());
}
QString fileKey(const QString &path) {
    const QFileInfo fi(path);
    return QStringLiteral("f:%1|%2|%3").arg(path).arg(fi.size()).arg(fi.lastModified().toMSecsSinceEpoch());
}

// 缓存：键 → 最多 256 px 位图；原始尺寸单独留档，不常驻原图。
QCache<QString, QImage> g_rawCache(8192); // KiB, bounded across albums
QCache<QString, QString> g_embeddedSources(512);
QCache<QString, QSize> g_dimensions(512);

QImage loadEmbeddedRaw(const QString &path) {
    const QString source=fileKey(path);
    if (const QString *key=g_embeddedSources.object(source))
        if(const QImage *image=g_rawCache.object(*key))return *image;
    const QByteArray bytes=CoverArt::embeddedBytes(path);
    const QString key=bytes.isEmpty()?source:embeddedKey(bytes);
    g_embeddedSources.insert(source,new QString(key));
    if(const QImage *cached=g_rawCache.object(key))return *cached;
    QBuffer buffer;buffer.setData(bytes);buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);const QSize size=reader.size();
    g_dimensions.insert(source,new QSize(size));
    if(size.isValid())reader.setScaledSize(size.scaled(256,256,Qt::KeepAspectRatio));
    QImage image=bytes.isEmpty()?QImage():reader.read();
    g_rawCache.insert(key,new QImage(image),std::max(1,int(image.sizeInBytes()/1024)));
    return image;
}

QImage loadFileRaw(const QString &path) {
    const QString key=fileKey(path);
    if(const QImage *image=g_rawCache.object(key))return *image;
    QImageReader reader(path);const QSize size=reader.size();
    g_dimensions.insert(key,new QSize(size));
    if(size.isValid())reader.setScaledSize(size.scaled(256,256,Qt::KeepAspectRatio));
    QImage image=reader.read();
    g_rawCache.insert(key,new QImage(image),std::max(1,int(image.sizeInBytes()/1024)));
    return image;
}

QImage downscaled(const QImage &src, int maxPixel) {
    if (src.isNull()) return {};
    if (qMax(src.width(), src.height()) <= maxPixel) return src;
    return src.scaled(maxPixel, maxPixel, Qt::KeepAspectRatio, Qt::SmoothTransformation);
}

} // namespace

namespace CoverArt {

QByteArray embeddedBytes(const QString &filePath) {
    AVFormatContext *fmt = nullptr;
    if (avformat_open_input(&fmt, filePath.toUtf8().constData(), nullptr, nullptr) < 0 || !fmt)
        return {};
    QByteArray result;
    if (avformat_find_stream_info(fmt, nullptr) >= 0) {
        for (unsigned i = 0; i < fmt->nb_streams; ++i) {
            AVStream *st = fmt->streams[i];
            if (!st || !(st->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
            if (st->attached_pic.size > 0 && st->attached_pic.data) {
                result = QByteArray(reinterpret_cast<const char *>(st->attached_pic.data),
                                    int(st->attached_pic.size));
                break;
            }
        }
    }
    avformat_close_input(&fmt);
    return result;
}

QString externalImagePath(const Track &track) {
    if (track.isNull() || track.isRadio()) return {};
    const QUrl url = track.url();
    if (!url.isLocalFile()) return {};
    const QFileInfo fi(url.toLocalFile());
    const QDir dir = fi.absoluteDir();
    const QString base = fi.completeBaseName();

    // 与音频同名的图片优先
    for (const QString &ext : imageExts()) {
        const QString p = dir.filePath(base + QLatin1Char('.') + ext);
        if (QFileInfo::exists(p)) return p;
    }
    // 其次常用名（大小写不敏感）
    for (const QString &name : preferredNames()) {
        for (const QString &ext : imageExts()) {
            const QStringList hits = dir.entryList({name + QLatin1Char('.') + ext},
                                                   QDir::Files, QDir::Name);
            if (!hits.isEmpty()) return dir.absoluteFilePath(hits.first());
        }
    }
    return {};
}

QImage imageForTrack(const Track &track, int maxPixel) {
    if (track.isNull() || track.isRadio()) return {};
    if (track.url().isLocalFile()) {
        if (QImage raw = loadEmbeddedRaw(track.url().toLocalFile()); !raw.isNull())
            return downscaled(raw, maxPixel);
    }
    const QString ext = externalImagePath(track);
    if (!ext.isEmpty()) {
        if (QImage raw = loadFileRaw(ext); !raw.isNull())
            return downscaled(raw, maxPixel);
    }
    return {};
}

QSize pixelSizeForTrack(const Track &track) {
    if (track.isNull() || track.isRadio()) return {};
    if (track.url().isLocalFile()) {
        QImage raw = loadEmbeddedRaw(track.url().toLocalFile());
        if (!raw.isNull()) {
            if(const QSize *size=g_dimensions.object(fileKey(track.url().toLocalFile())))return *size;
            return raw.size();
        }
    }
    const QString ext = externalImagePath(track);
    if (!ext.isEmpty()) {
        QImageReader r(ext);
        return r.size();
    }
    return {};
}

void clearCache() {
    g_rawCache.clear();g_embeddedSources.clear();g_dimensions.clear();
}
qint64 cacheBytes(){return qint64(g_rawCache.totalCost())*1024;}

} // namespace CoverArt
