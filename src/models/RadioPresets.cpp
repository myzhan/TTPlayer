#include "RadioPresets.h"

#include <QChar>

namespace {

// 剥掉首尾成对的引号/尖括号（从浏览器复制地址时常见）
QString trimBrackets(const QString &in) {
    const auto isWrap = [](QChar c) {
        return c == QLatin1Char('"') || c == QLatin1Char('\'')
            || c == QLatin1Char('<') || c == QLatin1Char('>');
    };
    int a = 0, b = int(in.size());
    while (a < b && isWrap(in[a])) ++a;
    while (b > a && isWrap(in[b - 1])) --b;
    return in.mid(a, b - a);
}

} // namespace

QUrl RadioURL::normalize(const QString &raw) {
    QString s = trimBrackets(raw.trimmed());
    if (s.isEmpty()) return {};
    if (!s.contains(QLatin1String("://"))) s = QLatin1String("http://") + s;
    const QUrl u(s, QUrl::TolerantMode);
    const QString scheme = u.scheme().toLower();
    if (scheme != QLatin1String("http") && scheme != QLatin1String("https")) return {};
    if (u.host().isEmpty()) return {};
    return u;
}

QString RadioURL::displayName(const QUrl &url) {
    if (url.isEmpty()) return {};
    const QString tail = url.path().section(QLatin1Char('/'), -1);
    QString name = url.host();
    if (url.port() > 0) name += QStringLiteral(":%1").arg(url.port());
    if (!tail.isEmpty()) name += QLatin1Char('/') + tail;
    return name.isEmpty() ? url.toString() : name;
}

QUrl RadioPreset::url() const { return RadioURL::normalize(address); }

QString RadioPreset::identityKey() const {
    const QUrl u = url();
    return u.isEmpty() ? address : u.toString();
}

Track RadioPreset::toTrack() const {
    const QUrl u = url();
    Track t = Track::fromRadio(u);
    t.setTitle(name);   // 显示走内置台名，而不是 host/尾段
    return t;
}

namespace RadioPresets {

const QList<RadioPreset> &all() {
    static const QList<RadioPreset> kAll = {
        {QStringLiteral("Whispering Solo Piano Radio"),
         QStringLiteral("https://pianosolo.streamguys1.com/live")},
    };
    return kAll;
}

QString nameFor(const QUrl &url) {
    if (url.isEmpty()) return {};
    const QString key = url.toString();
    for (const RadioPreset &p : all())
        if (p.identityKey() == key) return p.name;
    return {};
}

} // namespace RadioPresets
