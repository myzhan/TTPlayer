#include "UserPlaylist.h"

#include <QUuid>

QStringList UserPlaylist::dedup(const QStringList &keys) {
    QStringList out;
    QSet<QString> seen;
    out.reserve(keys.size());
    for (const QString &k : keys)
        if (!seen.contains(k)) {
            seen.insert(k);
            out.append(k);
        }
    return out;
}

QStringList UserPlaylists::ids() const {
    QStringList out;
    out.reserve(m_items.size());
    for (const UserPlaylist &p : m_items)
        out.append(p.id);
    return out;
}

const UserPlaylist *UserPlaylists::item(const QString &id) const {
    for (const UserPlaylist &p : m_items)
        if (p.id == id) return &p;
    return nullptr;
}

QString UserPlaylists::nameOf(const QString &id) const {
    const UserPlaylist *p = item(id);
    return p ? p->name : QString();
}

QStringList UserPlaylists::keysOf(const QString &id) const {
    const UserPlaylist *p = item(id);
    return p ? p->keys : QStringList();
}

int UserPlaylists::indexOf(const QString &id) const {
    for (int i = 0; i < m_items.size(); ++i)
        if (m_items[i].id == id) return i;
    return -1;
}

bool UserPlaylists::create(const QString &rawName, QString *id, QString *note) {
    const QString base = NameRules::normalized(rawName).left(kNameLimit);
    if (base.isEmpty()) return false;
    QSet<QString> taken;
    for (const UserPlaylist &p : m_items)
        taken.insert(p.name);
    bool changed = false;
    const QString name = NameRules::distinct(base, taken, &changed);
    const QString newId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_items.append(UserPlaylist(newId, name));
    if (id) *id = newId;
    if (note && changed) *note = QStringLiteral("已经有叫「%1」的歌单，这张改名为「%2」").arg(base, name);
    return true;
}

QString UserPlaylists::rename(const QString &id, const QString &rawName) {
    const int i = indexOf(id);
    if (i < 0) return QStringLiteral("这张歌单已经不在了");
    const QString base = NameRules::normalized(rawName).left(kNameLimit);
    if (base.isEmpty()) return QStringLiteral("歌单名不能是空的");
    QSet<QString> taken;
    for (int j = 0; j < m_items.size(); ++j)
        if (j != i) taken.insert(m_items[j].name);
    m_items[i].name = NameRules::distinct(base, taken);
    return QString(); // 空 = 改好了
}

bool UserPlaylists::remove(const QString &id) {
    const int i = indexOf(id);
    if (i < 0) return false;
    m_items.removeAt(i);
    return true;
}

int UserPlaylists::addKeys(const QStringList &newKeys, const QString &id) {
    const int i = indexOf(id);
    if (i < 0) return 0;
    const int before = m_items[i].keys.size();
    QSet<QString> seen(m_items[i].keys.constBegin(), m_items[i].keys.constEnd());
    for (const QString &k : newKeys)
        if (!seen.contains(k)) {
            seen.insert(k);
            m_items[i].keys.append(k);
        }
    return m_items[i].keys.size() - before;
}

int UserPlaylists::removeKeys(const QSet<QString> &gone, const QString &id) {
    const int i = indexOf(id);
    if (i < 0 || gone.isEmpty()) return 0;
    const int before = m_items[i].keys.size();
    QStringList kept;
    kept.reserve(before);
    for (const QString &k : m_items[i].keys)
        if (!gone.contains(k)) kept.append(k);
    m_items[i].keys = kept;
    return before - kept.size();
}

void UserPlaylists::clear(const QString &id) {
    const int i = indexOf(id);
    if (i >= 0) m_items[i].keys.clear();
}

bool UserPlaylists::reorder(const QString &id, const QStringList &order) {
    const int i = indexOf(id);
    if (i < 0) return false;
    const QStringList current = m_items[i].keys;
    if (order.size() != current.size()) return false;
    QStringList pool = current;
    QStringList rebuilt;
    rebuilt.reserve(order.size());
    for (const QString &k : order) {
        const int j = pool.indexOf(k);
        if (j < 0) return false;
        rebuilt.append(pool.takeAt(j));
    }
    m_items[i].keys = rebuilt;
    return true;
}

int UserPlaylists::replaceKeys(const QHash<QString, QString> &map) {
    if (map.isEmpty()) return 0;
    int touched = 0;
    for (UserPlaylist &p : m_items) {
        bool changed = false;
        for (QString &k : p.keys) {
            auto it = map.find(k);
            if (it != map.end() && it.value() != k) {
                k = it.value();
                changed = true;
            }
        }
        if (!changed) continue;
        p.keys = UserPlaylist::dedup(p.keys);
        ++touched;
    }
    return touched;
}

void UserPlaylists::restore(const QList<UserPlaylist> &saved) {
    QSet<QString> seenIDs, seenNames;
    QList<UserPlaylist> rebuilt;
    for (const UserPlaylist &list : saved) {
        const QString name = NameRules::normalized(list.name).left(kNameLimit);
        if (name.isEmpty() || list.id.isEmpty() || seenIDs.contains(list.id)) continue;
        seenIDs.insert(list.id);
        bool changed = false;
        const QString finalName = NameRules::distinct(name, seenNames, &changed);
        seenNames.insert(finalName);
        rebuilt.append(UserPlaylist(list.id, finalName, list.keys));
    }
    m_items = rebuilt;
}
