#include "Importer.h"

#include "Collections.h"
#include "media/Archive.h"
#include "media/Decoder.h"
#include "media/PlaylistM3U.h"

void Importer::probe(Track &t, std::shared_ptr<std::atomic<bool>> cancel) {
    if (t.isNull() || t.isRadio()) return;
    QString archive, entry;
    auto decoder =
        Archive::parseEntryUrl(t.url(), archive, entry)
            ? Decoder::openStream(std::make_shared<ArchiveEntrySource>(archive, entry), t.url().toString(), cancel)
            : Decoder::openFile(t.url().toLocalFile(), cancel);
    if (!decoder) {
        t.setDecodeProblem(QStringLiteral("文件不存在、不可读或没有可用音频流"));
        return;
    }
    auto &d = *decoder;
    double duration = double(d.totalFrames()) / d.sampleRate();
    if (t.isCueSegment()) duration = std::max(0.0, (t.playEnd() >= 0 ? t.playEnd() : duration) - t.playStart());
    t.setMetadata(duration, d.sampleRate(), d.channelCount(), d.bitRateKbps());
    t.setFormatName(d.formatName());
    t.setReplayGainTags(ReplayGainTags::fromTags(d.tags()));
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
    for (const QString &key : imported.keys) {
        if (cancel && cancel->load()) {
            result.cancelled = true;
            break;
        }
        Track t = Collections::resolveToken(key);
        if (t.isNull()) {
            result.problems << key;
            continue;
        }
        if (metadata) {
            probe(t);
            if (!t.decodeProblem().isEmpty()) {
                result.problems << key + QStringLiteral("：") + t.decodeProblem();
                continue;
            }
        }
        if (t.isRadio() && imported.names.contains(key)) t.setTitle(imported.names.value(key));
        result.tracks << t;
    }
    if (imported.unreadable)
        result.problems << QStringLiteral("%1 个条目格式不支持或无法读取").arg(imported.unreadable);
    return result;
}
