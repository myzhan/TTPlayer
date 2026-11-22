#include "PlayQueue.h"

#include <QRandomGenerator>
#include <algorithm>

const QueueItem *PlayQueue::current() const {
    if (!m_cursor || !idxOk(*m_cursor)) return nullptr;
    return &m_items[*m_cursor];
}

Track PlayQueue::currentTrack() const {
    const QueueItem *i = current();
    return i ? i->track : Track();
}

const QueueItem *PlayQueue::itemAt(int index) const {
    return idxOk(index) ? &m_items[index] : nullptr;
}

int PlayQueue::indexOf(const QUuid &id) const {
    for (int i = 0; i < m_items.size(); ++i)
        if (m_items[i].id == id) return i;
    return -1;
}

void PlayQueue::begin(const QList<Track> &tracks, int index) {
    invalidatePick();
    m_items.clear();
    for (const Track &t : tracks)
        m_items.append(QueueItem{.track = t});
    m_cursor = idxOk(index) ? std::optional<int>(index) : std::nullopt;
    m_history.clear();
    if (m_cursor) m_history.append(m_items[*m_cursor].id);
}

void PlayQueue::reset() {
    invalidatePick();
    m_items.clear();
    m_cursor.reset();
    m_history.clear();
}

void PlayQueue::restoreScene(const QList<QueueItem> &items, std::optional<int> cursor,
                             const QList<int> &historyIndexes) {
    invalidatePick();
    m_items = items;
    m_cursor = cursor && *cursor >= 0 && *cursor < m_items.size() ? cursor : std::nullopt;
    m_history.clear();
    if (!m_cursor) return;
    // 历史里指向不存在条目的下标丢掉；重复下标留着（同一首歌听过两次就是听过两次）
    for (int i : historyIndexes)
        if (idxOk(i)) m_history.append(m_items[i].id);
    // 当前条目必须在历史里（它是「最近听过的那一条」），否则随机「上一首」会少一步
    if (m_history.isEmpty() || m_history.last() != m_items[*m_cursor].id) m_history.append(m_items[*m_cursor].id);
}

const QueueItem *PlayQueue::focus(const QUuid &id) {
    const int i = indexOf(id);
    if (i < 0) return nullptr;
    invalidatePick();
    m_cursor = i;
    return &m_items[i];
}

const QueueItem *PlayQueue::item(const QUuid &id) const {
    const int i = indexOf(id);
    return i < 0 ? nullptr : &m_items[i];
}

void PlayQueue::markPlayed(const QUuid &id) {
    if (m_history.isEmpty() || m_history.last() != id) m_history.append(id);
}

void PlayQueue::dropTracks(const QSet<QString> &keys) {
    if (keys.isEmpty()) return;
    invalidatePick();
    const QueueItem *cur = current();
    const QUuid curID = cur ? cur->id : QUuid();
    const QString curKey = cur ? cur->track.identityKey() : QString();
    const bool hasCur = cur != nullptr;
    for (int i = m_items.size() - 1; i >= 0; --i) {
        // 正在播的那条形列外：删行不打断音频、不跳曲
        if (keys.contains(m_items[i].track.identityKey()) &&
            !(hasCur && m_items[i].id == curID && m_items[i].track.identityKey() == curKey))
            m_items.removeAt(i);
    }
    if (hasCur) m_cursor = indexOf(curID);
    pruneHistory();
}

const QueueItem *PlayQueue::nextItem() const {
    if (m_cursor) return idxOk(*m_cursor + 1) ? &m_items[*m_cursor + 1] : nullptr;
    return m_items.isEmpty() ? nullptr : &m_items.first();
}

void PlayQueue::replaceTrack(const QString &key, const Track &track) {
    for (QueueItem &item : m_items)
        if (item.track.identityKey() == key) item.track = track;
    invalidatePick();
}

