#include "RadioHarness.h"

#include "audio/AudioEngine.h"
#include "playback/PlayerController.h"
#include "models/Track.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QFile>
#include <QThread>
#include <QVariant>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <functional>
#include <thread>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

namespace {

enum class Mode { NoResp, Slow, Stall, Disconnect, Icy, Denied, Retry };

Mode modeFrom(const QByteArray &s) {
    if (s == "noresp") return Mode::NoResp;
    if (s == "slow") return Mode::Slow;
    if (s == "disconnect") return Mode::Disconnect;
    if (s == "denied") return Mode::Denied;
    if (s == "retry") return Mode::Retry;
    if (s == "icy") return Mode::Icy;
    return Mode::Stall; // 默认
}

// —— 本机假电台：一个 QThread 上跑 QTcpServer 事件循环，按模式控制发字节奏 ——
class FakeRadio : public QObject {
    Q_OBJECT
public:
    FakeRadio(QByteArray body, Mode mode, int startBytes)
        : m_body(std::move(body)), m_mode(mode), m_startBytes(startBytes) {
        m_server = new QTcpServer(this);
        connect(m_server, &QTcpServer::newConnection, this, [this] { onNewConn(); });
    }
    quint16 port() const { return m_server->serverPort(); }
    int connections() const { return m_connections; }

public slots:
    void doListen() { m_server->listen(QHostAddress::LocalHost, 0); }

private:
    void onNewConn() {
        ++m_connections;
        QTcpSocket *sock = m_server->nextPendingConnection();
        m_socks.push_back(sock);
        auto request = std::make_shared<QByteArray>();
        const auto receive = [this, sock, request] {
            if (sock->property("response-sent").toBool()) {
                sock->readAll();
                return;
            }
            request->append(sock->readAll());
            if (request->size() > qint64{64} * 1024) {
                sock->abort();
                return;
            }
            if (!request->contains("\r\n\r\n")) return;
            sock->setProperty("response-sent", true);
            respond(sock);
        };
        // 先消费 GET 头再响应/关闭；Windows 关闭带未读请求的 socket 会导致客户端丢失 HTTP 状态。
        connect(sock, &QIODevice::readyRead, this, receive);
        receive();
    }

