#include "GlobalSearch.h"

#include <QSet>

void GlobalSearch::invalidate() {
    m_rows.clear();
    m_built = false;
}

void GlobalSearch::build(const QList<SearchPage> &pages) {
    QHash<QString, int> seen; // identityKey → m_rows 下标
    int total = 0;
    for (const SearchPage &p : pages)
        total += p.tracks.size();
    QList<SearchHit> out;
    out.reserve(total);
    seen.reserve(total);
    for (const SearchPage &page : pages) {
        for (const Track &t : page.tracks) {
            const QString key = t.identityKey();
            auto it = seen.find(key);
            if (it != seen.end()) {
                // 已记过这个身份：只在页名里补一笔，不再第二条（否则同首歌排两回）
                if (!out[*it].pages.contains(page.name)) out[*it].pages.append(page.name);
                continue;
            }
            seen.insert(key, out.size());
            SearchHit h;
            h.track = t;
            h.pages << page.name;
            out.append(h);
        }
    }
    m_rows = out;
    m_built = true;
}

SearchResult GlobalSearch::matches(const TrackFilter &filter, int limit) const {
    // 文本条件单独跑一份判定器：格式档要按「不限格式的全部命中」统计
    const TrackFilter text(filter.keyword, QSet<QString>{});
    SearchResult r;
    if (filter.isEmpty()) return r;
    const QSet<QString> onFormats = filter.formats;
    QSet<QString> fmtSeen;
    for (const SearchHit &h : m_rows) {
        if (!text.matches(h.track)) continue;
        const QString fmt = h.track.filterFormat();
        fmtSeen.insert(fmt);
        if (!onFormats.isEmpty() && !onFormats.contains(fmt)) continue;
        ++r.total;
        if (r.hits.size() < limit) r.hits.append(h);
    }
    r.formats = QStringList(fmtSeen.constBegin(), fmtSeen.constEnd());
    r.formats.sort(Qt::CaseInsensitive);
    return r;
}

QStringList GlobalSearch::pagesOf(const QString &key) const {
    for (const SearchHit &h : m_rows)
        if (h.track.identityKey() == key) return h.pages;
    return {};
}
