#pragma once

// 一张自建歌单（F04）+ 其仓库。对齐 Swift Models/UserPlaylist.swift。
// id 是歌单的稳定身份：改名、增删条目、拖动排序都不动它，所以左栏那一行、存档记住的
// 当前组、右键「加入歌单」指的都是同一张歌单。条目只存 Track.identityKey，对象按需还原。

#include "models/NameRules.h"

#include <QSet>
#include <QString>
#include <QStringList>
#include <QHash>

struct UserPlaylist {
    QString id;
    QString name;
    QStringList keys;   // 组内去重，按用户排的次序

    UserPlaylist() = default;
    UserPlaylist(const QString &i, const QString &n, const QStringList &k = {})
        : id(i), name(n), keys(dedup(k)) {}

    /// 组内去重：同一首歌在一张歌单里只占一行（不同歌单之间互不影响）
    static QStringList dedup(const QStringList &keys);
};

/// 自建歌单的仓库：可变数量的歌单页，与固定页并列摆在左栏。
/// 只管「哪些键属于哪张歌单」，把键还原成曲目是控制器的事。
class UserPlaylists {
public:
    /// 名字长度上限：左栏那一列只有 ~110pt 宽，再长也只是看着像被截断
    static constexpr int kNameLimit = 40;

    const QList<UserPlaylist> &items() const { return m_items; }
    QStringList ids() const;
    int count() const { return m_items.size(); }
    bool isEmpty() const { return m_items.isEmpty(); }

    const UserPlaylist *item(const QString &id) const;
    bool contains(const QString &id) const { return item(id) != nullptr; }
    QString nameOf(const QString &id) const;
    QStringList keysOf(const QString &id) const;
    int indexOf(const QString &id) const;

    // MARK: 建 / 改名 / 删
    /// 新建：名字空返回 false；同名自动区分并把说明写进 *note。成功回填 *id
    bool create(const QString &rawName, QString *id, QString *note = nullptr);
    /// 改名：只改显示名，id 不动。返回空=改好，否则一句原因（空名字/不在了）
    QString rename(const QString &id, const QString &rawName);
    /// 删除整张：只丢这张的定义与键，不动别的歌单/收藏/队列/磁盘
    bool remove(const QString &id);

    // MARK: 内容
    /// 加入若干键（这一张里只留一行），返回真正新增的条数
    int addKeys(const QStringList &newKeys, const QString &id);
    /// 按稳定身份移除条目（不影响别的歌单），返回移除条数
    int removeKeys(const QSet<QString> &gone, const QString &id);
    void clear(const QString &id);
    /// 整体重排：order 必须正好覆盖现有条目（不多不少不重），否则不改
    bool reorder(const QString &id, const QStringList &order);
    /// 重新定位（F08）：所有歌单里的旧键换新键，行次序不动；碰撞并成一行
    int replaceKeys(const QHash<QString, QString> &map);

    // MARK: 存档
    /// 还原存档（旧档没有=空表）。宽容：丢空名/重复 ID/重复名字（自动区分），组内去重
    void restore(const QList<UserPlaylist> &saved);
    /// 写进存档的样子
    const QList<UserPlaylist> &snapshot() const { return m_items; }

private:
    QList<UserPlaylist> m_items;
};
