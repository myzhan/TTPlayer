#include "RadioStream.h"

#include "media/FFmpeg.h"

#include <QByteArray>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QThread>
#include <QTimer>
#include <QRegularExpression>

#include <algorithm>

// 工作线程里的取流器：QNetworkAccessManager 在本线程（QThread）创建，
// readyRead/finished 经本线程事件循环派发；字节交给 RadioStreamSource 的环形缓冲。
class RadioFetcher : public QObject {
    Q_OBJECT
public:
    RadioFetcher(QUrl url, RadioStreamSource *sink) : m_url(std::move(url)), m_sink(sink) {}

public slots:
    void run() {
        auto *nam = new QNetworkAccessManager(this);
        nam->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
        QNetworkRequest req(m_url);
        req.setRawHeader("Icy-MetaData", "1");
        req.setTransferTimeout(15000);
        req.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("TTPlayer/1.0"));
        m_reply = nam->get(req);
        connect(m_reply, &QNetworkReply::metaDataChanged, this, [this] {
            m_interval = m_reply->rawHeader("icy-metaint").toInt();
            m_audioLeft = m_interval;
        });

        connect(m_reply, &QIODevice::readyRead, this, [this] {
            const QByteArray c = m_reply->readAll();
            consume(c);
        });
        connect(m_reply, &QNetworkReply::finished, this, [this] {
            const int status = m_reply ? m_reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() : 0;
            if (m_reply && m_reply->error() != QNetworkReply::NoError && m_sink->onError)
                m_sink->onError(status, m_reply->errorString());
            if (m_reply) {
                const QByteArray c = m_reply->readAll();
                consume(c);
            }
            m_sink->markDone();
            QThread::currentThread()->quit();
        });

        // 停止看门狗：另一线程置 m_stopReq 后，这里掐掉请求并收线程
        m_timer = new QTimer(this);
        connect(m_timer, &QTimer::timeout, this, [this] {
            if (m_sink->stopRequested()) {
                if (m_reply) m_reply->abort();
                m_sink->markDone();
                QThread::currentThread()->quit();
            }
        });
        m_timer->start(100);
    }

private:
    void consume(const QByteArray &data) {
        if (m_interval <= 0) {
            if (!data.isEmpty()) m_sink->push(data.constData(), data.size());
            return;
        }
        int offset = 0;
        while (offset < data.size() && !m_sink->stopRequested()) {
            if (m_audioLeft > 0) {
                const int n = std::min(m_audioLeft, int(data.size()) - offset);
                m_sink->push(data.constData() + offset, n);
                offset += n;
                m_audioLeft -= n;
            } else if (m_metaLeft < 0) {
                m_metaLeft = uint8_t(data[offset++]) * 16;
                m_metadata.clear();
                if (m_metaLeft == 0) {
                    m_audioLeft = m_interval;
                    m_metaLeft = -1;
                }
            } else {
                const int n = std::min(m_metaLeft, int(data.size()) - offset);
                m_metadata.append(data.constData() + offset, n);
                offset += n;
                m_metaLeft -= n;
                if (!m_metaLeft) {
                    static const QRegularExpression title(QStringLiteral("StreamTitle='(.*?)';"));
                    QString text = QString::fromUtf8(m_metadata);
                    if (text.contains(QChar::ReplacementCharacter)) text = QString::fromLatin1(m_metadata);
                    const auto match = title.match(text);
                    if (match.hasMatch() && m_sink->onMetadata) m_sink->onMetadata(match.captured(1));
                    m_audioLeft = m_interval;
                    m_metaLeft = -1;
                }
            }
        }
    }
    int m_interval = 0, m_audioLeft = 0, m_metaLeft = -1;
    QByteArray m_metadata;
    QUrl m_url;
    RadioStreamSource *m_sink;
    QNetworkReply *m_reply = nullptr;
    QTimer *m_timer = nullptr;
};

RadioStreamSource::RadioStreamSource(const QUrl &url) : m_url(url) {}

RadioStreamSource::~RadioStreamSource() {
    stop();
}

void RadioStreamSource::start() {
    ff::ensureInit();
    m_thread = new QThread;
    m_fetcher = new RadioFetcher(m_url, this);
    m_fetcher->moveToThread(m_thread);
    QObject::connect(m_thread, &QThread::started, m_fetcher, &RadioFetcher::run);
    QObject::connect(m_thread, &QThread::finished, m_fetcher, &QObject::deleteLater);
    m_thread->start();
}

void RadioStreamSource::cancel() {
    // 与 stop() 的唤醒段同构，但不 quit/wait 线程：让卡在 read() 的调用者立即拿到 EOF。
    m_stopReq.store(true);
    std::lock_guard<std::mutex> lk(m_mtx);
    m_cv.notify_all();
}

void RadioStreamSource::stop() {
    m_stopReq.store(true);
    {
        std::lock_guard<std::mutex> lk(m_mtx);
        m_cv.notify_all(); // 唤醒可能卡在背压 push 里的工作线程
    }
    if (m_thread) {
        m_thread->quit(); // 事件循环退出（若正阻塞在 push，已被上面 notify 放开）
        m_thread->wait();
        delete m_thread;
        m_thread = nullptr;
    }
    m_fetcher = nullptr; // 随 QThread::finished 的 deleteLater 释放
}

void RadioStreamSource::push(const char *data, qint64 len) {
    std::unique_lock<std::mutex> lk(m_mtx);
    qint64 off = 0;
    while (off < len && !m_stopReq.load()) {
        if (m_buf.size() >= kCapBytes) {
            m_cv.wait(lk); // 等消费侧腾空间（read 里 notify）
            continue;
        }
        const size_t take = size_t(std::min<qint64>(qint64(kCapBytes - m_buf.size()), len - off));
        const char *p = data + off;
        m_buf.insert(m_buf.end(), p, p + take);
        off += qint64(take);
        m_cv.notify_all(); // 唤醒读侧
    }
}

void RadioStreamSource::markDone() {
    std::lock_guard<std::mutex> lk(m_mtx);
    m_done = true;
    m_cv.notify_all();
}

int64_t RadioStreamSource::read(uint8_t *buf, int buf_size) {
    if (buf_size <= 0) return 0;
    std::unique_lock<std::mutex> lk(m_mtx);
    // 没数据就阻塞等：直到有字节 / 流结束 / 被停止
    m_cv.wait(lk, [&] { return !m_buf.empty() || m_done || m_stopReq.load(); });
    if (m_buf.empty()) return 0; // 结束或停止 → EOF（Decoder 映射 AVERROR_EOF）
    const size_t n = std::min<size_t>(size_t(buf_size), m_buf.size());
    for (size_t i = 0; i < n; ++i) {
        buf[i] = m_buf.front();
        m_buf.pop_front();
    }
    m_cv.notify_all(); // 唤醒可能卡在背压的 push
    return int64_t(n);
}

#include "RadioStream.moc"
