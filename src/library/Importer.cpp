#include "Importer.h"

#include "Collections.h"
#include "media/Archive.h"
#include "media/Decoder.h"
#include "media/Lyric.h"
#include "media/FFmpeg.h"
#include "media/PlaylistM3U.h"
#include <QFileInfo>

QString Importer::fileDialogFilter() {
    static const QString filter = [] {
        QSet<QString> extensions = ff::playableExtensions();
        extensions.unite({"cue", "m3u", "m3u8"});
        QStringList patterns;
        for (const QString &extension : extensions)
            patterns << QStringLiteral("*.") + extension;
        patterns.sort();
        const QString audio = patterns.join(QLatin1Char(' '));
        const QString archives = QStringLiteral("*.zip *.7z *.rar *.tar *.gz *.tgz *.bz2 *.tbz *.xz *.txz *.zst");
        return QStringLiteral("音频、列表与压缩包 (%1 %2);;音频与列表 (%1);;压缩包 (%2);;所有文件 (*)")
            .arg(audio, archives);
    }();
    return filter;
}

void Importer::probe(Track &t, std::shared_ptr<const std::atomic<bool>> cancel) {
    if (t.isNull() || t.isRadio()) return;
    t.setEmbeddedLyrics({});
    QString archive, entry;
    const bool archived = Archive::parseEntryUrl(t.url(), archive, entry);
    const QFileInfo file(archived ? archive : t.url().toLocalFile());
    if (!file.exists() || !file.isReadable()) {
        t.setDecodeProblem(file.exists() ? QStringLiteral("文件不可读，请检查权限") : QStringLiteral("文件不存在"));
        return;
    }
    QString error;
    auto decoder = archived ? Decoder::openStream(std::make_shared<ArchiveEntrySource>(archive, entry),
                                                  t.url().toString(), cancel, &error)
                            : Decoder::openFile(t.url().toLocalFile(), cancel, &error);
    if (!decoder) {
        const QString summary = archived ? QStringLiteral("归档音频条目无法读取或解码")
                                         : QStringLiteral("音频解码失败（文件损坏、格式不支持或无可用音频流）");
        t.setDecodeProblem(error.isEmpty() ? summary : summary + QStringLiteral("：") + error);
        return;
    }
    auto &d = *decoder;
    double duration = double(d.totalFrames()) / d.sampleRate();
    if (t.isCueSegment()) duration = std::max(0.0, (t.playEnd() >= 0 ? t.playEnd() : duration) - t.playStart());
    t.setMetadata(duration, d.sampleRate(), d.channelCount(), d.bitRateKbps());
    t.setFormatName(d.formatName());
    t.setReplayGainTags(ReplayGainTags::fromTags(d.tags()));
    t.setEmbeddedLyrics(Lyric::embeddedText(d.tags()));
    if (!t.isCueSegment()) {
        if (!d.tags().value("title").isEmpty()) t.setTitle(d.tags().value("title"));
        const QString artist = d.tags().value("artist", d.tags().value("album_artist"));
        if (!artist.isEmpty()) t.setArtist(artist);
        if (!d.tags().value("album").isEmpty()) t.setAlbum(d.tags().value("album"));
    }
    t.setDecodeProblem({});
}

Importer::Result Importer::read(const QStringList &paths, bool metadata, const std::atomic<bool> *cancel) {
    Result result;
    PlaylistM3U::Imported imported;
    PlaylistM3U::importPaths(paths, imported, cancel);
    result.problems = imported.problems;
    result.cancelled = cancel && cancel->load();
    for (const QString &key : imported.keys) {
        if (cancel && cancel->load()) {
            result.cancelled = true;
            break;
        }
        Track t = Collections::resolveToken(key);
        if (t.isNull()) {
            result.problems << key + QStringLiteral("：无法解析曲目身份或分轨信息");
            continue;
        }
        if (metadata) {
            // probe 同步完成并销毁 Decoder；借用标志不超出 read 的调用栈。
            probe(t, std::shared_ptr<const std::atomic<bool>>(cancel, [](const std::atomic<bool> *) {}));
            if (cancel && cancel->load()) {
                result.cancelled = true;
                break;
            }
            if (!t.decodeProblem().isEmpty()) {
                result.problems << key + QStringLiteral("：") + t.decodeProblem();
                continue;
            }
        }
        if (t.isRadio() && imported.names.contains(key)) t.setTitle(imported.names.value(key));
        result.tracks << t;
    }
    return result;
}
