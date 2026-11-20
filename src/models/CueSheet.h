#pragma once

// CUE 分轨表解析（对齐 Swift Models/CueSheet.swift）：整盘压成一份镜像（WAV/FLAC）时，
// 靠 .cue 里的 FILE/TRACK/INDEX 切出每一首在镜像中的起止秒。解析结果直接产 Track 分轨段
// （Track::fromCueSegment），交给既有解码/播放通路（loadAndPlay 会带 playStart/playEnd）。
// 编码回退：UTF-8（剥 BOM）→ Latin-1；GBK/Big5 需 Qt5Compat::QTextCodec，暂作 TODO。

#include "models/Track.h"

#include <QList>
#include <QString>
#include <QUrl>

struct CueTrackInfo {
    int number = 0;
    QString title;
    QString performer;
    QString album;
    QUrl fileUrl;          // 音频镜像绝对 URL
    QUrl sheetUrl;         // 来源 .cue（分轨身份键）
    double start = 0;
    double nextStart = -1; // <0 = 到镜像结尾
};

class CueSheet {
public:
    /// 从磁盘读并解析；无有效镜像返回空表
    static QList<CueTrackInfo> parseFile(const QString &cuePath);

    /// 解析文本（sheetUrl 用于相对路径基准与分轨表身份）
    static QList<CueTrackInfo> parse(const QString &text, const QUrl &sheetUrl);

    /// 把分轨信息转成可播放的 Track 段（title=「表演者 - 标题」，元数据留给后续探测）
    static QList<Track> toTracks(const QList<CueTrackInfo> &infos);

    /// MM:SS:FF（FF=1/75 秒 CD 帧）→ 秒；非法返回 -1
    static double parseCueTime(const QString &text);
};
