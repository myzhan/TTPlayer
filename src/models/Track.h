#pragma once

// 一首曲目（文件 + 元数据），对齐 Swift 版 Models/Track.swift 的核心语义。
// 共享引用语义：元数据异步解析后要能让所有持有者看到（QSharedData 式手动 impl）。
// CUE 分轨 / 归档条目 / ReplayGain 等字段随对应模块移植再补齐。

#include "models/ReplayGain.h"

#include <QString>
#include <QUrl>
#include <QUuid>
#include <QMetaType>
#include <memory>
#include <atomic>
#include <cstdint>
#include <optional>

struct TrackData {
    QUuid id;
    QUrl url;

    // 元数据（异步解析后填充；跨线程读写用 mutex 保护，UI 只在主线程取快照）
    QString title;
    QString artist;
    QString album;
    double duration = 0;        // 秒
    double sampleRate = 0;      // Hz
    int channels = 0;
    int bitRateKbps = 0;
    QString formatName;         // 从实际数据格式读出的编码名，不拿扩展名猜
    QString decodeProblem;      // 人话原因；空 = 能解
    bool missingOnDisk = false;

    // CUE 分轨来源（>=0 时生效）：一份镜像可对应多条曲目
    int cueNumber = 0;
    QUrl cueSheetUrl;
    double cueStart = 0;
    double cueNextStart = -1;   // <0 = 到镜像结尾

    // ReplayGain 标签（F02）：nullopt = 还没解析过；解析过但没标签 = has_value && isEmpty
    std::optional<ReplayGainTags> replayGainTags;
};

class Track {
public:
    Track() = default;
    explicit Track(const QUrl &url);
    static Track fromRadio(const QUrl &url);
    static Track fromCueSegment(const QUrl &fileUrl, int number, const QUrl &sheetUrl,
                                double start, double nextStart);

    // 值语义 + 引用共享（改元数据所有拷贝可见）
    Track(const Track &) = default;
    Track &operator=(const Track &) = default;

    const QUuid &id() const { return d->id; }
    const QUrl &url() const { return d->url; }
    bool isNull() const { return !d; }

    // 只读快照（主线程）；写入口全部集中在下方 setter，异步解析线程也走它们
    QString title() const;
    QString artist() const;
    QString album() const;
    double duration() const;
    double sampleRate() const;
    int channels() const;
    int bitRateKbps() const;
    QString formatName() const;
    QString decodeProblem() const;
    void setTitle(const QString &v);
    void setArtist(const QString &v);
    void setAlbum(const QString &v);
    void setMetadata(double duration, double sampleRate, int channels, int bitRateKbps);
    void setFormatName(const QString &v);
    void setDecodeProblem(const QString &v);

    /// ReplayGain 标签快照 / 写入口（与其它元数据同锁）
    std::optional<ReplayGainTags> replayGainTags() const;
    void setReplayGainTags(const ReplayGainTags &v);

    bool isRadio() const;
    QString fileName() const;
    QString fileExtension() const;
    int64_t fileSize() const;

    /// 格式筛选用的档位名（F05）：只看条目来路的后缀，不看异步解出的 formatName；
    /// 电台自成一档「电台」、归档条目按条目自己的后缀（对齐 Swift Track.filterFormat）
    QString filterFormat() const;

    /// 播放区间起点（秒）：CUE 轨从镜像的该偏移开始，普通轨为 0
    double playStart() const { return d->cueStart; }
    /// 播放区间终点（秒）；CUE 末轨为 -1，放到镜像结尾
    double playEnd() const { return d->cueNextStart; }
    bool isCueSegment() const { return d->cueNumber > 0; }
    int cueNumber() const { return d->cueNumber; }   // 0=非分轨
    /// 分轨来源的分轨表 URL（非 CUE 轨为空）：歌词整盘/分轨候选判别用
    QUrl cueSheetUrl() const { return d->cueSheetUrl; }

    /// 列表去重键：同一镜像的多条 CUE 轨 url 相同必须带轨号；
    /// 电台必须用完整地址；归档条目（后续）带 fragment
    QString identityKey() const;

    bool operator==(const Track &o) const { return d == o.d; }

private:
    std::shared_ptr<TrackData> d;
};

Q_DECLARE_METATYPE(Track)
