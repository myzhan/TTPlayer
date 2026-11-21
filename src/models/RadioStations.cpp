#include "RadioStations.h"

#include "NameRules.h"
#include "RadioPresets.h"

#include <QUuid>

namespace {
// 名字规矩：去空白（含全角）+ 截上限。
QString clip(const QString &raw, int limit) {
    return NameRules::normalized(raw).left(limit);
}
QString newId() {
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}
} // namespace

QStringList RadioStations::ids() const {
    QStringList out;
    out.reserve(m_categories.size());
    for (const RadioCategory &c : m_categories)
        out.append(c.id);
    return out;
}

int RadioStations::indexOf(const QString &id) const {
    for (int i = 0; i < m_categories.size(); ++i)
        if (m_categories[i].id == id) return i;
    return -1;
}

QSet<QString> RadioStations::takenNames() const {
    QSet<QString> s;
    for (const RadioCategory &c : m_categories)
        s.insert(c.name);
    return s;
}

QString RadioStations::nameOf(const QString &id) const {
    if (id == uncategorizedID) return QStringLiteral("未分类电台");
    const int i = indexOf(id);
    return i < 0 ? QString() : m_categories[i].name;
}

// 已经不存在的分类 id 一律按未分类算（空串）：不能让存档里一个被删掉的分类把台藏起来
QString RadioStations::categoryIDOf(const QString &key) const {
    QString id = m_assigned.value(key);
    if (id.isEmpty() || id == uncategorizedID || !contains(id)) return QString();
    return id;
}

QStringList RadioStations::keysIn(const QString &id) const {
    const bool uncat = (id == uncategorizedID);
    QStringList out;
    const QList<QString> keys = m_assigned.keys();
    for (const QString &k : keys) {
        const QString cid = categoryIDOf(k);
        if (uncat ? cid.isEmpty() : cid == id) out.append(k);
    }
    out.sort();
    return out;
}

int RadioStations::unassignedCount() const {
    int n = 0;
    const QList<QString> keys = m_assigned.keys();
    for (const QString &k : keys)
        if (categoryIDOf(k).isEmpty()) ++n;
    return n;
}

QString RadioStations::displayName(const QUrl &url) const {
    const QString key = url.toString();
    QString alias = m_aliases.value(key);
    if (!alias.isEmpty()) return alias;
    // 出厂台不占 aliases 那张表：用户没起过名字时也有个能看的台名
    QString preset = RadioPresets::nameFor(url);
    if (!preset.isEmpty()) return preset;
    return RadioURL::displayName(url);
}

bool RadioStations::hasCustomName(const QUrl &url) const {
    return !m_aliases.value(url.toString()).isEmpty();
}

RadioStations::NameSource RadioStations::nameSource(const QUrl &url) const {
    if (hasCustomName(url)) return NameSource::Custom;
    return RadioPresets::nameFor(url).isEmpty() ? NameSource::Address : NameSource::Builtin;
}

QString RadioStations::fallbackText(const QUrl &url) const {
    switch (nameSource(url)) {
    case NameSource::Builtin:
        return QStringLiteral("内置台名「%1」").arg(RadioPresets::nameFor(url));
    case NameSource::Custom:
    case NameSource::Address:
        return QStringLiteral("按地址显示");
    }
    return QStringLiteral("按地址显示");
}

void RadioStations::setAlias(const QString &key, const QString &raw) {
    if (key.isEmpty()) return;
    const QString name = clip(raw, aliasLimit);
    if (name.isEmpty())
        m_aliases.remove(key); // 空名 = 取消自定义
    else
        m_aliases.insert(key, name);
}

bool RadioStations::createCategory(const QString &raw, QString *outId, QString *outNote) {
    const QString base = clip(raw, nameLimit);
    if (base.isEmpty()) return false;
    bool changed = false;
    const QString name = NameRules::distinct(base, takenNames(), &changed);
    RadioCategory made{newId(), name};
    m_categories.append(made);
    if (outId) *outId = made.id;
    if (outNote)
        *outNote = changed ? QStringLiteral("已经有叫「%1」的分类，这个改名为「%2」").arg(base, name) : QString();
    return true;
}