    void respond(QTcpSocket *sock) {
        if (m_mode == Mode::Denied || m_mode == Mode::Retry) {
            const int status = m_mode == Mode::Denied ? 403 : 503;
            sock->write("HTTP/1.1 " + QByteArray::number(status) +
                        " Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            sock->disconnectFromHost();
            return;
        }
        if (m_mode == Mode::NoResp) return; // 连上后什么都不发
        const QByteArray head = "HTTP/1.1 200 OK\r\nContent-Type: audio/flac\r\nConnection: close\r\n\r\n";
        if (m_mode == Mode::Icy) {
            sock->write(
                "HTTP/1.1 200 OK\r\nContent-Type: audio/flac\r\nicy-metaint: 1024\r\nConnection: close\r\n\r\n");
            const QByteArray metadata("StreamTitle='Review Artist - Live';");
            QByteArray padded = metadata;
            padded.append(QByteArray(((metadata.size() + 15) / 16) * 16 - metadata.size(), '\0'));
            QByteArray interleaved;
            for (qsizetype offset = 0; offset < m_body.size(); offset += 1024) {
                const QByteArray audio = m_body.mid(offset, 1024);
                interleaved += audio;
                if (audio.size() == 1024) {
                    interleaved += char(padded.size() / 16);
                    interleaved += padded;
                }
            }
            // Deliberately split metadata boundaries across readyRead deliveries.
            const int midpoint = 1050;
            sock->write(interleaved.left(midpoint));
            QTimer::singleShot(20, this, [sock, interleaved] {
                sock->write(interleaved.mid(midpoint));
                sock->flush();
            });
            return;
        }
        if (m_mode == Mode::Slow) {
            // 慢首包：400ms 后才发头，再每 300ms 挤 2KB
            QTimer::singleShot(400, this, [this, sock, head] {
                sock->write(head);
                pumpSlow(sock, 0);
            });
            return;
        }
        // Stall / Disconnect：立刻发头 + 起播所需字节，之后停发（Stall 保活 / Disconnect 关）
        sock->write(head);
        const int n = qMin(m_startBytes, int(m_body.size()));
        sock->write(m_body.constData(), n);
        sock->flush();
        if (m_mode == Mode::Disconnect) QTimer::singleShot(400, this, [sock] { sock->abort(); });
    }
    void pumpSlow(QTcpSocket *sock, int off) {
        if (off >= m_body.size()) return;
        const int take = qMin(2048, m_body.size() - off);
        sock->write(m_body.constData() + off, take);
        sock->flush();
        QTimer::singleShot(300, this, [this, sock, off, take] { pumpSlow(sock, off + take); });
    }

    QByteArray m_body;
    int m_connections = 0;
    Mode m_mode;
    int m_startBytes;
    QTcpServer *m_server = nullptr;
    QList<QTcpSocket *> m_socks;
};

using clock = std::chrono::steady_clock;

// 在主线程推进 Qt 事件循环 ms 毫秒：电台异步开流的结果通过
// QMetaObject::invokeMethod(..., QueuedConnection) 投递回主线程，只有这里
// processEvents 起来，onRadioOpened 才会被处理、播放才会真正开始。
void pump(int ms) {
    auto t0 = clock::now();
    while (std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - t0).count() < ms) {
        QCoreApplication::processEvents();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

// 在独立线程跑 fn，最多等 budgetMs；返回 {是否按时完成, 实测毫秒}。
// 超时不 join（fn 可能永久阻塞在网络里），由调用方决定 _exit——泄漏线程留到进程退出。
// 等待期间在主线程 processEvents，让「fn 已发起、结果靠 QueuedConnection 回主线程」
// 的异步开流（noresp/slow/stall/disconnect）能被推进，而不是把主线程钉死在 sleep。
struct Bounded {
    bool ok;
    qint64 ms;
};
Bounded runBounded(const std::function<void()> &fn, int budgetMs) {
    const auto start = clock::now();
    fn(); // Product actions run on their owning Qt thread; CTest supplies a process watchdog.
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - start).count();
    return {elapsed <= budgetMs, elapsed};
}

} // namespace

int runRadioLiveProbe(AudioEngine *engine, PlayerController &controller, QTextStream &out) {
    int fail = 0;
    const auto check = [&](const char *name, bool ok) {
        out << "RADIOLIVE " << name << ' ' << (ok ? "PASS" : "FAIL") << '\n';
        if (!ok) ++fail;
    };

    const Mode mode = modeFrom(qgetenv("TTPLAYER_QT_RADIOLIVE_MODE"));
    const QByteArray path = qgetenv("TTPLAYER_QT_RADIOLIVE_BODY");
    QFile f(path.isEmpty()
                ? qEnvironmentVariable("TTPLAYER_TESTDIR", QStringLiteral("testlib")) + QStringLiteral("/cover.flac")
                : QString::fromLocal8Bit(path));
    if (!f.open(QIODevice::ReadOnly)) {
        out << "RADIOLIVE body_missing FAIL (" << f.fileName() << ")\n";
        return 1;
    }
    const QByteArray body = f.readAll();
    f.close();

    // 假电台跑在自己的 QThread 事件循环上（stall 只发够探测的一小段，便于快速耗尽）
    QThread thr;
    auto *radio = new FakeRadio(body, mode, /*startBytes=*/64 * 1024);
    radio->moveToThread(&thr);
    QObject::connect(&thr, &QThread::finished, radio, &QObject::deleteLater);
    thr.start();
    // 在 radio 线程上开始监听，再回主线程取端口
    QMetaObject::invokeMethod(radio, [radio] { radio->doListen(); }, Qt::BlockingQueuedConnection);
    quint16 port = 0;
    QMetaObject::invokeMethod(radio, [radio, &port] { port = radio->port(); }, Qt::BlockingQueuedConnection);
    check("server_up", port != 0);

    const Track track = Track::fromRadio(QUrl(QStringLiteral("http://127.0.0.1:%1/stream").arg(port)));

    // —— 1) 开流：走真实产品入口（setTracks + playRowAt→loadAndPlay）；
    //    UI 侧调用必须限时返回（after：异步 → 秒回；before 的 noresp/slow：挂死）——
    const int openBudget = 2500;
    Bounded o = runBounded(
        [&] {
            controller.setTracks({track});
            controller.playRowAt(0);
        },
        openBudget);
    out << "RADIOLIVE open_ms " << o.ms << " ok=" << (o.ok ? 1 : 0) << '\n';
    if (!o.ok) {
        out << "RADIOLIVE open_bounded FAIL (UI 开流被网络阻塞 >" << openBudget << "ms)\n";
        out.flush();
        _exit(3); // 阻塞线程泄漏，直接退进程，别污染后续
    }
    check("open_bounded", true);

    if (mode == Mode::Denied || mode == Mode::Retry) {
        int connections = 0;
        if (mode == Mode::Denied) {
            pump(1200);
            QMetaObject::invokeMethod(radio, [&] { connections = radio->connections(); }, Qt::BlockingQueuedConnection);
            check("fatal_HTTP_does_not_retry",
                  connections == 1 && !controller.isPlaying() && controller.radioStatusText().contains("403"));
        } else {
            pump(5000);
            QMetaObject::invokeMethod(radio, [&] { connections = radio->connections(); }, Qt::BlockingQueuedConnection);
            check("retry_limit_six_connections",
                  connections == 6 && controller.radioStatusText().contains(QStringLiteral("手动重试")));
            const int previous = connections;
            controller.retryRadio();
            pump(100);
            QMetaObject::invokeMethod(radio, [&] { connections = radio->connections(); }, Qt::BlockingQueuedConnection);
            check("manual_retry_new_generation", connections > previous);
            controller.stop();
            pump(1200);
            const int stopped = connections;
            QMetaObject::invokeMethod(radio, [&] { connections = radio->connections(); }, Qt::BlockingQueuedConnection);
            check("stop_cancels_backoff", connections == stopped && !controller.isPlaying());
        }
    }
    if (mode == Mode::Icy) {
        for (int i = 0; i < 200 && controller.radioNowPlaying().isEmpty(); ++i)
            pump(10);
        check("ICY_cross_packet_title", controller.radioNowPlaying() == QStringLiteral("Review Artist - Live"));
        check("retry_delays", PlayerController::retryDelay(0) == 2 && PlayerController::retryDelay(1) == 4 &&
                                  PlayerController::retryDelay(2) == 8 && PlayerController::retryDelay(3) == 8);
        for (int i = 0; i < 200 && !controller.isPlaying(); ++i)
            pump(10);
        for (int i = 0; i < 150 && engine->bufferedSeconds() < 5; ++i)
            pump(10);
        out << "RADIOLIVE decoded_reserve_seconds " << engine->bufferedSeconds() << '\n';
        check("live_burst_keeps_five_seconds_of_decoded_audio", engine->bufferedSeconds() >= 5);
        controller.togglePlay();
        check("radio_pause_disconnects_keeps_session",
              !controller.isPlaying() && controller.radioQualityText().contains(QStringLiteral("本次收听")));
        controller.togglePlay();
        for (int i = 0; i < 200 && !controller.isPlaying(); ++i)
            pump(10);
        check("radio_resume_reconnects_same_session",
              controller.isPlaying() && controller.radioQualityText().contains(QStringLiteral("重连 1 次")));
        controller.retryRadio();
        pump(100);
        controller.stop();
        const QString stopped = controller.radioStatusText();
        pump(500);
        check("stop_invalidates_late_playing", !controller.isPlaying() && stopped == QStringLiteral("未连接") &&
                                                   controller.radioStatusText() == stopped);
    }

    // —— 2) stall/disconnect：起播 → 缓冲耗尽（stall 时回调卡在等字节、持引擎锁）→ stop 必须秒回 ——
    if (mode == Mode::Stall || mode == Mode::Disconnect) {
        // 起播检查：趁字节还没耗尽时做（positionSeconds 也拿引擎锁，耗尽后会一起卡住）
        bool started = false;
        for (int i = 0; i < 30 && !started; ++i) {
            runBounded([&] { started = engine->isPlaying() || engine->positionSeconds() > 0.05; }, 300);
            if (!started) pump(30);
        }
        out << "RADIOLIVE playback_started " << (started ? "INFO-yes" : "INFO-no") << '\n';

        // 等到缓冲在实时消费下耗尽：stall 给足 3s（回调必然卡在 src->read 持锁），
        // disconnect 只 800ms（400ms 时服务端 abort → markDone → EOF，不会卡）
        const int drain = mode == Mode::Stall ? 3000 : 800;
        pump(drain);
        const int stopBudget = 1500;
        Bounded s = runBounded([&] { controller.stop(); }, stopBudget);
        out << "RADIOLIVE stop_ms " << s.ms << " ok=" << (s.ok ? 1 : 0) << '\n';
        if (!s.ok) {
            out << "RADIOLIVE stop_bounded FAIL (断流时 UI stop 卡在引擎锁 >" << stopBudget << "ms)\n";
            out.flush();
            _exit(4);
        }
        check("stop_bounded", true);
    } else {
        // noresp/slow：只断言开流有界；收尾停掉（此时可能根本没起播，stop 应安全秒回）
        Bounded s = runBounded([&] { controller.stop(); }, 1500);
        check("stop_bounded", s.ok);
    }

    // —— 3) 反复 stop/切歌压力（R08 验收：每阶段 ≥ 30 次，验取消/换代无死锁）——
    // 每轮都重走真实入口 playRowAt → loadAndPlay → abortPendingOpen（取消上一条在途
    // 开流 + 换代 token）→ startRadioAsync，随后立刻 stop：让「后台卡在 openStream/
    // read」与「UI 发起下一轮」交叠，才能抱住代际/取消路径的竞态。
    const int stress = qgetenv("TTPLAYER_QT_RADIOLIVE_STRESS").toInt();
    if (stress > 0) {
        qint64 worstOpen = 0, worstStop = 0;
        bool openUnbounded = false, stopUnbounded = false;
        for (int i = 0; i < stress; ++i) {
            Bounded openResult = runBounded(
                [&] {
                    controller.setTracks({track});
                    controller.playRowAt(0);
                },
                2500);
            worstOpen = std::max(worstOpen, openResult.ms);
            if (!openResult.ok) openUnbounded = true;
            // 让后台开流有机会推进（起播/卡在 read），再立即 stop/切下一轮
            pump(mode == Mode::Stall ? 40 : 15);
            Bounded s = runBounded([&] { controller.stop(); }, 1500);
            worstStop = std::max(worstStop, s.ms);
            if (!s.ok) stopUnbounded = true;
        }
        out << "RADIOLIVE stress iterations=" << stress << " worst_open_ms=" << worstOpen
            << " worst_stop_ms=" << worstStop << '\n';
        check("stress_open_bounded", !openUnbounded);
        check("stress_stop_bounded", !stopUnbounded);
    }

    controller.stop();
    if (mode == Mode::NoResp || mode == Mode::Slow) {
        bool reclaimed = true;
        for (int round = 0; round < 30; ++round) {
            auto isolated = AudioEngine::create();
            auto owner = std::make_unique<PlayerController>(isolated);
            owner->setTracks({track});
            owner->playRowAt(0);
            pump(10);
            const auto begin = clock::now();
            owner.reset();
            isolated.reset();
            reclaimed &= std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - begin).count() < 1500;
            pump(5); // Deliver any queued late callbacks after the owner has gone.
        }
        check("destroy_controller_during_open_30", reclaimed);
    }
    thr.quit();
    thr.wait(2000);
    out << "RADIOLIVE done fail=" << fail << '\n';
    return fail;
}

#include "RadioHarness.moc"
