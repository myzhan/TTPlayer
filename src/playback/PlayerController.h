#pragma once

// 播放控制器：PlayQueue 是「接下来播什么」的唯一真相，浏览列表只管高亮。
// 装载失败自动跳过走私有 advanceToNext()，
// 绝不能调公开的 next()——那会把 consecutiveFailures 清零，整队列解不开时
// 「失败→跳下一条→又失败」同步递归到栈溢出。
//
// 本版补齐设置背后的后端能力：
// - 歌词时间校准（F10）：每曲各自的 offset，只进 state.json、绝不回写 .lrc
// - 睡眠定时器（F09）：按分钟倒计时 / 播完当前曲；到点前淡出最后 10 s（可关）
// - 无缝播放（F01）：预取下一曲解码器，切歌不换设备、消除开流延迟
// - 输出设备（F07）：SDL 设备枚举 + 指定设备打开（引擎侧）

#include "models/PlayQueue.h"
#include "models/ReplayGain.h"
#include "media/Lyric.h"
#include "audio/AudioEngine.h"
#include "audio/RadioQuality.h"
#include "Clock.h"
#include <QElapsedTimer>

#include <QObject>
#include <QTimer>
#include <QMap>
#include <QString>

#include <atomic>
#include <memory>
#include <mutex>

class RadioStreamSource;

// R08：电台开流（avformat_open_input + find_stream_info）可能因无响应/慢首包
// 长时间阻塞——必须搬离 UI 线程。job 在发起方与后台开流线之间共享：
// 发起方换曲/停止时置 cancelled 并对 src 调 cancel()（src 被 Decoder 与本 job
// 共享持有，不会悬垂），使卡住的 find_stream_info 尽快拿 EOF 返回。
struct RadioOpenJob {
    std::atomic<bool> cancelled{false};
    std::atomic<bool> finished{false};
    std::mutex mtx;
    std::shared_ptr<RadioStreamSource> src; // 后台线程建好后发布，供发起方取消
};

class PlayerController : public QObject {
    Q_OBJECT
public:
    explicit PlayerController(AudioEnginePtr engine, QObject *parent = nullptr);
    ~PlayerController() override;

    // 浏览列表（当前页）：双击建立播放上下文
    const QList<Track> &tracks() const { return m_tracks; }
    void setTracks(const QList<Track> &tracks);
    void replaceTrackReferences(const QHash<QString, Track> &replacements);

    PlayQueue &queue() { return m_queue; }
    PlayMode mode() const { return m_mode; }
    void setMode(PlayMode m);

    Track currentTrack() const { return m_queue.currentTrack(); }

    /// 双击第 row 行 = 开一段新的播放上下文并播出
    void playRowAt(int row);
    void togglePlay();
    void next(); // 手动下一首
    void prev(); // 上一首（>3s 先回本机头）
    void seekTo(double sec);
    void stop();

    // MARK: 待播队列（F03）。都不打断当前曲；没在播时只入表，按播放/双击再开播。
    int enqueueNext(const QList<Track> &tracks);  // 「下一首播放」：插到当前之后
    int enqueueLater(const QList<Track> &tracks); // 「稍后播放」：追加到尾部
    void removeQueued(const QSet<QUuid> &ids);    // 移走待播条目（正在播的形列外）
    void dropTracks(const QSet<QString> &keys);
    void clearPendingQueue();                      // 清空待播：当前曲继续播完就收手
    bool moveQueued(const QUuid &id, int index);   // 拖动调整待播次序（落点夹在待播区间）
    bool reorderQueued(const QList<QUuid> &order); // 一次性提交整个待播段重排
    void playQueued(const QUuid &id);              // 队列面板双击某条：只挪游标不重建上下文

    // R03 现场恢复：重建队列上下文/游标/历史，装载当前曲并定位。
    // autoPlay=false 停在原位（恢复现场但不响），true 才开声；模式由调用方先 setMode。
    // 返回是否成功落到当前曲（失败时上层退化为普通恢复，不擅自推进整条队列）。
    bool restoreResume(const QList<QueueItem> &items, std::optional<int> cursor, const QList<int> &historyIndexes,
                       double position, bool autoPlay);

