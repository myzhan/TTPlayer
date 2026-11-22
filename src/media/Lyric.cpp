#include "Lyric.h"

#include <QRegularExpression>
#include <QFileInfo>
#include <QFile>
#include <QDir>
#include <QChar>
#include <QStringList>
#include <algorithm>
#include <cmath>
#ifdef TTPLAYER_HAVE_TEXTCODEC
#include <QTextCodec>
#endif

namespace {

// 目录 → (归一化名 → .lrc 绝对路径) 的懒建索引，按目录 mtime 失效（一个目录只列一次）。
// 只在主线程访问（loadLyricForCurrent 同步调用），不需加锁。
QHash<QString, QHash<QString, QString>> g_dirIndex;
QHash<QString, qint64> g_dirStamps;
constexpr int kDirCacheLimit = 512;

} // namespace

int Lyric::lineIndexAt(double t) const {
    if (m_lines.empty()) return -1;
    if (t < m_lines.front().time) return -1;
    int lo = 0, hi = int(m_lines.size()) - 1;
    while (lo < hi) {
        const int mid = (lo + hi + 1) / 2;
        if (m_lines[mid].time <= t)
            lo = mid;
        else
            hi = mid - 1;
    }
    return lo;
}

Lyric Lyric::parse(const QString &text) {
    static const QRegularExpression tagPattern(QStringLiteral("\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{1,3}))?\\]"));
    static const QRegularExpression offsetPattern(QStringLiteral("\\[offset:\\s*([+-]?\\d+)\\s*\\]"));

    double offsetSec = 0;
    auto om = offsetPattern.globalMatch(text);
    while (om.hasNext()) { // 多行 offset 取最后一行
        const auto m = om.next();
        offsetSec = m.captured(1).toDouble() / 1000.0;
    }

    Lyric result;
    result.m_fileOffset = offsetSec;
    const QStringList rawLines = text.split(QRegularExpression(QStringLiteral("[\\r\\n]")), Qt::SkipEmptyParts);
    for (const QString &raw : rawLines) {
        const QString line = raw.trimmed();
        if (line.isEmpty() || !line.startsWith(QLatin1Char('['))) continue;
        if (line.left(7).compare(QStringLiteral("[offset"), Qt::CaseInsensitive) == 0) continue;

        QList<QRegularExpressionMatch> matches;
        auto tm = tagPattern.globalMatch(line);
        while (tm.hasNext())
            matches << tm.next();
        if (matches.isEmpty()) continue;

        QString content = line;
        content.remove(tagPattern);
        content = content.trimmed();
        if (content.isEmpty()) continue;

        for (const auto &m : matches) {
            const double mm = m.captured(1).toDouble();
            const double ss = m.captured(2).toDouble();
            double frac = 0;
            const QString f = m.captured(3);
            if (!f.isEmpty()) frac = f.toDouble() / std::pow(10.0, double(f.length()));
            const double time = mm * 60 + ss + frac - offsetSec;
            result.m_lines.push_back({qMax(0.0, time), content});
        }
    }
    std::sort(result.m_lines.begin(), result.m_lines.end(),
              [](const LyricLine &a, const LyricLine &b) { return a.time < b.time; });
    return result;
}

Lyric Lyric::parseEmbedded(const QString &text) {
    QString clean = text;
    clean.remove(QChar(0));
    if (clean.startsWith(QChar(0xFEFF))) clean.remove(0, 1);
    clean.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
    clean.replace(QLatin1Char('\r'), QLatin1Char('\n'));
    clean = clean.trimmed();
    Lyric result = parse(clean);
    if (result.isTimed()) return result;
    // 只有 LRC 头信息而没有正文不算歌词，不能挡住外置文件回退。
    static const QRegularExpression header(QStringLiteral("^\\[(?:ar|ti|al|by|offset|length|re|ve):.*\\]$"),
                                           QRegularExpression::CaseInsensitiveOption);
    QStringList lines;
    for (const QString &line : clean.split(QLatin1Char('\n')))
        if (!header.match(line.trimmed()).hasMatch()) lines << line;
    result.m_plainText = lines.join(QLatin1Char('\n')).trimmed();
    return result;
}

QString Lyric::embeddedText(const QHash<QString, QString> &tags) {
    // QHash 遍历序不稳定；多语言/多标签取值必须确定，带时间的版本优先于纯文本。
    QStringList keys = tags.keys();
    std::sort(keys.begin(), keys.end());
    QString plain;
    for (const QString &name : keys) {
        QString key = name.toLower();
        key.remove(QLatin1Char('_'));
        key.remove(QLatin1Char(' '));
        if (key != QLatin1String("lyrics") && !key.startsWith(QLatin1String("lyrics-")) &&
            key != QLatin1String("unsyncedlyrics") && key != QLatin1String("syncedlyrics") &&
            key != QLatin1String("wm/lyrics"))
            continue;
        const QString text = tags.value(name);
        const Lyric lyric = parseEmbedded(text);
        if (lyric.isTimed()) return text;
        if (!lyric.isEmpty() && plain.isEmpty()) plain = text;
    }
    return plain;
}

QString Lyric::normalized(const QString &name) {
    static const QRegularExpression trackPrefix(QStringLiteral("^\\d{1,3}\\s*[-._ ]\\s*"));
    QString s = name.toLower();
    s.remove(trackPrefix); // 只锚定开头，去首段音轨号
    QString out;
    out.reserve(s.size());
    for (const QChar c : s)
        if (c.isLetterOrNumber()) out.append(c); // 汉字算 letter
    return out;
}

