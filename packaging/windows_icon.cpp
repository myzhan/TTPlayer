#include "ui/AppIcon.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QDataStream>
#include <QDir>
#include <QFileInfo>
#include <QSaveFile>
#include <QTextStream>
#include <array>

// 构建期复用 AppIcon 生成 ICO / PNG，不启动播放器，也不需要 Qt 平台插件或用户存档。
int main(int argc, char *argv[]) {
    QCoreApplication app(argc, argv);
    if (app.arguments().size() != 2) return 1;
    const QString path = app.arguments().at(1);
    if (QFileInfo(path).suffix().compare(QStringLiteral("png"), Qt::CaseInsensitive) == 0) {
        if (!QDir().mkpath(QFileInfo(path).absolutePath())) return 1;
        QSaveFile file(path);
        if (!file.open(QIODevice::WriteOnly) || !AppIcon::image(256).save(&file, "PNG") || !file.commit()) return 1;
        return 0;
    }
    constexpr std::array sizes{16, 24, 32, 48, 64, 128, 256};
    std::array<QByteArray, sizes.size()> images;
    for (size_t i = 0; i < sizes.size(); ++i) {
        QBuffer buffer(&images[i]);
        if (!buffer.open(QIODevice::WriteOnly) || !AppIcon::image(sizes[i]).save(&buffer, "PNG")) {
            QTextStream(stderr) << "无法编码 Windows 图标\n";
            return 1;
        }
    }
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) return 1;
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly)) return 1;
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream << quint16(0) << quint16(1) << quint16(sizes.size());
    quint32 offset = 6 + 16 * quint32(sizes.size());
    for (size_t i = 0; i < sizes.size(); ++i) {
        const auto side = quint8(sizes[i] == 256 ? 0 : sizes[i]);
        stream << side << side << quint8(0) << quint8(0) << quint16(1) << quint16(32) << quint32(images[i].size())
               << offset;
        offset += quint32(images[i].size());
    }
    for (const auto &bytes : images) {
        if (stream.writeRawData(bytes.constData(), int(bytes.size())) != bytes.size()) return 1;
    }
    if (stream.status() != QDataStream::Ok || !file.commit()) return 1;
    return 0;
}