    bool isPlaying() const;
    QString radioStatusText() const { return m_radioStatus; }
    QString radioNowPlaying() const { return m_radioTitle; }
    QString radioQualityText() const { return m_radioQuality.summary(m_radioClock.elapsed() / 1000.0); }
    void retryRadio();
    static int retryDelay(int attempt) { return attempt == 0 ? 2 : attempt == 1 ? 4 : 8; }
    double position() const { return m_positionCache; }
    double duration() const;

    // MARK: 响度均衡 ReplayGain（F02）。默认关闭。
    ReplayGainMode replayGainMode() const { return m_rgMode; }
    double replayGainPreamp() const { return m_rgPreamp; }
    bool replayGainPeakLimit() const { return m_rgPeakLimit; }
    void setReplayGainMode(ReplayGainMode m);
    void setReplayGainPreamp(double db); // 钉到 -12…+12
    void setReplayGainPeakLimit(bool on);
    /// 当前曲在某设置下的增益决定
    ReplayGainDecision replayGainDecision(const Track &track) const;
    /// 属性面板「响度均衡」那一行
    QString replayGainStatusText(const Track &track, bool applied) const;

    // MARK: 歌词与时间校准（F10）。控制器持有当前歌词，显示与查行只认 alignedLyricTime。
    const Lyric &currentLyric() const { return m_lyric; }
    /// 播放位置（段内秒）→ 歌词时间轴：整盘词加段起点、用户校准减掉
    double alignedLyricTime(double segmentTime) const;

    static constexpr double kLyricShiftStep = 0.5;   // 一次 ±0.5 秒
    static constexpr double kLyricShiftLimit = 30.0; // 上下限 ±30 秒

    double lyricShift() const; // 当前曲校准量（秒，正 = 延后）
    bool lyricShiftApplies() const { return lyricShiftProblem().isEmpty(); }
    QString lyricShiftProblem() const;     // 不生效原因；可校准返回空串
    QString lyricShiftText() const;        // 未校准 / 延后 X.X 秒 / 提前 X.X 秒
    QString lyricShiftDetail() const;      // 含文件自带 offset 与「存哪儿」
    QString nudgeLyricShift(double delta); // ±步进，返回给用户的一句话
    QString resetLyricShift();             // 归零当前曲
    QString setLyricShift(double seconds); // 直接设当前曲（自检/自定义）

    const QMap<QString, double> &lyricShiftTable() const { return m_lyricShifts; }
    void setLyricShiftTable(const QMap<QString, double> &t); // 从存档接回

    // MARK: 无缝播放（F01）。开关变更即时生效，下一处衔接即按新值决定要不要预取。
    bool gaplessEnabled() const { return m_gapless; }
    void setGaplessEnabled(bool on);

    // MARK: 睡眠定时器（F09）。计划不入档，只有「要不要淡出」是设置。
    enum class SleepPlan { Off, Countdown, AfterTrack };
    void setSleepMinutes(int minutes); // 按分钟倒计时（<=0 视作取消）
    void setSleepAfterCurrentTrack();  // 播完当前曲就停
    void cancelSleepTimer();
    SleepPlan sleepPlan() const { return m_sleepPlan; }
    bool sleepArmed() const { return m_sleepPlan != SleepPlan::Off; }
    int sleepRemainingSeconds() const; // Countdown 剩余；其它 0
    QString sleepStatusText() const;   // 剩 mm:ss / 播完当前曲后停止 / 空
    bool sleepFadeEnabled() const { return m_sleepFade; }
    void setSleepFadeEnabled(bool on);
    static constexpr double kSleepFadeSeconds = 10.0;