const QHash<QString, QString> &Lyric::lrcIndexIn(const QString &dir) {
    const qint64 stamp = QFileInfo(dir).lastModified().toMSecsSinceEpoch();
    auto cached = g_dirIndex.find(dir);
    if (cached != g_dirIndex.end() && g_dirStamps.value(dir) == stamp)
        return cached.value(); // 引用进哈希，同线程下在下一次变更前稳定
    QHash<QString, QString> map;
    QDir d(dir);
    const QStringList names = d.entryList(QDir::Files, QDir::Name);
    for (const QString &name : names) {
        if (!name.endsWith(QLatin1String(".lrc"), Qt::CaseInsensitive)) continue;
        const QString base = normalized(QFileInfo(name).completeBaseName());
        if (base.isEmpty()) continue;
        const QString full = d.absoluteFilePath(name);
        auto old = map.constFind(base);
        // 归一化撞名标记为空，拒绝把歧义伪装成唯一命中。
        if (old != map.constEnd()) {
            map[base] = QString();
            continue;
        }
        map.insert(base, full);
    }
    if (g_dirIndex.size() >= kDirCacheLimit) {
        g_dirIndex.clear();
        g_dirStamps.clear();
    }
    g_dirIndex.insert(dir, map);
    g_dirStamps.insert(dir, stamp);
    return g_dirIndex.find(dir).value();
}

QStringList Lyric::candidateFiles(const QString &audioPath) {
    const QFileInfo fi(audioPath);
    const QString dir = fi.absolutePath();
    const QString same = dir + QLatin1Char('/') + fi.completeBaseName() + QStringLiteral(".lrc");
    if (QFile::exists(same)) return {same};
    // 同目录归一化唯一命中（「01 - 歌名」↔「歌名」）；拿不准就算没歌词
    const auto &index = lrcIndexIn(dir);
    if (index.isEmpty()) return {};
    const QString want = normalized(fi.completeBaseName());
    if (want.isEmpty()) return {};
    auto exact = index.constFind(want);
    if (exact != index.constEnd()) return exact.value().isEmpty() ? QStringList{} : QStringList{exact.value()};
    QStringList hits;
    for (auto k = index.constBegin(); k != index.constEnd(); ++k)
        if (k.key().contains(want) || want.contains(k.key())) {
            if (k.value().isEmpty()) return {};
            hits << k.value();
        }
    return hits.size() == 1 ? hits : QStringList{}; // 只认唯一命中
}

bool Lyric::isAlbumWide(const QString &lrcPath, const Track &track) {
    const QString base = normalized(QFileInfo(lrcPath).completeBaseName());
    if (base.isEmpty()) return false;
    const QUrl &url = track.url();
    if (url.isLocalFile() && base == normalized(QFileInfo(url.toLocalFile()).completeBaseName())) return true;
    const QUrl sheet = track.cueSheetUrl();
    if (track.isCueSegment() && sheet.isLocalFile() &&
        base == normalized(QFileInfo(sheet.toLocalFile()).completeBaseName()))
        return true;
    return false;
}

Lyric Lyric::parseFile(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    QByteArray data = f.readAll();
    if (data.startsWith("\xEF\xBB\xBF")) data.remove(0, 3); // 剥 UTF-8 BOM
    // 1) 严格 UTF-8：fromUtf8 是 lossy，用替换字符判断是否真是 UTF-8
    const QString u = QString::fromUtf8(data);
    if (!u.contains(QChar(0xFFFD))) {
        Lyric l = parse(u);
        if (!l.isEmpty()) return l;
    }
#ifdef TTPLAYER_HAVE_TEXTCODEC
    // 2) GB18030（GBK 超集）：中文 .lrc 常见，时间标签是 ASCII 但正文需正确解码
    if (QTextCodec *gb = QTextCodec::codecForName("GB18030")) {
        Lyric l = parse(gb->toUnicode(data));
        if (!l.isEmpty()) return l;
    }
#endif
    // 3) Latin-1 兜底（单字节，绝不失败；至少 ASCII 时间标签能解）
    return parse(QString::fromLatin1(data));
}

Lyric Lyric::loadForTrack(const Track &track) {
    if (track.isNull() || track.isRadio()) return {};
    Lyric embedded = parseEmbedded(track.embeddedLyrics());
    if (!embedded.isEmpty()) {
        // 内嵌词属于音频容器，CUE 共用镜像时同样按整盘时间轴对齐。
        if (embedded.isTimed() && track.isCueSegment()) embedded.setMirrorShift(track.playStart());
        return embedded;
    }
    const QUrl &url = track.url();
    if (!url.isLocalFile()) return {};
    const QString image = url.toLocalFile();
    for (const QString &lrcPath : candidateFiles(image)) {
        Lyric ly = parseFile(lrcPath);
        if (ly.isEmpty()) continue;
        // CUE 轨拿到整盘那份：时间轴是镜像绝对秒，补本段起点才对上引擎的「段内第几秒」；
        // 按轨名命中那份本身从 0 计时，不加
        if (track.isCueSegment() && isAlbumWide(lrcPath, track)) ly.setMirrorShift(track.playStart());
        return ly;
    }
    return {};
}
