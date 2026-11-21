#pragma once

// 统一 FFmpeg 文件解码器：任意容器 + 任意音频编码 → 立体声 Float32 非交织 PCM。
// 解码语义（含无缝基准校准）：
// - 可听基准只能从「真正交出来的第一帧的 pts」拿，不能拿哪个报上来的延迟数；
// - seek 时必须冷启动重建 swr（滤波器记忆会让重复定位漂移）；
// - pkt_timebase 必须设，否则 mp3 丢 priming 后时间戳不挪，帧号两头偏差。
// 约束沿用：不整曲进内存、不在音频线程做重活、能随机定位。

#include <QString>
#include <QHash>
#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

extern "C" {
#include <libavutil/rational.h>
#include <libavutil/samplefmt.h>
}
struct AVFormatContext;
struct AVCodecContext;
struct SwrContext;
struct AVPacket;
struct AVFrame;
struct AVIOContext;

// 字节流来源：电台（QtNetwork 拉流，不可定位）与归档条目（libarchive，部分可定位）
// 都把它喂给同一条 Decoder——对应 ArchiveIO / RadioStream 的自定义 AVIOContext。
// read 返回实际读到的字节数（0=EOF，负数=已映射的 AVERROR）；不可 seek 时 seekable()=false。
class StreamSource {
public:
    virtual ~StreamSource() = default;
    virtual int64_t read(uint8_t *buf, int buf_size) = 0;
    virtual bool seekable() const { return false; }
    virtual int64_t seek(int64_t /*offset*/, int /*whence*/) { return -1; }
    /// 可取消 IO（R08）：让阻塞在 read() 里的取流尽快返回，不 join、不释放 this。
    /// 电台（网络可能无限阻塞）覆写它置停位 + 唤醒 CV；本地/归档顺序读默认空实现。
    virtual void cancel() {}
};

class Decoder {
public:
    struct GaplessInfo {
        int encoderDelay = 0; // 解码器报的 priming（FFmpeg 已自己丢掉）
        int trailingPadding = 0;
        int seekPreroll = 0;
        int streamDelay = 0; // 流参数侧报的延迟（mp3 是 0、aac 是 1024）
        int streamTrailing = 0;
        int64_t firstOutPTS = -1; // 首帧实测 pts（输出时基），即可听基准
    };

    /// 打开失败抛不出来（C++ 无异常习惯这里用工厂 + error()）
    static std::unique_ptr<Decoder> openFile(const QString &path, std::shared_ptr<std::atomic<bool>> cancel = {});
    /// 从自定义字节流打开（电台 / 归档条目）；displayName 仅用于错误日志。
    /// 传 shared_ptr：电台可在开流（find_stream_info）被搬到后台线程后，由发起方持有
    /// 同一份引用随时 cancel()（唤醒卡住的 IO）而不会与 Decoder 争所有权 / 悬垂。
    static std::unique_ptr<Decoder> openStream(std::shared_ptr<StreamSource> src,
                                               const QString &displayName = QString(),
                                               std::shared_ptr<std::atomic<bool>> cancel = {});

    ~Decoder();
    Decoder(const Decoder &) = delete;
    Decoder &operator=(const Decoder &) = delete;

    double sampleRate() const { return m_sampleRate; }
    int bitRateKbps() const { return m_bitRateKbps; } // 真实码率，取不到为 0
    int channelCount() const { return m_inputChannels; }
    int64_t totalFrames() const { return m_totalFrames; }
    const QString &formatName() const { return m_formatName; }
    const QString &error() const { return m_error; }
    const GaplessInfo &gapless() const { return m_gapless; }
    /// 容器级 metadata（键已统一小写，涵盖 ReplayGain 标签等各家写法）
    const QHash<QString, QString> &tags() const { return m_tags; }
    /// 可听第 0 帧落在哪个 pts 坐标上（校准后的真实基准）
    int64_t audibleBase() const { return m_ptsBase; }