/// 纯算「播完之后轮到谁」，不碰游标也不记历史：预取与推进共用这一套规矩。
/// 随机模式不看位置，只认摇出来的结果（否则「随机」实际变成顺序遍历）
const QueueItem *PlayQueue::nextOnFinish(PlayMode mode) const {
    const QueueItem *next = nextItem();
    switch (mode) {
    case PlayMode::Random:
        return randomPeek();
    case PlayMode::SingleLoop:
        return current();
    case PlayMode::Order:
        return next;
    case PlayMode::ListLoop:
        return next ? next : (m_items.isEmpty() ? nullptr : &m_items.first());
    }
    return nullptr;
}

const QueueItem *PlayQueue::advanceByUser(PlayMode mode) {
    // 注意不能在入口就 invalidatePick：那会把预取刚定下的答案抹掉（出口作废，
    // 而 focus() 内部本就作废）
    const QueueItem *next = nextItem();
    if (mode == PlayMode::Random) {
        if (const QueueItem *p = randomPeek()) return focus(p->id);
    }
    if (next) return focus(next->id);
    // 到了末尾：单曲循环也不能把手动「下一首」变成原地重播（那等于按了没反应），
    // 回到队首接着走；整个上下文只有一条时才只能重播它
    if (mode == PlayMode::SingleLoop && m_items.size() > 1) return focus(m_items.first().id);
    return tailItem(mode);
}

const QueueItem *PlayQueue::advanceOnFinish(PlayMode mode) {
    const QueueItem *picked = m_prePicked ? itemWhereId(*m_prePicked) : nullptr;
    if (!picked) picked = nextOnFinish(mode);
    m_prePicked.reset();
    if (!picked) return nullptr;
    return focusItem(picked->id);
}

const QueueItem *PlayQueue::peekOnFinish(PlayMode mode) {
    if (m_prePicked) {
        if (const QueueItem *it = itemWhereId(*m_prePicked)) return it;
    }
    const QueueItem *it = nextOnFinish(mode);
    m_prePicked = it ? std::optional<QUuid>(it->id) : std::nullopt;
    return it;
}

const QueueItem *PlayQueue::retreat(PlayMode mode) {
    invalidatePick();
    if (mode == PlayMode::Random && m_history.size() >= 2) {
        m_history.removeLast();
        const QUuid prev = m_history.last();
        const int i = indexOf(prev);
        if (i >= 0) {
            m_cursor = i;
            return &m_items[i];
        }
    }
    if (m_cursor && *m_cursor > 0) return focus(m_items[*m_cursor - 1].id);
    if (mode == PlayMode::ListLoop && !m_items.isEmpty()) return focus(m_items.last().id);
    return current();
}

const QueueItem *PlayQueue::itemWhereId(const QUuid &id) const {
    return item(id);
}

const QueueItem *PlayQueue::focusItem(const QUuid &id) {
    return focus(id);
}

void PlayQueue::pruneHistory() {
    for (int i = m_history.size() - 1; i >= 0; --i)
        if (indexOf(m_history[i]) < 0) m_history.removeAt(i);
}

const QueueItem *PlayQueue::tailItem(PlayMode mode) {
    switch (mode) {
    case PlayMode::Order:
        return nullptr;
    case PlayMode::ListLoop:
        return m_items.isEmpty() ? nullptr : focus(m_items.first().id);
    case PlayMode::SingleLoop:
        return current();
    case PlayMode::Random: {
        const QueueItem *it = randomPeek();
        return it ? focus(it->id) : nullptr;
    }
    }
    return nullptr;
}

const QueueItem *PlayQueue::randomPeek() const {
    if (m_items.isEmpty()) return nullptr;
    if (m_items.size() == 1) return &m_items[0];
    // 默认实现尽量避免连着抽到同一首（试 16 次仍撞上就接受，随机本来就有这一天）
    auto &fn = randomIndex;
    static const std::function<int(int, int)> fallback = [](int count, int cur) {
        int pick = QRandomGenerator::global()->bounded(count);
        int tries = 0;
        while (pick == cur && tries < 16) {
            pick = QRandomGenerator::global()->bounded(count);
            ++tries;
        }
        return pick;
    };
    const int pick =
        fn ? fn(m_items.size(), m_cursor ? *m_cursor : -1) : fallback(m_items.size(), m_cursor ? *m_cursor : -1);
    return idxOk(pick) ? &m_items[pick] : &m_items[0];
}
