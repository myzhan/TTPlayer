#include "ReplayGain.h"

#include <QStringList>
#include <algorithm>
#include <cmath>

namespace {

QString trimmedLower(QString s) {
    s = s.toLower();
    s.remove(QLatin1String("db"));
    s.replace(QLatin1Char(','), QLatin1Char('.'));
    s = s.trimmed();
    s.remove(QLatin1Char('+'));
    return s;
}

} // namespace

std::optional<double> ReplayGainTags::decibel(const QString &raw) {
    if (raw.isEmpty()) return std::nullopt;
    const QString text = trimmedLower(raw);
    if (text.isEmpty()) return std::nullopt;
    bool ok = false;
    const double v = text.toDouble(&ok);
    if (!ok || !std::isfinite(v) || std::abs(v) > 30) return std::nullopt;
    return v;
}

std::optional<double> ReplayGainTags::peak(const QString &raw) {
    if (raw.isEmpty()) return std::nullopt;
    QString text = raw.toLower().trimmed();
    if (text.endsWith(QLatin1String("db"))) {
        auto v = decibel(text.left(text.size() - 2));
        if (!v) return std::nullopt;
        const double linear = std::pow(10.0, *v / 20.0);
        if (!std::isfinite(linear) || linear <= 0 || linear > 10) return std::nullopt;
        return linear;
    }
    text.replace(QLatin1Char(','), QLatin1Char('.'));
    bool ok = false;
    const double v = text.toDouble(&ok);
    if (!ok || !std::isfinite(v) || v <= 0 || v > 10) return std::nullopt;
    return v;
}

ReplayGainTags ReplayGainTags::fromTags(const QHash<QString, QString> &tags) {
    ReplayGainTags t;
    t.trackGain = decibel(tags.value(QLatin1String("replaygain_track_gain")));
    t.albumGain = decibel(tags.value(QLatin1String("replaygain_album_gain")));
    t.trackPeak = peak(tags.value(QLatin1String("replaygain_track_peak")));
    t.albumPeak = peak(tags.value(QLatin1String("replaygain_album_peak")));
    return t;
}

ReplayGainDecision ReplayGainDecision::decide(const std::optional<ReplayGainTags> &tagsOpt,
                                              ReplayGainMode mode, double preamp,
                                              bool peakLimit, bool isRadio) {
    ReplayGainDecision d;
    if (isRadio) {
        d.source = Source::Radio;   // 电台既不加标签增益，也不加 preamp
        return d;
    }
    if (mode == ReplayGainMode::Off) {
        d.source = Source::Off;
        return d;
    }
    const ReplayGainTags t = tagsOpt.value_or(ReplayGainTags {});
    std::optional<double> gain;
    std::optional<double> pk;
    if (mode == ReplayGainMode::Track) {
        gain = t.trackGain;
        pk = t.trackPeak ? t.trackPeak : t.albumPeak;
        d.source = t.trackGain ? Source::Track : Source::NoTag;
    } else { // Album
        if (t.albumGain) {
            gain = t.albumGain;
            pk = t.albumPeak ? t.albumPeak : t.trackPeak;
            d.source = Source::Album;
        } else {
            gain = t.trackGain;
            pk = t.trackPeak ? t.trackPeak : t.albumPeak;
            d.source = t.trackGain ? Source::AlbumToTrack : Source::NoTag;
        }
    }
    // 没有有效 Gain 标签就是「不动音量」：preamp 是标签链路上的偏移量，没标签可偏移时
    // 单独加上去等于拿均衡去推一首没测过的曲子，与文案「不动音量」自相矛盾
    if (!gain) {
        d.source = Source::NoTag;
        return d;
    }
    d.tagdB = *gain;
    d.totaldB = *gain + preamp;
    float lin = float(std::pow(10.0, d.totaldB / 20.0));
    if (peakLimit && pk && lin > float(1.0 / *pk)) {
        lin = float(1.0 / *pk);
        d.limited = true;
    }
    d.linear = lin;
    d.peak = pk;
    return d;
}

QString ReplayGainDecision::sourceText() const {
    switch (source) {
    case Source::Off: return QStringLiteral("已关闭");
    case Source::Track: return QStringLiteral("按曲目");
    case Source::Album: return QStringLiteral("按专辑");
    case Source::AlbumToTrack: return QStringLiteral("按专辑（专辑标签缺失，退回曲目）");
    case Source::NoTag: return QStringLiteral("曲子里没有 ReplayGain 标签（不动音量）");
    case Source::Radio: return QStringLiteral("电台不做响度均衡（也不加前置增益）");
    }
    return {};
}

QString ReplayGainDecision::summaryText() const {
    QString s = sourceText();
    if (source != Source::Off && source != Source::Radio && source != Source::NoTag)
        s += QStringLiteral(" %1 dB").arg(ReplayGainFormat::signedDb(totaldB, 1));
    if (limited) {
        s += QStringLiteral("（峰值 %1 已把增益压到 %2 dB）")
                 .arg(peak.value_or(0), 0, 'f', 3)
                 .arg(ReplayGainFormat::signedDb(20 * std::log10(std::max(double(linear), 1e-9)), 1));
    }
    return s;
}
