#pragma once

// 自建歌单的 M3U / M3U8 读写（F04）。行写法：
// - 普通文件 → 绝对路径（第三方播放器也认）
// - 电台 → 完整 http/https 地址
// - 精确选中的一条 CUE 分轨 → `<分轨表路径>#track=<轨号>`
// - 归档里的一个条目 → `file://…#archive-entry=<条目>`
// 后两种是 TTPlayer 扩展写法：别的播放器读不懂会把整行当找不到的文件跳过，TTPlayer 自己
// 读回来仍精确到用户选的那一轨 / 那一个条目。普通文件的 identityKey 就等于绝对路径，
// 「导出 → 导入」逐字符保真；指向不在盘上的文件的行也照样写、照样读回来（失效引用可见）。

#include "models/Track.h"

#include <QHash>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <atomic>

namespace PlaylistM3U {

/// 扩展格式标记行：读到它就确认这份 m3u 是按上面那套写法导出的
extern const QString marker;
/// 给人看的兼容说明（跟着写进导出文件）
extern const QString compatibilityNote;

/// 一行该写什么：四种来路都直接用 identityKey
QString lineFor(const Track &track);

/// 按键导出。names/durations 是键 → 显示名 / 秒（缺失写空名、-1 时长）
bool exportKeys(const QStringList &keys, const QHash<QString, QString> &names, const QHash<QString, double> &durations,
                const QString &path);
/// 用界面上正在显示的那批曲目导出（键从曲目现算，保证与存档写法一致）
bool exportTracks(const QList<Track> &tracks, const QString &path);

/// 导入结果：键的次序（歌单里就是行次序）+ 哪些行指向不在盘上的东西 + 读不懂的行数
struct Imported {
    QStringList keys;
    QStringList missing;
    int unreadable = 0;
    QSet<QString> seen;
    QSet<QString> coveredImages;
    QHash<QString, QString> names;

    void keep(const QString &key, bool exists) {
        if (seen.contains(key)) return; // 嵌套/循环引用会反复递同一首，歌单里只留一行
        seen.insert(key);
        keys.append(key);
        if (!exists) missing.append(key);
    }
    void fail() { ++unreadable; }
};

/// 读一个 m3u/m3u8 当成一张歌单；文件连文本都读不出来返回 false
bool importFile(const QString &path, Imported &out);
void importPaths(const QStringList &paths, Imported &out, const std::atomic<bool> *cancel = nullptr);

} // namespace PlaylistM3U
