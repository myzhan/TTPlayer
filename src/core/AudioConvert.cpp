#include "AudioConvert.h"

#include <QDir>
#include <QFileInfo>

#include <algorithm>

namespace {

// 格式表：顺序即下拉框顺序。两种 m4a 靠 label 区分（AAC 有损 / ALAC 无损）。
const QList<ConvertFormat> kFormats{
    {QStringLiteral("aac"), QStringLiteral("AAC (M4A)"), QStringLiteral("m4a"), AV_CODEC_ID_AAC, false, false, 256, 0},
    {QStringLiteral("alac"), QStringLiteral("ALAC (M4A 无损)"), QStringLiteral("m4a"), AV_CODEC_ID_ALAC, true, true, 0, 2},
    {QStringLiteral("flac"), QStringLiteral("FLAC"), QStringLiteral("flac"), AV_CODEC_ID_FLAC, true, true, 0, 12},
    {QStringLiteral("wav"), QStringLiteral("WAV"), QStringLiteral("wav"), AV_CODEC_ID_PCM_S16LE, true, false, 0, 0},
};

} // namespace

namespace AudioConvert {

const QList<ConvertFormat> &formats() {
    return kFormats;
}

const ConvertFormat *formatById(const QString &id) {
    for (const ConvertFormat &f : kFormats)
        if (f.id == id) return &f;
    return nullptr;
}

QString outputName(const QString &inputPath, const QString &extension) {
    return QFileInfo(inputPath).completeBaseName() + QLatin1Char('.') + extension;
}

QString uniqueOutputPath(const QString &inputPath, const QString &dir, const QString &extension) {
    const QFileInfo src(inputPath);
    const QDir outDir(dir.isEmpty() ? src.absolutePath() : dir);
    const QString base = src.completeBaseName();

    QString candidate = outDir.filePath(base + QLatin1Char('.') + extension);
    for (int n = 2; QFileInfo::exists(candidate); ++n)
        candidate = outDir.filePath(QStringLiteral("%1 (%2).%3").arg(base).arg(n).arg(extension));
    return candidate;
}

EncodeTarget targetFor(const ConvertParams &params) {
    EncodeTarget target;
    const ConvertFormat *fmt = formatById(params.formatId);
    if (!fmt) return target;

    target.codecId = fmt->codecId;
    target.sampleRate = params.sampleRate;
    target.channels = params.channels;
    target.gainDb = params.gainDb;
    if (!fmt->lossless) target.bitrateKbps = params.bitrateKbps > 0 ? params.bitrateKbps : fmt->defaultKbps;
    if (fmt->supportsCompression) target.compressionLevel = std::clamp(params.compressionLevel, 0, fmt->maxCompression);
    return target;
}

} // namespace AudioConvert
