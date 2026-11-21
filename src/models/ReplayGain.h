#pragma once

// ReplayGain。
// 标签缺失 / 写法非法 / 非有限值一律当没读到（optional 空），绝不当成 0 dB：
// 0 dB = 「有标签且不用动」，空 = 「没有标签」，两者的回退路径不同。

#include <QHash>
#include <QString>
#include <optional>

// 启用范围。默认关闭：响度均衡会抹平母带之间的相对响度，是「改用户听到的内容」的开关。
// rawValue 直接进 state.json（沿用既有枚举序 off=0 / track=1 / album=2），不能改编号。
enum class ReplayGainMode { Off = 0, Track = 1, Album = 2 };

// dB 文本：强制带符号（+6.0 / -6.0 / +0.0），即 "%+.1f"
namespace ReplayGainFormat {
inline QString signedDb(double v, int prec = 1) {
    return QStringLiteral("%1%2").arg(v < 0 ? QString() : QLatin1String("+")).arg(v, 0, 'f', prec);
}
}

// 一首曲子里读到的 ReplayGain 标签
struct ReplayGainTags {
    std::optional<double> trackGain; // dB
    std::optional<double> albumGain; // dB
    std::optional<double> trackPeak; // 满量程线性值
    std::optional<double> albumPeak; // 满量程线性值

    bool isEmpty() const { return !trackGain && !albumGain && !trackPeak && !albumPeak; }

    // 从容器 metadata（键需已小写）解析；非法写法一律留空
    static ReplayGainTags fromTags(const QHash<QString, QString> &tags);

    // 增益文本：-6.02 dB / +5.300dB / -0,5 dB 都要能读；非有限、超 ±30 dB 视为非法
    static std::optional<double> decibel(const QString &raw);
    // 峰值：正常线性满量程（0..1，偶尔 >1）；写成 dB 的换算回来。0/负/非有限/>10 非法
    static std::optional<double> peak(const QString &raw);
};

// 一首曲目在当前设置下的增益决定（同时给属性面板回答「加了多少、为什么」）
struct ReplayGainDecision {
    enum class Source { Off, Track, Album, AlbumToTrack, NoTag, Radio };

    Source source = Source::Off;
    double tagdB = 0;     // 实际采用那份标签的 dB
    double totaldB = 0;   // 标签 + 前置增益
    float linear = 1.0f;  // 真正施加的线性增益（峰值限幅可能压小）
    bool limited = false; // 峰值防削波是否真的动了手
    std::optional<double> peak;

    static ReplayGainDecision decide(const std::optional<ReplayGainTags> &tags, ReplayGainMode mode, double preamp,
                                     bool peakLimit, bool isRadio);

    QString sourceText() const;
    // 一行话：数值、来源、限幅结果都要说清
    QString summaryText() const;
};
