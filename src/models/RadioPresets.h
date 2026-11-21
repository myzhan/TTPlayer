#pragma once

// 一台内置电台（出厂内容）。
//
// address 存字符串而不是 QUrl：入表一律走 RadioURL.normalize 那一条口子，与用户手输、
// m3u 导进来的地址共用同一个校验与同一个身份写法（电台的 identityKey 就是完整地址），
// 内置的东西没有资格绕过它单开一套。归一化不出来的内置地址就是代码里写错了。

#include "Track.h"

#include <QList>
#include <QString>
#include <QUrl>

struct RadioPreset {
    QString name;
    QString address;

    QUrl url() const;            // normalize 后的地址；非法返回空 QUrl
    QString identityKey() const; // 与 Track::identityKey 对齐（完整地址）
    Track toTrack() const;       // 建成 radio Track，标题走内置台名
};

// 电台地址归一化：只认 http/https，
// 没写协议补 http://，剥掉从浏览器复制常带的引号/尖括号。
namespace RadioURL {
QUrl normalize(const QString &raw);
/// 用户没填名字时的显示名：host[:port] + 路径尾段（够识别，又不至于长得离谱）。
/// Track::fromRadio 与 RadioStations::displayName 共用这一份口径，不各写各的。
QString displayName(const QUrl &url);
} // namespace RadioURL

// 内置电台清单（出厂内容）。启动时默认塞进列表：入口埋得深的东西等于没有，用户不需要
// 就在列表里删掉，删过的那台记进黑名单、以后每次启动都不再塞回来（declinedRadioKeys）。
// 台名也不写进别名表（那张记的是用户自己起的名字）：显示时按地址兜底。
namespace RadioPresets {
const QList<RadioPreset> &all();
QString nameFor(const QUrl &url); // 这个地址是不是出厂自带的那一台（是 → 内置台名）
} // namespace RadioPresets
