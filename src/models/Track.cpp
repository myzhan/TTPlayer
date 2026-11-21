#include "Track.h"

#include "RadioPresets.h"

#include <QFileInfo>
#include <QMutex>
#include <QMutexLocker>
#include <QUuid>

// 元数据跨线程读写（解析在工作线程、UI 在主线程）：一把全局锁足够——
// 访问都是取字符串/数值的微秒级操作，无需每字段独立原子量。
static QMutex gMetaMutex;

Track::Track(const QUrl &url) : d(std::make_shared<TrackData>()) {
    d->id = QUuid::createUuid();
    d->url = url;
    d->title = QFileInfo(url.toLocalFile()).completeBaseName();
    if (d->title.isEmpty()) d->title = url.fileName();
}

Track Track::fromRadio(const QUrl &url) {
    Track t(url);
    t.d->title = RadioURL::displayName(url); // host[:port]/尾段（别名/内置名由 RadioStations 上层覆盖）
    t.d->formatName = QStringLiteral("网络电台");
    t.d->channels = 2;
    return t;
}

Track Track::fromCueSegment(const QUrl &fileUrl, int number, const QUrl &sheetUrl, double start, double nextStart) {
    Track t(fileUrl);
    t.d->cueNumber = number;
    t.d->cueSheetUrl = sheetUrl;
    t.d->cueStart = start;
    t.d->cueNextStart = nextStart;
    t.d->title = QStringLiteral("%1").arg(number, 2, 10, QLatin1Char('0'));
    return t;
}

#define META_GET(field, type)                                                                                          \
    type Track::field() const {                                                                                        \
        QMutexLocker l(&gMetaMutex);                                                                                   \
        return d->field;                                                                                               \
    }

META_GET(title, QString)
META_GET(artist, QString)
META_GET(album, QString)
META_GET(formatName, QString)
META_GET(decodeProblem, QString)

// setter 的名字是 PascalCase，成员是 camelCase，逐个手写映射
#define META_SET(fn, member)                                                                                           \
    void Track::set##fn(const QString &v) {                                                                            \
        QMutexLocker l(&gMetaMutex);                                                                                   \
        d->member = v;                                                                                                 \
    }
META_SET(Title, title)
META_SET(Artist, artist)
META_SET(Album, album)
META_SET(FormatName, formatName)
META_SET(DecodeProblem, decodeProblem)

double Track::duration() const {
    QMutexLocker l(&gMetaMutex);
    return d->duration;
}
double Track::sampleRate() const {
    QMutexLocker l(&gMetaMutex);
    return d->sampleRate;
}
int Track::channels() const {
    QMutexLocker l(&gMetaMutex);
    return d->channels;
}
int Track::bitRateKbps() const {
    QMutexLocker l(&gMetaMutex);
    return d->bitRateKbps;
}

void Track::setMetadata(double duration_, double sampleRate_, int channels_, int bitRateKbps_) {
    QMutexLocker l(&gMetaMutex);
    d->duration = duration_;
    d->sampleRate = sampleRate_;
    d->channels = channels_;
    d->bitRateKbps = bitRateKbps_;
}

std::optional<ReplayGainTags> Track::replayGainTags() const {
    QMutexLocker l(&gMetaMutex);
    return d->replayGainTags;
}

void Track::setReplayGainTags(const ReplayGainTags &v) {
    QMutexLocker l(&gMetaMutex);
    d->replayGainTags = v;
}

bool Track::isRadio() const {
    const QString s = d->url.scheme();
    return s == QLatin1String("http") || s == QLatin1String("https");
}

QString Track::fileName() const {
    if (isRadio()) return d->title; // 电台没有文件名，标题就是 host/尾段
    return QFileInfo(d->url.toLocalFile()).completeBaseName();
}

QString Track::fileExtension() const {
    return QFileInfo(d->url.toLocalFile()).suffix().toUpper();
}

int64_t Track::fileSize() const {
    if (isRadio()) return 0; // 广播地址不是本地资源
    return QFileInfo(d->url.toLocalFile()).size();
}

QString Track::filterFormat() const {
    if (isRadio()) return QStringLiteral("电台");
    // 归档条目：外层是 .zip，把「ZIP」当音频格式没意义 → 按条目自己的后缀算
    const QString frag = d->url.fragment(QUrl::FullyDecoded);
    static const QLatin1String kEntry("archive-entry=");
    if (frag.startsWith(kEntry)) {
        const QString entry = frag.mid(int(kEntry.size()));
        const QString ext = QFileInfo(entry).suffix().toUpper();
        return ext.isEmpty() ? QStringLiteral("归档") : ext;
    }
    const QString ext = QFileInfo(d->url.path()).suffix().toUpper();
    return ext.isEmpty() ? QStringLiteral("其他") : ext;
}

QString Track::identityKey() const {
    // 电台必须用完整地址：两个台可能都叫 /stream，只看 path 会互相顶掉。
    // 归档条目（后续接 Archive 层）：path 只到外层归档文件，必须带 fragment。
    if (isRadio()) return d->url.toString();
    if (d->cueNumber > 0) return d->cueSheetUrl.toLocalFile() + QStringLiteral("#track=%1").arg(d->cueNumber);
    // 归档条目：path 只到外层归档文件，同档多条目必须靠 fragment 区分
    if (d->url.hasFragment()) return d->url.toString();
    return d->url.toLocalFile();
}
