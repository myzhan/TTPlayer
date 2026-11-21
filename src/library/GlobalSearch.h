#pragma once

// 全局搜索的索引与判定（F05：搜索框搜的是整个播放器，不再只是当前那一页）。
// 只吃「排好页序的曲目列表」，不认识存档/歌单档案/媒体库（那些在控制器），
// 所以「同一身份出现在好几页时留哪条、命中按什么次序排」能单独被测。
// 搜索的三条规矩：
// 1. 不复制曲目：索引存的是各页本来就有的 Track 引用；
// 2. 只在内容真变了时重建（invalidate 后下次 build）；
// 3. 命中次序 = 页序 + 页内序，同一身份只留第一次出现的那条，但把几页都记下来。

#include "models/Track.h"
#include "models/TrackFilter.h"

#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

/// 一个命名页（收藏 / 某歌单 / 某媒体库分组 / 当前列表）
struct SearchPage {
    QString name;
    QList<Track> tracks;
};

/// 一条命中：曲目对象 + 这个身份出现在哪几页（页序）
struct SearchHit {
    Track track;
    QStringList pages;
};

/// 一次搜索的结果：列得出的命中、真命中多少条、这批命中里有哪些格式档
struct SearchResult {
    QList<SearchHit> hits;
    int total = 0;
    /// 命中里出现过的格式档，不算格式条件（搜索态下「格式」菜单要列得出换档后仍能命中的那些）
    QStringList formats;
};

class GlobalSearch {
public:
    /// 一次给多少条命中：再多不是给人逐行看的；截断要如实写在标题行里
    static constexpr int kResultLimit = 1000;

    /// 内容变了（加减曲目、改档案、建删歌单、库重扫）：缓存作废，下次搜索前重建
    void invalidate();

    /// 索引建好了没有（自检要确认搜之前确实把池子建起来了）
    bool isStale() const { return !m_built; }

    /// 索引里有多少个不同身份（不是命中数）
    int indexedCount() const { return m_rows.size(); }

    /// 按页序建索引：同一身份只留第一次出现的那条对象，后面的页只补页名
    void build(const QList<SearchPage> &pages);

    /// 搜一遍：命中次序就是索引次序。total 是真命中多少条、hits 是列得出的（到 limit）
    SearchResult matches(const TrackFilter &filter, int limit = kResultLimit) const;

    /// 索引里这个身份都在哪几页（命中表行末提示用；没这条给空）
    QStringList pagesOf(const QString &key) const;

private:
    QList<SearchHit> m_rows; // 已按页序去重的索引
    bool m_built = false;
};