QString RadioStations::renameCategory(const QString &id, const QString &raw) {
    if (id == uncategorizedID) return QStringLiteral("未分类是默认入口，改不了名字");
    const int i = indexOf(id);
    if (i < 0) return QStringLiteral("这个分类已经不在了");
    const QString base = clip(raw, nameLimit);
    if (base.isEmpty()) return QStringLiteral("分类名不能是空的");
    QSet<QString> taken = takenNames();
    taken.remove(m_categories[i].name);
    m_categories[i].name = NameRules::distinct(base, taken);
    return QString();
}

bool RadioStations::deleteCategory(const QString &id, int *moved) {
    if (id == uncategorizedID) return false;
    const int i = indexOf(id);
    if (i < 0) return false;
    // 归属当场清干净：留着指向一个没有的分类的悬空 id 迟早让人看不懂
    int dropped = 0;
    const QList<QString> keys = m_assigned.keys();
    for (const QString &k : keys) {
        if (m_assigned.value(k) == id) {
            m_assigned.remove(k);
            ++dropped;
        }
    }
    m_categories.removeAt(i);
    if (moved) *moved = dropped;
    return true;
}

int RadioStations::moveRadios(const QStringList &keys, const QString &id, QString *problem) {
    if (keys.isEmpty()) return 0;
    // id 空或「未分类」= 把归属摘掉（不是删台）
    if (id.isEmpty() || id == uncategorizedID) {
        int hit = 0;
        for (const QString &k : keys) {
            if (m_assigned.contains(k)) {
                m_assigned.remove(k);
                ++hit;
            }
        }
        return hit;
    }
    if (!contains(id)) {
        if (problem) *problem = QStringLiteral("这个分类已经不在了");
        return 0;
    }
    for (const QString &k : keys)
        m_assigned.insert(k, id);
    return keys.size();
}

int RadioStations::replaceKeys(const QHash<QString, QString> &map) {
    int changed = 0;
    for (auto it = map.constBegin(); it != map.constEnd(); ++it) {
        const QString &oldKey = it.key();
        const QString &newKey = it.value();
        const QString name = m_aliases.take(oldKey);
        if (!name.isEmpty()) {
            if (!m_aliases.contains(newKey)) m_aliases.insert(newKey, name);
            ++changed;
        }
        const QString cid = m_assigned.take(oldKey);
        if (!cid.isEmpty()) {
            if (!m_assigned.contains(newKey)) m_assigned.insert(newKey, cid);
            ++changed;
        }
    }
    return changed;
}

void RadioStations::restore(const QHash<QString, QString> &aliases, const QList<RadioCategory> &cats,
                            const QHash<QString, QString> &assigned) {
    QSet<QString> seenIDs, seenNames;
    QList<RadioCategory> rebuilt;
    for (const RadioCategory &cat : cats) {
        const QString name = clip(cat.name, nameLimit);
        if (name.isEmpty() || cat.id.isEmpty() || cat.id == uncategorizedID || seenIDs.contains(cat.id)) continue;
        seenIDs.insert(cat.id);
        bool changed = false;
        const QString finalName = NameRules::distinct(name, seenNames, &changed);
        seenNames.insert(finalName);
        rebuilt.append({cat.id, finalName});
    }
    m_categories = rebuilt;
    QSet<QString> live;
    for (const RadioCategory &c : rebuilt)
        live.insert(c.id);

    m_aliases.clear();
    for (auto it = aliases.constBegin(); it != aliases.constEnd(); ++it) {
        const QString name = clip(it.value(), aliasLimit);
        if (name.isEmpty() || it.key().isEmpty()) continue; // 地址/名字不对的一律不收
        m_aliases.insert(it.key(), name);
    }
    m_assigned.clear();
    for (auto it = assigned.constBegin(); it != assigned.constEnd(); ++it) {
        if (!it.key().isEmpty() && live.contains(it.value())) m_assigned.insert(it.key(), it.value());
    }
}