    // MARK: 输出设备（F07）。转发给引擎；空 UID = 跟随系统默认。
    void setOutputDevice(const QString &uid);
    QString outputDevice() const;

signals:
    void trackChanged();
    void playbackStateChanged();
    void positionTicked(double pos, double duration);
    void listChanged();
    void modeChanged();
    void replayGainChanged();
    void lyricShiftChanged();
    void sleepChanged();
    void queueChanged(); // 排队 / 移除 / 重排 / 换游标：驱动待播队列面板刷新

private:
    friend class RegressionTests;
    bool loadAndPlay(const Track &track);
    /// 带预取解码器的装载（F01 无缝）：prepared 非空则直接用它，不再现开流
    bool loadAndPlay(const Track &track, std::unique_ptr<Decoder> prepared);
    void onTrackFinished();           // EOF 自然推进（含失败跳）
    const QueueItem *advanceToNext(); // 失败路径专用：不清失败计数
    void beginContextAndPlay(int row);
    void applyReplayGainForCurrent(); // 设置变更后重算当前曲增益

    void loadLyricForCurrent(); // 换曲时重解同名 .lrc
    void schedulePrefetch();    // 无缝：在当前曲已排进设备后预取下一曲解码器
    static std::unique_ptr<Decoder>
    openDecoderFor(const Track &track, std::shared_ptr<std::atomic<bool>> cancel = {}); // 文件/归档/电台统一开流

    void refreshPrefetch(); // 队列变了：有当前曲就重算预取，否则丢弃旧预取

    // R08：电台异步开流——不在 UI 线程阻塞等网络；token 不匹配的晚到结果直接丢弃。
    void startLocalAsync(const Track &track, bool autoPlay, double position, bool restoring);
    void reapWorkers();
    void cancelPrefetch();
    void startRadioAsync(const Track &track, bool autoPlay);
    void onRadioOpened(uint64_t token, Track track, std::unique_ptr<Decoder> dec, bool autoPlay);
    void abortPendingOpen(); // 换曲/停止：取消在途开流并作废其 token
    void scheduleRadioRetry();

    void sleepTick();
    void fireSleep(const QString &reason);
    void applySleepFade();

    AudioEnginePtr m_engine;
    PlayQueue m_queue;
    QList<Track> m_tracks;
    PlayMode m_mode = PlayMode::Order;
    QTimer m_tick; // 250ms 位置回显
    double m_positionCache = 0;
    int m_consecutiveFailures = 0;

    ReplayGainMode m_rgMode = ReplayGainMode::Off;
    double m_rgPreamp = 0; // dB，-12…+12
    bool m_rgPeakLimit = true;

    Lyric m_lyric;                       // 当前曲歌词（含 mirrorShift）
    QMap<QString, double> m_lyricShifts; // identityKey → 校准秒

    bool m_gapless = true;
    std::unique_ptr<Decoder> m_prefetchDecoder; // 已开好的下一曲
    QString m_prefetchKey;                      // 对应的 track identityKey
    double m_prefetchStart = 0, m_prefetchEnd = -1;

    uint64_t m_prefetchToken = 0;
    std::shared_ptr<RadioOpenJob> m_prefetchJob;
    uint64_t m_openToken = 0; // 当前开流派号（仅主线程读写）
    std::vector<std::pair<std::thread, std::shared_ptr<RadioOpenJob>>> m_openWorkers;
    double m_restorePosition = 0;
    bool m_restorePending = false;
    RadioQuality m_radioQuality;
    QElapsedTimer m_radioClock;
    uint64_t m_seenUnderruns = 0;
    bool m_loadWantsPlay = true;
    bool m_radioWantsPlay = false;
    int m_radioRetries = 0;
    QString m_radioStatus = QStringLiteral("未连接"), m_radioTitle;
    QString m_radioSessionKey;
    std::shared_ptr<RadioOpenJob> m_openJob; // 在途电台开流（仅主线程访问）
    bool m_resumeAutoPlay = true;            // 下一次装载是否立刻出声（restoreResume 消费）

    SleepPlan m_sleepPlan = SleepPlan::Off;
    QTimer m_sleepTick; // 0.5s 心跳
    std::function<qint64()> m_sleepClock = continuousMilliseconds;
    int m_sleepMinutes = 0;
    qint64 m_sleepDeadlineMs = 0; // Countdown 到点的墙钟毫秒
    QString m_sleepTrackId;       // AfterTrack 绑定的队列条目 id
    bool m_sleepFade = true;
    bool m_sleepFading = false; // 已进入淡出窗口（只推一次 fade）
};
