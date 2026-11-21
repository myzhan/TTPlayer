#pragma once
#include <functional>

// 电台流（QtNetwork 自管理，跨平台）：QNetworkAccessManager 拉 http(s) 流，在一个真正的
// QThread（自带事件循环与网络事件派发）里经 readyRead 信号持续读，喂进环形缓冲；Decoder
// 的自定义 AVIOContext（StreamSource::read）从音频线程取字节。三者互不阻塞：
// 工作线程填缓冲、音频线程阻塞等字节、主线程事件循环照常跑 UI。
//
// 注意：不能用裸 std::thread 跑 QNetworkAccessManager——该线程没有 Qt 事件派发器，
// readyRead/waitForReadyRead 都拿不到数据（实测解码线程永久卡在等字节上）。必须 QThread。
//
// 不可定位（live 流），seekable()=false；电台不做时长/进度、也不做 ReplayGain。
// 沿用「自定义 AVIO 喂同一条 FFmpegDecoder」的思路（同归档通路）。

#include "decoder/Decoder.h"

#include <QString>
#include <QUrl>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>

class QThread;
class RadioFetcher;

class RadioStreamSource : public StreamSource {
public:
    explicit RadioStreamSource(const QUrl &url);
    ~RadioStreamSource() override;
    RadioStreamSource(const RadioStreamSource &) = delete;
    RadioStreamSource &operator=(const RadioStreamSource &) = delete;

    /// 起工作线程发起请求；不阻塞，连接失败以 EOF 反映到后续 read()
    void start();

    int64_t read(uint8_t *buf, int buf_size) override; // 取字节（无数据时阻塞等待）
    bool seekable() const override { return false; }

    /// 让工作线程收尾（析构调用）
    void stop();

    /// R08 可取消 IO：置停位 + 唤醒卡在等字节/背压的 read/push，不 join、不回收线程
    /// （join 留给 stop()/析构）—— 供引擎在正阻塞于 read() 时跨线程即时放开回调。
    void cancel() override;

    // —— 供 RadioFetcher（工作线程）回调 ——
    void push(const char *data, qint64 len); // 追加字节，缓冲满则阻塞等消费侧腾空间
    void markDone();                         // 收尾：不再产数据，读侧见 EOF
    bool stopRequested() const { return m_stopReq.load(); }
    std::function<void(const QString &)> onMetadata;
    std::function<void(int, const QString &)> onError;

private:
    QUrl m_url;
    QThread *m_thread = nullptr;
    RadioFetcher *m_fetcher = nullptr;

    std::mutex m_mtx;
    std::condition_variable m_cv;
    std::deque<uint8_t> m_buf;          // 待交付字节
    bool m_done = false;                // 收尾（锁内读写）
    std::atomic<bool> m_stopReq{false}; // 请求工作线程退出（跨线程读）

    // 环形缓冲上限：拉得比消费快时让工作线程阻塞等空格，避免无限吃内存
    static constexpr size_t kCapBytes = size_t{4} * 1024 * 1024;
};
