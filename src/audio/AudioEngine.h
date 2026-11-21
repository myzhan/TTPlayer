#pragma once

// 输出引擎：跨平台实现。
// 拓扑：decoder → [EQ] → fade → volume → 设备。
// Windows/Linux 设备 IO 走 SDL3；macOS 使用 HAL AudioUnit 按 CoreAudio UID 绑定，避免同名设备误选。
//
// R08 线程模型（关键，别再改回去）：
//   - 后台 producer 线程独占 Decoder，阻塞式拉 PCM 填「有界环」（唯一会碰网络/磁盘 IO 的地方）；
//   - SDL 回调只做纯 CPU 的短活：从环里取样本 → EQ/fade/volume/gain → 交织送设备，
//     环空（如断流）就出静音、位置不前进，绝不在回调里等 IO；
//   - UI 的 pause/stop/seek/取频谱只拿 m_mutex 做 O(1) 改状态，永不跨 IO 持锁；
//   - 换曲/停止先把旧解码器 requestCancel()（无锁，唤醒卡住的 read），再让 producer
//     自己丢弃在途样本——UI 不 join 网络线程，因此断流时 stop 也是秒回。
//   - m_gen 代际：producer 每次交付前核对解码器身份，旧曲的 EOF/样本不能污染新曲。

#include "decoder/Decoder.h"
#include "audio/EQ.h"
#include "audio/Spectrum.h"

#include <QPointer>
#include <QString>
#include <QStringList>
// SDL3 与系统安装布局一致：头文件在 include/SDL3/ 下。
#include <SDL3/SDL.h>
#ifdef __APPLE__
#include <AudioUnit/AudioUnit.h>
#endif

#include <condition_variable>
#include <memory>
#include <mutex>
#include <atomic>
#include <thread>
#include <vector>

class AudioEngine : public std::enable_shared_from_this<AudioEngine> {
public:
    static std::shared_ptr<AudioEngine> create();

    ~AudioEngine();

    /// 换曲：接管解码器（采样率不同会重开设备）；区间为 CUE 秒偏移（playEnd<0 = 到结尾）
    bool play(std::unique_ptr<Decoder> decoder, double playStart, double playEnd, bool autoPlay = true,
              double position = 0, float gain = 1, bool liveRadio = false);
    void pause();
    bool resume();
    void stop();
    bool isPlaying() const;

    /// 秒 → 可听帧号 seek（当前曲内定位；CUE 区间加自身偏移）
    bool seekSeconds(double sec);
    double positionSeconds();
    double durationSeconds();
    double bufferedSeconds() const {
        std::lock_guard<std::mutex> lk(m_mutex);
        return m_ringCount / m_sampleRate;
    }
    enum class RadioBufferState { Priming, Playing, Refilling };
    RadioBufferState radioBufferState() const {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_radioBufferState;
    }
    uint64_t underruns() const { return m_underruns.load(); }

    void setVolume(double v); // 0..1（mainMixer.outputVolume 对应物）
    double volume() const;
    /// ReplayGain 线性增益（当前曲）：在 fade*volume 之后再乘一层，1.0 = 不动。
    void setReplayGainLinear(float g);
    void prepareNext(std::unique_ptr<Decoder> decoder, double start, double end, float gain, const QString &key);
    void clearNext();
    std::function<void(const QString &)> onTransition;
    void setFadeTarget(double target, double seconds); // 1s 线性渐变（fadeNode 对应物）

    void setEQEnabled(bool on);
    void setEQGains(const std::array<double, Equalizer::kBands> &gains);
    void setEQPreamp(double db);
    double eqPreamp() const;
    std::array<double, Equalizer::kBands> eqGains() const;
    bool eqEnabled() const;
    /// 当前设备/解码采样率（预取判断同采样率用）
    double sampleRate() const;

    /// 输出设备：macOS 使用稳定 UID 与独立显示名；其他平台使用 SDL 的唯一设备名称。
    /// setOutputDevice 传空串回到系统默认；已开着设备会原地重开到新设备。
    static QStringList outputDevices();
    struct OutputDevice {
        QString id, name;
    };
    static QList<OutputDevice> outputDeviceDescriptors();
    QString actualOutputDevice() const { return m_actualOutput; }
    QString outputProblem() const { return m_outputProblem; }
    bool pollDevices();
    void setOutputDevice(const QString &uid);
    QString outputDevice() const;
    /// 频谱取窗（UI 线程）：与回调共拿 m_mutex（取窗必须拿锁，否则环形缓冲撕裂）
    bool spectrumBands(float *out);
    void setSpectrumEnabled(bool on) {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_spectrum.setEnabled(on);
    }

    /// 电平表取峰（UI 线程）：回调算好的本窗 L/R 峰值（0..1，已含 fade*volume*gain），
    /// 无锁原子读；衰减/峰保持由显示端做。
    void levels(float &l, float &r) const {
        l = m_peakL.load(std::memory_order_relaxed);
        r = m_peakR.load(std::memory_order_relaxed);
    }

    /// 自然播完（EOF 且非 stop）回调，主线程触发；Qt::QueuedConnection 槽
    std::function<void()> onFinished;

private:
    friend class RegressionTests;
    // Allocated only by selftest before playback. Copying never allocates in the callback.
    std::vector<float> m_testCapture;
    size_t m_testCaptured = 0;
    AudioEngine();
    /// SDL3 改用 push 模型：设备回调只告诉我们“还能收多少字节”，由本引擎自己填。
    static void sdlStreamCallback(void *userdata, SDL_AudioStream *stream, int additional, int total);
    void callback(float *out, int frames);

