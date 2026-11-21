#include "TrackFilter.h"

QString TrackFilter::keywordText() const {
    return keyword.trimmed();
}

QString TrackFilter::summary() const {
    QStringList parts;
    const QString kw = keywordText();
    if (!kw.isEmpty()) parts << QStringLiteral("「%1」").arg(kw);
    if (!formats.isEmpty()) {
        QStringList fs = QStringList(formats.constBegin(), formats.constEnd());
        fs.sort(Qt::CaseInsensitive);
        parts << fs.join(QLatin1Char('/'));
    }
    return parts.isEmpty() ? QStringLiteral("全部") : parts.join(QStringLiteral(" + "));
}

bool TrackFilter::matches(const Track &track) const {
    if (!formats.isEmpty() && !formats.contains(track.filterFormat())) return false;
    const QString kw = keywordText();
    if (kw.isEmpty()) return true;
    // 次序有讲究：标题/艺术家最短最易命中，文件名要现取路径末段，放最后
    return track.title().contains(kw, Qt::CaseInsensitive) || track.artist().contains(kw, Qt::CaseInsensitive) ||
           track.album().contains(kw, Qt::CaseInsensitive) || track.fileName().contains(kw, Qt::CaseInsensitive);
}

QList<int> TrackFilter::visibleRows(const QList<Track> &tracks) const {
    if (isEmpty()) return {};
    QList<int> rows;
    rows.reserve(tracks.size());
    for (int i = 0; i < tracks.size(); ++i)
        if (matches(tracks.at(i))) rows.append(i);
    return rows;
}

QStringList TrackFilter::formatOptions(const QList<Track> &tracks) {
    QSet<QString> seen;
    QStringList out;
    for (const Track &t : tracks) {
        const QString f = t.filterFormat();
        if (!seen.contains(f)) {
            seen.insert(f);
            out.append(f);
        }
    }
    out.sort(Qt::CaseInsensitive);
    return out;
}
