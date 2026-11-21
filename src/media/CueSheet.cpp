#include "CueSheet.h"

#include <QByteArray>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QRegularExpression>
#include <QStringList>
#include <algorithm>
#include <cmath>
#include <QTextCodec>

namespace {

// 取引号内的值；无引号时取到下一个空格
QString quotedValue(const QString &rest, bool *okOut) {
    const int first = rest.indexOf(QLatin1Char('"'));
    if (first >= 0) {
        const int last = rest.indexOf(QLatin1Char('"'), first + 1);
        if (last > first) {
            *okOut = true;
            return rest.mid(first + 1, last - first - 1);
        }
        *okOut = true;
        return rest.mid(first + 1);
    }
    const QString trimmed = rest.trimmed();
    if (trimmed.isEmpty()) {
        *okOut = false;
        return {};
    }
    *okOut = true;
    return trimmed.section(QLatin1Char(' '), 0, 0);
}

QUrl resolveFile(const QString &name, const QDir &base) {
    if (name.startsWith(QLatin1Char('/'))) return QUrl::fromLocalFile(name);
    return QUrl::fromLocalFile(base.absoluteFilePath(name));
}

struct Draft {
    int number = 0;
    QString title, performer;
    QUrl file;
    bool hasFile = false;
    double index01 = -1, index00 = -1;
};

} // namespace

double CueSheet::parseCueTime(const QString &text) {
    const QStringList f = text.split(QLatin1Char(':'));
    if (f.size() != 3) return -1;
    bool ok = false;
    const double m = f[0].toDouble(&ok);
    if (!ok) return -1;
    const double s = f[1].toDouble(&ok);
    if (!ok) return -1;
    const double frame = f[2].toDouble(&ok);
    if (!ok) return -1;
    if (!std::isfinite(m) || !std::isfinite(s) || !std::isfinite(frame) || m < 0 || s < 0 || s >= 60 || frame < 0 ||
        frame >= 75 || std::floor(m) != m || std::floor(s) != s || std::floor(frame) != frame)
        return -1;
    return m * 60 + s + frame / 75.0;
}

QList<CueTrackInfo> CueSheet::parseFile(const QString &cuePath) {
    QFile f(cuePath);
    if (!f.open(QIODevice::ReadOnly)) return {};
    QByteArray data = f.readAll();
    if (data.startsWith("\xEF\xBB\xBF")) data.remove(0, 3);
    QString text = QString::fromUtf8(data);
    if (text.contains(QChar::ReplacementCharacter))
        text = QTextCodec::codecForName("GB18030")->toUnicode(data); // UTF-8 没解出关键字，退 Latin-1
    return parse(text, QUrl::fromLocalFile(cuePath));
}

QList<CueTrackInfo> CueSheet::parse(const QString &text, const QUrl &sheetUrl) {
    const QDir base = QFileInfo(sheetUrl.toLocalFile()).absoluteDir();
    QList<CueTrackInfo> entries;
    QUrl currentFile;
    QString albumTitle, albumPerformer;
    bool hasCurrentFile = false;
    Draft draft;
    bool haveDraft = false;

    auto flush = [&] {
        if (haveDraft && draft.hasFile) {
            const double start = draft.index01 >= 0 ? draft.index01 : draft.index00;
            if (start >= 0) {
                CueTrackInfo info;
                info.number = draft.number;
                info.title = draft.title;
                info.performer = draft.performer.isEmpty() ? albumPerformer : draft.performer;
                info.album = albumTitle;
                info.fileUrl = draft.file;
                info.sheetUrl = sheetUrl;
                info.start = start;
                info.nextStart = -1;
                entries.append(info);
            }
        }
        haveDraft = false;
        draft = Draft{};
    };

    const QStringList rawLines = text.split(QRegularExpression(QStringLiteral("[\\r\\n]")));
    for (const QString &rawLine : rawLines) {
        QString line = rawLine;
        line.replace(QLatin1Char('\t'), QLatin1Char(' '));
        line = line.trimmed();
        if (line.isEmpty()) continue;
        const QString cmd = line.section(QLatin1Char(' '), 0, 0).toUpper();
        const QString rest = line.contains(QLatin1Char(' ')) ? line.section(QLatin1Char(' '), 1) : QString();

        if (cmd == QLatin1String("REM")) {
            continue;
        } else if (cmd == QLatin1String("FILE")) {
            flush();
            bool ok = false;
            const QString name = quotedValue(rest, &ok);
            if (ok && !name.isEmpty()) {
                currentFile = resolveFile(name, base);
                hasCurrentFile = true;
            }
        } else if (cmd == QLatin1String("TITLE")) {
            bool ok = false;
            const QString v = quotedValue(rest, &ok);
            if (!ok) continue;
            if (haveDraft)
                draft.title = v;
            else
                albumTitle = v;
        } else if (cmd == QLatin1String("PERFORMER")) {
            bool ok = false;
            const QString v = quotedValue(rest, &ok);
            if (!ok) continue;
            if (haveDraft)
                draft.performer = v;
            else
                albumPerformer = v;
        } else if (cmd == QLatin1String("TRACK")) {
            flush();
            draft = Draft{};
            draft.number = rest.section(QLatin1Char(' '), 0, 0).toInt();
            if (draft.number == 0) draft.number = entries.size() + 1;
            draft.file = currentFile;
            draft.hasFile = hasCurrentFile;
            haveDraft = true;
        } else if (cmd == QLatin1String("INDEX")) {
            const QStringList fields = rest.split(QLatin1Char(' '), Qt::SkipEmptyParts);
            if (fields.size() < 2) continue;
            const int idx = fields[0].toInt();
            const double seconds = parseCueTime(fields[1]);
            if (seconds < 0) continue;
            if (idx == 1 && draft.index01 < 0)
                draft.index01 = seconds;
            else if (idx == 0 && draft.index00 < 0)
                draft.index00 = seconds;
        }
    }
    flush();

    // 只保留镜像仍在盘上的条目
    QList<CueTrackInfo> valid;
    for (const CueTrackInfo &e : entries)
        if (QFileInfo::exists(e.fileUrl.toLocalFile())) valid.append(e);
    if (valid.isEmpty()) return {};

    // FILE order is the album order, independent of lexical file names.
    QHash<QUrl, double> next;
    for (qsizetype i = valid.size(); i-- > 0;) {
        if (next.contains(valid[i].fileUrl) && next.value(valid[i].fileUrl) > valid[i].start)
            valid[i].nextStart = next.value(valid[i].fileUrl);
        next.insert(valid[i].fileUrl, valid[i].start);
    }
    return valid;
}

QList<Track> CueSheet::toTracks(const QList<CueTrackInfo> &infos) {
    QList<Track> out;
    for (const CueTrackInfo &info : infos) {
        Track t = Track::fromCueSegment(info.fileUrl, info.number, info.sheetUrl, info.start, info.nextStart);
        // 镜像 URL + 轨号已写进 cue 字段，identityKey 与原键一致；这里覆盖占位标题/表演者
        t.setTitle(info.title.isEmpty() ? QStringLiteral("Track %1").arg(info.number) : info.title);
        t.setArtist(info.performer);
        t.setAlbum(info.album);
        if (info.nextStart >= 0) t.setMetadata(info.nextStart - info.start, 0, 0, 0);
        out.append(t);
    }
    return out;
}