    bool openDevice(double sampleRate);
    bool openNativeDevice(double sampleRate);
    void pauseDevice(bool paused);
#ifdef __APPLE__
    static OSStatus nativeCallback(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32,
                                   AudioBufferList *);
#endif
    void adoptDeviceRate();
    void closeDevice();

    void startPump();
    void stopPump(); // 置 m_run=false + notify + join（析构用；此处可等，因为已先 cancel 过 IO）
    void pumpLoop();
    bool promoteNext(); // callback, under m_mutex; never performs IO
    struct Prepared {
        std::shared_ptr<Decoder> decoder;
        std::vector<float> l, r;
        double start = 0, end = -1;
        float gain = 1;
        QString key;
        int count = 0;
        bool ready = false;
        Prepared() : l(4096), r(4096) {}
    };
    std::shared_ptr<Prepared> m_next, m_retiredNext;
    std::shared_ptr<Decoder> m_retired;

    // 有界 PCM 环（仅 producer 写、callback 读，都在 m_mutex 下；O(1) 拷贝，不跨 IO）
    void ringClear();
    void resetPlaybackBuffer();
    bool m_liveRadio = false;
    RadioBufferState m_radioBufferState = RadioBufferState::Playing;
    static constexpr int kRadioCapacitySeconds = 12;
    static constexpr int kRadioPrerollSeconds = 2;
    int ringFree() const { return int(m_ringL.size()) - m_ringCount; }
    void ringPush(const float *l, const float *r, int n);
    int ringPop(float *l, float *r, int n); // 返回实际取到的帧数

    mutable std::mutex m_mutex;
    std::condition_variable m_cv; // producer 等「有活 / 有空间 / 被唤醒」

    // —— 仅 producer 线程触碰的解码器（shared_ptr 让 UI 能安全 requestCancel 旧实例）——
    std::shared_ptr<Decoder> m_decoder;
    std::thread m_pump;
    std::atomic<bool> m_run{false};

    // —— 共享状态（m_mutex 守护）——
    double m_playStart = 0, m_playEnd = -1; // CUE 区间（秒）
    int64_t m_endFrame = INT64_MAX;         // 绝对结束帧（含 CUE 尾；radio/未知=INT64_MAX）
    int64_t m_readPos = 0;                  // producer 解码游标（绝对可听帧）
    int64_t m_delivered = 0;                // callback 已交付到设备的可听帧（位置真相）
    int64_t m_totalFrames = 0;
    double m_deviceRate = 44100;
    double m_sampleRate = 44100;
    bool m_playing = false;         // 想不想出真声（play/resume 真，pause/stop 假）
    bool m_eos = false;             // producer 命中 EOF / 到区间尾
    bool m_finishPending = false;   // EOF 已上报，不重复触发
    std::atomic<uint64_t> m_gen{0}; // 装载代际（换曲/停止递增）

    std::vector<float> m_ringL, m_ringR; // 交织前的非交织立体声环
    int m_ringHead = 0, m_ringCount = 0;

    bool m_deviceOpen = false;
    bool m_starved = false;
    std::atomic<uint64_t> m_underruns{0};
    QString m_actualOutput, m_outputProblem, m_defaultOutput;
    /// 设备重开/销毁中：在途回调必须不拿锁直接出静音——SDL_CloseAudioDevice
    /// 等在途回调，而回调正拿着 m_mutex，主线程持锁等关设备会死锁
    std::atomic<bool> m_abortCb{false};
    /// 自检静音（TTPLAYER_SILENT_OUTPUT=1）：链上照常跑，只把送设备缓冲归零
    bool m_silentOutput = false;

    QByteArray m_outputDevice; // 指定输出设备（SDL 设备名 / mac UID）；空 = 跟随系统默认

    double m_volume = 0.8;
    float m_replayGainLinear = 1.0f;
    double m_eqPreamp = 0;
    double m_fadeCur = 1.0, m_fadeTarget = 1.0, m_fadeStep = 0.0; // 每帧增量

    Equalizer m_eq;
    SpectrumAnalyzer m_spectrum;

    SDL_AudioStream *m_stream = nullptr; // SDL_OpenAudioDeviceStream 的句柄（销毁即关设备）
    SDL_AudioDeviceID m_deviceId = 0;
    void *m_nativeOutput = nullptr;
    uint32_t m_boundDevice = 0;

    static constexpr int kPumpChunk = 2048;      // producer 每次解码帧数
    static constexpr int kSdlStageFrames = 8192; // SDL3 回调一次最多填的帧数（超出分块 Put）
    static constexpr int kRingCap = 131072;      // 环容量（帧）≈ 3s @44.1k；回调只在不足时出静音
    std::vector<float> m_cbL, m_cbR;             // callback 取窗暂存（仅回调线程用）
    std::vector<float> m_sdlOut;                 // SDL3 回调交织暂存（构造时分配，回调里绝不扩容）

    // 电平表峰值（回调写、UI 无锁读）：本窗交付样本的 |max|，含 fade*volume*gain
    std::atomic<float> m_peakL{0.0f}, m_peakR{0.0f};
};

using AudioEnginePtr = std::shared_ptr<AudioEngine>;
