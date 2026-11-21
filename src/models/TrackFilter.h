#pragma once

// 即时搜索与筛选的条件（F05）：只是「哪些行看得见」的一份描述——不写进列表、不进播放
// 队列、不进存档。筛选态一旦落到数据层，清除搜索之后就再也还原不回用户原来那张完整列表。
// 关键字对 标题/艺术家/专辑/文件名 任一命中（大小写不敏感），
// 格式档空集=不限。

#include "models/Track.h"

#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>

struct TrackFilter {
    QString keyword;       // 原始关键字（未 trim）
    QSet<QString> formats; // 勾选的格式档（取自 Track::filterFormat）；空 = 不限

    TrackFilter() = default;
    TrackFilter(const QString &kw, const QSet<QString> &fmts = {}) : keyword(kw), formats(fmts) {}

    /// 去掉首尾空白后的关键字：只敲空格不算要搜空格
    QString keywordText() const;
    bool isActive() const { return !keywordText().isEmpty() || !formats.isEmpty(); }
    /// 无任何条件（用于「空关键字返回空表、由调用处决定退出搜索」）
    bool isEmpty() const { return keywordText().isEmpty() && formats.isEmpty(); }

    /// 一句话说明当前条件（日志与界面文案用）
    QString summary() const;

    /// 一条曲目在当前条件下是否可见
    bool matches(const Track &track) const;

    /// 命中的原列表行号；无条件时返回空数组（调用处走恒等映射，别为万行白建万个数）
    QList<int> visibleRows(const QList<Track> &tracks) const;

    /// 当前列表里真出现过的格式档（不把用户手里没有的后缀摆到菜单上），按自然序排
    static QStringList formatOptions(const QList<Track> &tracks);
};
