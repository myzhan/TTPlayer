#pragma once

// LRC 歌词解析与查找。支持一行多时间标签、
// [mm:ss] / [mm:ss.xx] / [mm:ss:xxx]、全局 [offset:±毫秒]（正值=歌词提前，解析时
// 已算进每行 time，显示不再二次叠加）。二分查当前行。
// 查找优先级：可用内嵌歌词 → 同名 .lrc → 同目录归一化唯一命中（「01 - 歌名」↔「歌名」），拿不准
// 就算没歌词（宁缺毋滥）。CUE 轨命中整盘那份（与镜像/分轨表同名）时 mirrorShift=
// 本段起点，把「段内第几秒」对齐到整盘绝对时间轴；按轨名命中那份从 0 计时，不加。
// 编码：剥 BOM → 严格 UTF-8（无替换字符）→ GB18030（需 Qt6 Core5Compat，可用时）→ Latin-1。

#include "models/Track.h"

#include <QHash>
#include <QString>
#include <vector>

struct LyricLine {
    double time = 0; // 秒（已含 offset）
    QString text;
};

class Lyric {
public:
    bool isEmpty() const { return m_lines.empty() && m_plainText.isEmpty(); }
    bool isTimed() const { return !m_lines.empty(); }
    const QString &plainText() const { return m_plainText; }
    const std::vector<LyricLine> &lines() const { return m_lines; }
    double fileOffset() const { return m_fileOffset; }

    /// 本段起点（秒）：CUE 轨配整盘词时要给播放位置补上的量，普通轨为 0
    double mirrorShift() const { return m_mirrorShift; }
    void setMirrorShift(double s) { m_mirrorShift = s; }

    /// 把「本段内的播放位置」换成歌词自己的时间轴：整盘词加段起点，
    /// 用户校准（正值 = 歌词延后显示）减掉。显示与查行只认这一个换算
    double alignedTime(double segmentTime, double delay) const { return segmentTime + m_mirrorShift - delay; }

    /// 当前时间对应的行下标；早于首行返回 -1（显示「纯音乐/无歌词」）
    int lineIndexAt(double t) const;

    static Lyric parse(const QString &text);
    /// 从 FFmpeg 标签选取歌词：支持 lyrics / lyrics-*（MP3 USLT）及常见别名，时间词优先。
    static QString embeddedText(const QHash<QString, QString> &tags);
    /// 解析内嵌文本；带 LRC 时间标签时同步，否则保留可阅读的纯文本，不虚构时间。
    static Lyric parseEmbedded(const QString &text);
    /// 内嵌优先，缺失/空白时回退同名或同目录唯一命中的外置歌词；找不到返回空 Lyric。
    /// CUE 整盘词场景会自行设好 mirrorShift，调用方不再覆写
    static Lyric loadForTrack(const Track &track);

private:
    std::vector<LyricLine> m_lines;
    QString m_plainText;
    double m_fileOffset = 0;
    double m_mirrorShift = 0;

    // MARK: 查找辅助（均只在主线程调用，与 loadLyricForCurrent 同线程）
    /// 归一化文件名：去开头音轨号，只留字母/数字/汉字（空格/横杠/下划线不参与比较）
    static QString normalized(const QString &name);
    /// 候选 .lrc 绝对路径（同名优先，否则同目录唯一模糊命中）；无则空
    static QStringList candidateFiles(const QString &audioPath);
    /// 同目录 .lrc 索引（按目录 mtime 缓存，一个目录只列一次），键=归一化名
    static const QHash<QString, QString> &lrcIndexIn(const QString &dir);
    /// 这份 .lrc 是不是「整盘一份」（与镜像或分轨表同名），而非按轨名找到的
    static bool isAlbumWide(const QString &lrcPath, const Track &track);
    /// 按编码回退读一份 .lrc 并解析；解不出带时间的行返回空
    static Lyric parseFile(const QString &path);
};
