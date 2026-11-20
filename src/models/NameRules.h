#pragma once

// 「名字规矩」只有一个来源：歌单名与电台分类名都要去空白（含全角空格 U+3000）、
// 截上限、同名自动区分。两处各写一份的话，用户在歌单里能敲进去的东西到分类里就被拒，说不通。
// 对齐 Swift Models/RadioStations.swift 的 NameRules。

#include <QSet>
#include <QString>

namespace NameRules {

/// 去首尾空白：全角空格（U+3000）不在常规 trim 里，但中文用户敲出来的「空格」常常就是它
inline QString normalized(const QString &raw) {
    return raw.trimmed();   // QString::trimmed 已含 U+3000（QChar::isSpace）
}

/// 同名自动区分：已经有「甲」就用「甲 (2)」，还撞就 (3)……返回实际用的名字与是否改过
inline QString distinct(const QString &name, const QSet<QString> &taken, bool *changed = nullptr) {
    if (!taken.contains(name)) {
        if (changed) *changed = false;
        return name;
    }
    int n = 2;
    while (taken.contains(QStringLiteral("%1 (%2)").arg(name).arg(n))) ++n;
    if (changed) *changed = true;
    return QStringLiteral("%1 (%2)").arg(name).arg(n);
}

} // namespace NameRules
