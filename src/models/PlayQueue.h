#pragma once

// 基础播放上下文，与浏览列表独立：切页、筛选、排序不重建播放序列。
// 条目身份连接无缝预取、实际推进及随机历史；删行不停止当前曲。

#include "Track.h"

#include <QList>
#include <QSet>
#include <QUuid>
#include <functional>
#include <memory>
#include <optional>

struct QueueItem {
    QUuid id = QUuid::createUuid();
    Track track; // 重新定位只换曲，不换条目身份。
    bool operator==(const QueueItem &o) const { return id == o.id; }
};

enum class PlayMode { Order, ListLoop, SingleLoop, Random };

class PlayQueue {
public:
    // —— 查询 ——
    const QList<QueueItem> &items() const { return m_items; }
    int count() const { return m_items.size(); }
    bool isEmpty() const { return m_items.isEmpty(); }
    std::optional<int> cursor() const { return m_cursor; }
    const QueueItem *current() const;
    Track currentTrack() const;
    const QueueItem *itemAt(int index) const;
    int indexOf(const QUuid &id) const; // -1 = 没有
    std::optional<int> currentIndex() const { return m_cursor; }
    const QList<QUuid> &history() const { return m_history; }

    // —— 建立与选择 ——
    /// 双击曲目：以当时的列表顺序建立新的基础播放序列。
    void begin(const QList<Track> &tracks, int index);
    void reset();
    /// 恢复播放现场（F06，后续接存档）：条目次序、游标、历史照单收下
    void restoreScene(const QList<QueueItem> &items, std::optional<int> cursor, const QList<int> &historyIndexes);
    /// 按稳定条目身份移动播放游标。
    const QueueItem *focus(const QUuid &id);
    /// 只查不动：按 id 拿那一条（focus 会挪游标的场合不能用它）
    const QueueItem *item(const QUuid &id) const;
    /// 真开播了才记一笔，供随机回退
    void markPlayed(const QUuid &id);

    // —— 浏览列表删除与重新定位（都不停止当前曲）——
    /// 浏览列表删行：同键条目一并摘掉，正在播的形列外
    void dropTracks(const QSet<QString> &keys);
    void replaceTrack(const QString &key, const Track &track);

    // —— 接下来播谁 ——
    /// 手动「下一首」：无论如何往前走一步（单曲循环也能被跳过；随机照摇）
    const QueueItem *advanceByUser(PlayMode mode);
    /// 一整曲播完后的自然推进（先定选算过就复用同一个答案）
    const QueueItem *advanceOnFinish(PlayMode mode);
    /// 「假如现在就自然播完，接下来轮到哪一条」：只算不动游标（F01 预取用）
    const QueueItem *peekOnFinish(PlayMode mode);
    /// 作废先定选（队列、模式、游标任一处变了都要叫）
    void invalidatePick() { m_prePicked = std::nullopt; }
    /// 「上一首」：随机模式沿实际播放历史回退，其余按队列次序
    const QueueItem *retreat(PlayMode mode);

    /// 随机数来源（自检换固定答案）；默认尽量避免连抽同一首
    std::function<int(int count, int cursor)> randomIndex;

private:
    const QueueItem *nextItem() const;
    const QueueItem *nextOnFinish(PlayMode mode) const;
    const QueueItem *randomPeek() const;
    const QueueItem *itemWhereId(const QUuid &id) const;
    const QueueItem *focusItem(const QUuid &id);
    const QueueItem *tailItem(PlayMode mode);
    bool idxOk(int i) const { return i >= 0 && i < m_items.size(); }
    void pruneHistory(); // 丢掉指向已不存在条目的历史 id

    QList<QueueItem> m_items;
    std::optional<int> m_cursor;      // 正在播的条目下标（nullopt = 还没建立上下文）
    QList<QUuid> m_history;           // 真开播过的条目身份，最近的在末尾
    std::optional<QUuid> m_prePicked; // 先定选：预取与推进必须同一个答案
};