    /// 读 need 帧到非交织立体声缓冲；位置不连续时内部自动 seek。返回实际帧数（0=EOF）
    int read(float *outL, float *outR, int need, int64_t fromPos);

    /// R08：请求取消当前/后续 IO。只翻原子标志 + 通知取流源，不碰任何引擎级锁、
    /// 不重assign m_streamSrc —— 因此可在音频回调正阻塞在 read() 时由其它线程安全调用，
    /// 让「先使阻塞 IO 可取消、再回收」成为可能（打破 stop↔回调互等死锁）。
    void requestCancel();
    bool isCancelled() const { return m_abort.load() || (m_externalCancel && m_externalCancel->load()); }

    /// 顺序解到底数产出帧数（只有自检付这笔钱）
    int64_t countProducedFrames();
    bool resampleTo(int rate);

private:
    friend class RegressionTests;
    Decoder() = default;
    bool init(const QString &path);
    bool initStream(std::shared_ptr<StreamSource> src);
    bool finishInit();                    // find_stream_info 之后的共用收尾（两入口都走）
    bool openFormat(const QString *path); // 文件路径与自定义 pb 两条入口共用的 avformat_open_input
    static int readPacket(void *opaque, uint8_t *buf, int buf_size);
    static int64_t seekPacket(void *opaque, int64_t offset, int whence);
    static int interruptCb(void *opaque); // FFmpeg 中断回调：m_abort 置位即 bail

    void primeAudibleBase();
    void configureSwr();
    void seek(int64_t frame);
    bool fillStage();
    bool feedOnePacket();
    bool emitFrame(AVFrame *frame);
    bool drainSwrTail();
    int convert(const uint8_t **inData, int inCount);
    void shiftStageLeft(int drop);
    void cleanup();

    AVFormatContext *m_fmt = nullptr;
    int m_inputChannels = 0;
    AVCodecContext *m_cc = nullptr;
    SwrContext *m_swr = nullptr;
    AVPacket *m_packet = nullptr;
    AVFrame *m_frame = nullptr;
    // 自定义 AVIO（电台/归档）：非空表示走 StreamSource 通路
    AVIOContext *m_pb = nullptr;
    uint8_t *m_ioBuffer = nullptr;
    std::shared_ptr<StreamSource> m_streamSrc;
    bool forwardOnly() const { return m_streamSrc && !m_streamSrc->seekable(); }
    int32_t m_streamIndex = -1;
    AVRational m_timeBase{1, 1};
    AVRational m_outTB{1, 1};
    int32_t m_outRate = 0;
    int32_t m_swrInRate = 0;
    AVSampleFormat m_swrInFormat = AV_SAMPLE_FMT_NONE;

    double m_sampleRate = 0;
    int m_bitRateKbps = 0;
    int64_t m_totalFrames = 0;
    QString m_formatName;
    QString m_error;
    GaplessInfo m_gapless;
    QHash<QString, QString> m_tags; // init 时从 m_fmt->metadata 快照

    static constexpr int kStageCap = 16384;
    std::vector<float> m_stageL, m_stageR;
    int m_stageCount = 0;
    int m_stageCursor = 0;

    int64_t m_nextOutPos = 0;         // 下次 read 的交付位置：只按实际交付的 PCM 帧数推进
    int64_t m_runningOutPos = 0;      // 重采样输出时间轴，包含 seek 时丢弃的样本
    bool m_outputPosAnchored = false; // 冷启动后只用第一帧 PTS 定位一次，之后按实际产出计数
    int64_t m_ptsBase = 0;       // 可听第 0 帧的 pts 坐标
    bool m_ptsCalibrated = false;
    int64_t m_discardUntil = -1; // seek 后要丢到的目标帧（-1 = 无需丢弃）
    bool m_flushSent = false;

    std::shared_ptr<std::atomic<bool>> m_externalCancel;
    std::atomic<bool> m_abort{false}; // R08：取消 IO（跨线程读，FFmpeg 中断回调 + read 循环判）

    static constexpr int64_t kNoPTS = INT64_MIN;
};
