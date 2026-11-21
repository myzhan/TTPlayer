#include "PlayerController.h"
#include "decoder/Archive.h"
#include "audio/RadioStream.h"
#include <QPointer>
#include <QApplication>
#include <QDateTime>
#include <algorithm>
#include <cmath>
#include <thread>
#include <utility>

PlayerController::PlayerController(AudioEnginePtr engine, QObject *parent)
    : QObject(parent), m_engine(std::move(engine)) {
    m_radioClock.start();
    m_tick.setInterval(250);
    connect(&m_tick, &QTimer::timeout, this, [this] {
        if (m_radioWantsPlay && m_engine->isPlaying()) {
            const double buffer = m_engine->bufferedSeconds();
            const double now = m_radioClock.elapsed() / 1000.0;
            m_radioQuality.noteBuffer(buffer, now);
            const uint64_t events = m_engine->underruns();
            if (events > m_seenUnderruns) m_radioQuality.noteUnderrun(now);
            m_seenUnderruns = events;
            QString status;
            switch (m_engine->radioBufferState()) {
            case AudioEngine::RadioBufferState::Priming:
                status = QStringLiteral("正在缓冲…");
                break;
            case AudioEngine::RadioBufferState::Refilling:
                status = QStringLiteral("缓冲不足，正在等数据…");
                break;
            case AudioEngine::RadioBufferState::Playing:
                status = QStringLiteral("直播中");
                break;
            }
            if (status != m_radioStatus) {
                m_radioStatus = status;
                emit playbackStateChanged();
            }
        }
        const double pos = m_engine->positionSeconds();
        if (pos >= 0) {
            m_positionCache = pos;
            emit positionTicked(pos, duration());
        }
    });
    m_tick.start();
    auto *devicePoll = new QTimer(this);
    devicePoll->setInterval(1000);
    connect(devicePoll, &QTimer::timeout, this, [this] {
        const bool wanted = m_radioWantsPlay;
        if (m_engine->pollDevices() && wanted) retryRadio();
    });
    devicePoll->start();

    // 睡眠心跳：0.5 s 一格，够把「剩余时间」读顺，又不必为它单开一条线程
    m_sleepTick.setInterval(500);
    connect(&m_sleepTick, &QTimer::timeout, this, &PlayerController::sleepTick);

    // 回调由引擎在主线程排队触发；QPointer 防控制器先于回调析构（悬垂 this）
    QPointer<PlayerController> guard(this);
    m_engine->onFinished = [guard] {
        if (guard) guard->onTrackFinished();
    };
    m_engine->onTransition = [guard](const QString &key) {
        if (!guard) return;
        // Audio has already committed this queue item. A mode change before UI delivery
        // controls the following pick; it must not choose this transition a second time.
        const QueueItem *next = guard->m_queue.focus(QUuid(key));
        if (!next) {
            guard->stop();
            return;
        }
        guard->m_queue.markPlayed(next->id);
        guard->m_positionCache = guard->m_engine->positionSeconds();
        guard->loadLyricForCurrent();
        emit guard->queueChanged();
        emit guard->trackChanged();
        emit guard->playbackStateChanged();
        guard->schedulePrefetch();
    };
}

void PlayerController::setTracks(const QList<Track> &tracks) {
    m_tracks = tracks;
    emit listChanged();
}

void PlayerController::replaceTrackReferences(const QHash<QString, Track> &replacements) {
    const Track current = currentTrack();
    bool changedCurrent = false;
    for (auto item = replacements.begin(); item != replacements.end(); ++item) {
        changedCurrent |= !current.isNull() && current.identityKey() == item.key();
        m_queue.replaceTrack(item.key(), item.value());
        if (item.key() != item.value().identityKey() && m_lyricShifts.contains(item.key()))
            m_lyricShifts.insert(item.value().identityKey(), m_lyricShifts.take(item.key()));
    }
    refreshPrefetch();
    if (changedCurrent) {
        loadLyricForCurrent();
        emit trackChanged();
    }
    emit lyricShiftChanged();
    emit queueChanged();
}

PlayerController::~PlayerController() {
    abortPendingOpen();
    m_engine->stop();
    cancelPrefetch();
    for (auto &worker : m_openWorkers)
        worker.second->cancelled = true;
    m_engine->onFinished = nullptr;
    m_engine->onTransition = nullptr;
    for (auto &worker : m_openWorkers)
        if (worker.first.joinable()) worker.first.join();
}

void PlayerController::setMode(PlayMode m) {
    if (m == m_mode) return;
    m_mode = m;
    m_queue.invalidatePick();  // 模式变了，先定选答案作废
    m_prefetchDecoder.reset(); // 预取的下一曲作废（旧模式下的 peek）
    m_prefetchKey.clear();
    schedulePrefetch();
    emit modeChanged();
}

bool PlayerController::isPlaying() const {
    return m_engine->isPlaying();
}

double PlayerController::duration() const {
    const Track t = m_queue.currentTrack();
    if (t.isNull()) return 0;
    const double engineDur = m_engine->durationSeconds();
    return engineDur > 0 ? engineDur : t.duration();
}

void PlayerController::playRowAt(int row) {
    beginContextAndPlay(row);
}

void PlayerController::beginContextAndPlay(int row) {
    if (row < 0 || row >= m_tracks.size()) return;
    m_consecutiveFailures = 0;
    m_queue.begin(m_tracks, row);
    const QueueItem *item = m_queue.current();
    if (!item) return;
    m_queue.markPlayed(item->id);
    if (loadAndPlay(item->track)) {
        emit trackChanged();
        emit playbackStateChanged();
    } else {
        // 装载失败：走失败跳（不清计数，见 advanceToNext 的递归上界）
        emit trackChanged();
        onTrackFinished();
    }
}

// 队列变了（排队 / 移除 / 重排 / 换游标）：重算预取。有当前曲才值得重新开一条
// 解码器；彻底停住（无游标）时只丢弃旧预取，不白开流。
void PlayerController::refreshPrefetch() {
    if (m_queue.current())
        schedulePrefetch();
    else {
        m_prefetchDecoder.reset();
        m_prefetchKey.clear();
    }
}

int PlayerController::enqueueNext(const QList<Track> &tracks) {
    if (tracks.isEmpty()) return 0;
    m_queue.insertNext(tracks);
    emit queueChanged();
    refreshPrefetch();
    return tracks.size();
}

int PlayerController::enqueueLater(const QList<Track> &tracks) {
    if (tracks.isEmpty()) return 0;
    m_queue.appendLater(tracks);
    emit queueChanged();
    refreshPrefetch();
    return tracks.size();
}

void PlayerController::removeQueued(const QSet<QUuid> &ids) {
    if (ids.isEmpty()) return;
    m_queue.remove(ids);
    emit queueChanged();
    refreshPrefetch();
}

void PlayerController::dropTracks(const QSet<QString> &keys) {
    m_queue.dropTracks(keys);
    refreshPrefetch();
    emit queueChanged();
}

void PlayerController::clearPendingQueue() {
    m_queue.clearPending();
    emit queueChanged();
    refreshPrefetch();
}

bool PlayerController::moveQueued(const QUuid &id, int index) {
    if (!m_queue.movePending(id, index)) return false;
    emit queueChanged();
    refreshPrefetch();
    return true;
}

bool PlayerController::reorderQueued(const QList<QUuid> &order) {
    if (!m_queue.reorderPending(order)) return false;
    emit queueChanged();
    refreshPrefetch();
    return true;
}

// 直接播队列里某一条（队列面板双击）：只把游标移到它，不重建上下文，
// 所以它后面的条目照样按原次序轮到。
void PlayerController::playQueued(const QUuid &id) {
    m_consecutiveFailures = 0;
    const QueueItem *item = m_queue.focus(id);
    if (!item) return;
    m_queue.markPlayed(item->id);
    emit queueChanged();
    if (loadAndPlay(item->track)) {
        emit trackChanged();
        emit playbackStateChanged();
    } else {
        emit trackChanged();
        onTrackFinished();
    }
}

// R03：重建上下文/游标/历史，装载当前曲并定位；autoPlay=false 停在原位不响。
bool PlayerController::restoreResume(const QList<QueueItem> &items, std::optional<int> cursor,
                                     const QList<int> &historyIndexes, double position, bool autoPlay) {
    m_consecutiveFailures = 0;
    m_queue.restoreScene(items, cursor, historyIndexes);
    const QueueItem *cur = m_queue.current();
    if (!cur) return false;
    emit queueChanged();
    // loadAndPlay 会立即开播：定位后若不需自动续播就马上暂停（decoder 留住，之后可 resume）。
    // 电台走异步开流，把 autoPlay 意图交给 m_resumeAutoPlay，由 onRadioOpened 收尾时暂停。
    m_resumeAutoPlay = autoPlay;
    m_restorePending = true;
    m_restorePosition = std::isfinite(position) ? std::max(0.0, position) : 0;
    if (!loadAndPlay(cur->track)) {
        // 当前曲打不开：保持现场（游标就位），不擅自推进整条队列
        emit trackChanged();
        return false;
    }
    // 不需自动续播就直接暂停（loadAndPlay 已确定开播，不能走 togglePlay——
    // dummy/异步设备下 play 后 isPlaying 未必立刻为真，togglePlay 会误判成「重新装载」又开声）。
    emit trackChanged();
    emit playbackStateChanged();
    return true;
}

bool PlayerController::loadAndPlay(const Track &track) {
    return loadAndPlay(track, nullptr);
}

bool PlayerController::loadAndPlay(const Track &track, std::unique_ptr<Decoder> prepared) {
    // R08：任何新装载先作废上一条在途的电台开流（取消 + 换代 token）
    abortPendingOpen();
    // 开流是否立刻出声：restoreResume 置 false 表示「恢复现场但不响」
    const bool restoring = std::exchange(m_restorePending, false);
    const bool autoPlay = m_resumeAutoPlay;
    m_resumeAutoPlay = true;

    // 电台：把可能长时间阻塞的 avformat_open_input/find_stream_info 搬离 UI 线程
    if (!prepared && track.isRadio()) {
        if (m_radioSessionKey != track.identityKey()) {
            m_radioSessionKey = track.identityKey();
            m_radioTitle.clear();
            m_radioRetries = 0;
            m_radioQuality.startSession(m_radioQuality.session + 1);
            m_seenUnderruns = m_engine->underruns();
        }
        m_radioWantsPlay = autoPlay;
        if (!autoPlay) {
            m_radioStatus = QStringLiteral("未连接");
            return true;
        }
        startRadioAsync(track, autoPlay);
        return true; // 乐观：已发起后台开流，成败在主线程 onRadioOpened 收尾
    }

    m_radioWantsPlay = false;
    m_radioRetries = 0;

    if (!prepared) {
        startLocalAsync(track, autoPlay, std::exchange(m_restorePosition, 0), restoring);
        return true;
    }
    auto decoder = std::move(prepared);
    if (!decoder) {
        m_engine->stop();
        emit playbackStateChanged();
        return false;
    }
    const double position = std::exchange(m_restorePosition, 0);
    if (!m_engine->play(std::move(decoder), track.playStart(), track.playEnd(), autoPlay, position,
                        track.isRadio() ? 1.0f : replayGainDecision(track).linear)) {
        emit playbackStateChanged();
        return false;
    }
    // 电台线性增益锁 1.0（live 流无标签）；本地/归档按当前曲标签与设置算
    m_engine->setReplayGainLinear(track.isRadio() ? 1.0f : replayGainDecision(track).linear);
    m_positionCache = m_engine->positionSeconds();
    loadLyricForCurrent();
    if (!autoPlay) m_engine->pause();
    // 坑 #14：预取只能在当前曲已经排进节点之后发起
    schedulePrefetch();
    return true;
}

void PlayerController::reapWorkers() {
    for (auto worker = m_openWorkers.begin(); worker != m_openWorkers.end();) {
        if (worker->second->finished.load()) {
            worker->first.join();
            worker = m_openWorkers.erase(worker);
        } else
            ++worker;
    }
}

void PlayerController::startLocalAsync(const Track &track, bool autoPlay, double position, bool restoring) {
    reapWorkers();
    cancelPrefetch();
    m_engine->stop();
    const uint64_t token = ++m_openToken;
    m_loadWantsPlay = autoPlay;
    auto job = std::make_shared<RadioOpenJob>();
    m_openJob = job;
    std::thread worker([this, job, track, token, position, restoring] {
        struct Completion {
            std::shared_ptr<RadioOpenJob> job;
            ~Completion() { job->finished = true; }
        } completion{job};
        auto decoder = openDecoderFor(track, std::shared_ptr<std::atomic<bool>>(job, &job->cancelled));
        if (job->cancelled) return;
        QMetaObject::invokeMethod(
            this,
            [this, token, track, position, restoring, decoder = std::move(decoder)]() mutable {
                if (token != m_openToken) return;
                m_openJob.reset();
                if (!decoder) {
                    if (restoring) {
                        Track failed = track;
                        failed.setDecodeProblem(QStringLiteral("无法恢复这个文件，请重新定位或手动选择其他曲目"));
                        m_engine->stop();
                        m_positionCache = 0;
                        loadLyricForCurrent();
                        emit trackChanged();
                        emit playbackStateChanged();
                        return;
                    }
                    if (++m_consecutiveFailures >= std::max(1, m_queue.count())) {
                        stop();
                        return;
                    }
                    onTrackFinished();
                    return;
                }
                m_consecutiveFailures = 0;
                m_resumeAutoPlay = m_loadWantsPlay;
                m_restorePosition = position;
                if (!loadAndPlay(track, std::move(decoder))) {
                    stop();
                    return;
                }
                emit trackChanged();
                emit playbackStateChanged();
            },
            Qt::QueuedConnection);
    });
    m_openWorkers.emplace_back(std::move(worker), job);
}

void PlayerController::cancelPrefetch() {
    ++m_prefetchToken;
    if (m_prefetchJob) m_prefetchJob->cancelled = true;
    m_prefetchJob.reset();
    m_engine->clearNext();
}

// 后台线程阻塞开流，回主线程收尾；所有线程由控制器持有并在析构前回收。
void PlayerController::startRadioAsync(const Track &track, bool autoPlay) {
    reapWorkers();
    m_engine->stop();
    m_radioStatus = QStringLiteral("正在连接");
    m_positionCache = 0;
    emit playbackStateChanged();
    const uint64_t token = ++m_openToken; // 与 abortPendingOpen 同一派号序列
    auto job = std::make_shared<RadioOpenJob>();
    m_openJob = job;
    const QUrl &url = track.url();
    const QString disp = url.toString();
    // src 被 RadioOpenJob 与 Decoder 共享持有：发起方在开流期间也能安全 cancel()。
    // All workers are owned, cancelled and joined before controller destruction. Network callbacks
    // post through qApp and inspect the guarded receiver only on the UI thread.
    QPointer<PlayerController> guard(this);
    std::thread worker([this, guard, job, url, disp, track, token, autoPlay] {
        struct Completion {
            std::shared_ptr<RadioOpenJob> job;
            ~Completion() { job->finished = true; }
        } completion{job};
        auto src = std::make_shared<RadioStreamSource>(url);
        src->onError = [guard, token](int status, const QString &reason) {
            QMetaObject::invokeMethod(
                qApp,
                [guard, token, status, reason] {
                    if (!guard || token != guard->m_openToken || !guard->m_radioWantsPlay) return;
                    if (status == 401 || status == 403 || status == 404) {
                        guard->m_radioWantsPlay = false;
                        guard->m_radioStatus = status == 404
                                                   ? QStringLiteral("找不到这个电台（HTTP 404）")
                                                   : QStringLiteral("电台要账号或密码（HTTP %1）").arg(status);
                        guard->m_engine->stop();
                        emit guard->playbackStateChanged();
                    } else if (!reason.isEmpty())
                        guard->m_radioStatus = reason;
                },
                Qt::QueuedConnection);
        };
        src->onMetadata = [guard, token](const QString &title) {
            QMetaObject::invokeMethod(
                qApp,
                [guard, token, title] {
                    if (!guard || token != guard->m_openToken || !guard->m_radioWantsPlay) return;
                    guard->m_radioTitle = title;
                    emit guard->playbackStateChanged();
                },
                Qt::QueuedConnection);
        };
        {
            std::lock_guard<std::mutex> lk(job->mtx);
            if (job->cancelled.load()) return; // 已被取消，别白连
            job->src = src;                    // 发布给发起方供取消
        }
        src->start();
        std::unique_ptr<Decoder> dec = Decoder::openStream(src, disp); // 唯一阻塞点
        if (job->cancelled.load()) return;                             // 晚到：dec/src 随作用域释放
        QMetaObject::invokeMethod(
            this,
            [this, token, track, dec = std::move(dec), autoPlay]() mutable {
                onRadioOpened(token, track, std::move(dec), autoPlay);
            },
            Qt::QueuedConnection);
    });
    m_openWorkers.emplace_back(std::move(worker), job);
}

void PlayerController::onRadioOpened(uint64_t token, Track track, std::unique_ptr<Decoder> dec, bool autoPlay) {
    if (token != m_openToken || !m_radioWantsPlay) return; // 旧连接与终止错误不能重新点亮播放
    m_openJob.reset();
    if (dec) {
        track.setMetadata(0, dec->sampleRate(), dec->channelCount(), dec->bitRateKbps());
        track.setFormatName(dec->formatName());
    }
    if (!dec || !m_engine->play(std::move(dec), track.playStart(), track.playEnd(), autoPlay, 0, 1, true)) {
        // 开流失败/取消：按装载失败处理——停 + 失败跳（沿用同步失败语义）
        m_engine->stop();
        emit playbackStateChanged();
        scheduleRadioRetry();
        return;
    }
    m_engine->setReplayGainLinear(1.0f); // 电台线性增益锁 1.0
    m_radioStatus = QStringLiteral("正在缓冲…");
    m_positionCache = 0;
    loadLyricForCurrent();
    if (!autoPlay) m_engine->pause();
    schedulePrefetch();
    emit trackChanged();
    emit playbackStateChanged();
}

void PlayerController::abortPendingOpen() {
    ++m_openToken; // 作废在途开流（晚到结果不再被采纳）
    if (!m_openJob) return;
    m_openJob->cancelled.store(true);
    std::shared_ptr<RadioStreamSource> s;
    {
        std::lock_guard<std::mutex> lk(m_openJob->mtx);
        s = m_openJob->src;
    }
    if (s) s->cancel(); // 唤醒卡在 find_stream_info 的阻塞 read
    m_openJob.reset();
}

void PlayerController::scheduleRadioRetry() {
    if (!m_radioWantsPlay) return;
    if (m_radioRetries >= 5) {
        m_radioWantsPlay = false;
        m_radioStatus = QStringLiteral("电台连不上，请手动重试");
        emit playbackStateChanged();
        return;
    }
    const uint64_t token = m_openToken;
    const int delay = retryDelay(m_radioRetries++);
    m_radioQuality.noteReconnect(m_radioClock.elapsed() / 1000.0);
    m_radioStatus = QStringLiteral("%1 秒后重连（第 %2 次）").arg(delay).arg(m_radioRetries);
    emit playbackStateChanged();
    const double scale = qEnvironmentVariableIsSet("TTPLAYER_SELFTEST") ? 0.125 : 1.0;
    QTimer::singleShot(int(delay * 1000 * scale), this, [this, token] {
        if (token != m_openToken || !m_radioWantsPlay) return;
        const Track track = currentTrack();
        if (!track.isNull() && track.isRadio()) startRadioAsync(track, true);
    });
}

void PlayerController::retryRadio() {
    const Track track = currentTrack();
    if (track.isNull() || !track.isRadio()) return;
    if (m_radioSessionKey != track.identityKey()) {
        m_radioSessionKey = track.identityKey();
        m_radioQuality.startSession(m_radioQuality.session + 1);
        m_seenUnderruns = m_engine->underruns();
        m_radioTitle.clear();
    }
    m_radioQuality.noteReconnect(m_radioClock.elapsed() / 1000.0);
    abortPendingOpen();
    m_radioRetries = 0;
    m_radioWantsPlay = true;
    startRadioAsync(track, true);
}

// 文件 / 归档 / 电台统一开流（预取与现场播放同一条通路，保证预取真的能用）
std::unique_ptr<Decoder> PlayerController::openDecoderFor(const Track &track,
                                                          std::shared_ptr<std::atomic<bool>> cancel) {
    if (track.isRadio()) {
        // 电台：QtNetwork 拉流喂自定义 AVIO（不可定位、无时长、不做 ReplayGain）
        // （正常播放路径已改走 startRadioAsync 异步开流；这里保留给需要同步开的调用）
        auto src = std::make_shared<RadioStreamSource>(track.url());
        src->start();
        return Decoder::openStream(src, track.url().toString());
    }
    QString apath, entry;
    if (Archive::parseEntryUrl(track.url(), apath, entry)) {
        // 归档条目：libarchive 流式读，喂同一条 FFmpeg 通路（不落地解压）
        return Decoder::openStream(std::make_shared<ArchiveEntrySource>(apath, entry), track.url().toString(), cancel);
    }
    return Decoder::openFile(track.url().toLocalFile(), cancel);
}

// 无缝预取（F01）：开下一曲的解码器先挂住，切歌时直接换手，消除 FFmpeg 开流延迟。
// 只在真开无缝、且下一条能确定（非电台 / 非「播完当前曲」即将停）时做。
void PlayerController::schedulePrefetch() {
    cancelPrefetch();
    m_prefetchDecoder.reset();
    m_prefetchKey.clear();
    if (!m_gapless) return;
    if (m_sleepPlan == SleepPlan::AfterTrack) return; // 一会儿就停，不必预取
    const QueueItem *peek = m_queue.peekOnFinish(m_mode);
    if (!peek) return;
    const Track &nt = peek->track;
    if (nt.isRadio()) return; // 直播流不预取
    reapWorkers();
    const Track next = nt;
    const QString queueId = peek->id.toString();
    const uint64_t token = m_prefetchToken;
    const int rate = int(m_engine->sampleRate());
    auto job = std::make_shared<RadioOpenJob>();
    m_prefetchJob = job;
    std::thread worker([this, job, next, queueId, token, rate] {
        struct Completion {
            std::shared_ptr<RadioOpenJob> job;
            ~Completion() { job->finished = true; }
        } completion{job};
        auto decoder = openDecoderFor(next, std::shared_ptr<std::atomic<bool>>(job, &job->cancelled));
        if (job->cancelled || !decoder || !decoder->resampleTo(rate)) return;
        QMetaObject::invokeMethod(
            this,
            [this, job, next, queueId, token, decoder = std::move(decoder)]() mutable {
                if (job->cancelled || token != m_prefetchToken) return;
                m_prefetchJob.reset();
                m_engine->prepareNext(std::move(decoder), next.playStart(), next.playEnd(),
                                      replayGainDecision(next).linear, queueId);
            },
            Qt::QueuedConnection);
    });
    m_openWorkers.emplace_back(std::move(worker), job);
}

void PlayerController::togglePlay() {
    const Track current = currentTrack();
    if (!current.isNull() && current.isRadio()) {
        if (m_engine->isPlaying() || m_openJob) {
            // Pause disconnects live IO but keeps this listening session's quality ledger.
            m_radioWantsPlay = false;
            abortPendingOpen();
            m_engine->stop();
            m_radioStatus = QStringLiteral("未连接");
            m_positionCache = 0;
        } else {
            if (!m_radioSessionKey.isEmpty()) m_radioQuality.noteReconnect(m_radioClock.elapsed() / 1000.0);
            m_radioRetries = 0;
            loadAndPlay(current);
        }
        emit playbackStateChanged();
        return;
    }
    if (!m_queue.current()) {
        const QueueItem *head = m_queue.itemAt(0);
        if (head)
            playQueued(head->id);
        else if (!m_tracks.isEmpty())
            playRowAt(0);
        return;
    }
    if (m_openJob) {
        m_loadWantsPlay = !m_loadWantsPlay;
        emit playbackStateChanged();
        return;
    }
    if (m_engine->isPlaying()) {
        m_engine->pause();
    } else if (!m_engine->resume()) {
        // 停干净了（stop 后 decoder 已释放）：重播当前曲
        const Track t = m_queue.currentTrack();
        if (!t.isNull()) loadAndPlay(t);
    }
    emit playbackStateChanged();
}

const QueueItem *PlayerController::advanceToNext() {
    // 失败路径专用：只算推进，绝不走 next()（它会清零 consecutiveFailures，
    // 整队列解不开时「失败→跳下一条→又失败」会同步递归到栈溢出）
    return m_queue.advanceOnFinish(m_mode);
}

void PlayerController::onTrackFinished() {
    if (!currentTrack().isNull() && currentTrack().isRadio()) {
        m_engine->stop();
        scheduleRadioRetry();
        return;
    }
    // 睡眠「播完当前曲」：刚 finish 的这一条就是绑定的那一条 → 直接停，不推进
    if (m_sleepPlan == SleepPlan::AfterTrack) {
        const QueueItem *cur = m_queue.current();
        if (cur && cur->id.toString() == m_sleepTrackId) {
            fireSleep(QStringLiteral("播完当前曲"));
            return;
        }
    }
    const int ceiling = std::max(m_queue.count(), int(m_tracks.size()));
    int hops = 0;
    while (hops++ <= ceiling) {
        const QueueItem *item = advanceToNext();
        if (!item) { // 顺序模式走到头：停下（装载着但停住）
            m_engine->stop();
            m_positionCache = 0;
            emit playbackStateChanged();
            return;
        }
        m_queue.markPlayed(item->id);
        // 无缝：预取正好就是这一条 → 直接换手（消除 FFmpeg 开流延迟）
        std::unique_ptr<Decoder> prepared;
        if (m_prefetchDecoder && item->track.identityKey() == m_prefetchKey) {
            prepared = std::move(m_prefetchDecoder);
            m_prefetchKey.clear();
        }
        if (loadAndPlay(item->track, std::move(prepared))) {
            // 成功解开后才在异步收尾里清除失败计数。
            emit trackChanged(); // 装载完（歌词已重解）再报，窗体读到的是本曲
            emit playbackStateChanged();
            return;
        }
        ++m_consecutiveFailures;
    }
    m_engine->stop();
    emit playbackStateChanged();
}

void PlayerController::next() {
    m_consecutiveFailures = 0;
    const QueueItem *item = m_queue.advanceByUser(m_mode);
    if (!item) return;
    m_queue.markPlayed(item->id);
    if (loadAndPlay(item->track)) {
        emit trackChanged();
        emit playbackStateChanged();
    } else
        onTrackFinished();
}

void PlayerController::prev() {
    m_consecutiveFailures = 0;
    // >3s 先回本曲头（经典播放器直觉），否则真·上一首
    if (m_positionCache > 3.0 && m_engine->seekSeconds(0)) {
        m_positionCache = 0;
        emit positionTicked(0, duration());
        return;
    }
    const QueueItem *item = m_queue.retreat(m_mode);
    if (!item) return;
    m_queue.markPlayed(item->id);
    if (loadAndPlay(item->track)) {
        emit trackChanged();
        emit playbackStateChanged();
    } else
        onTrackFinished();
}

void PlayerController::seekTo(double sec) {
    if (currentTrack().isRadio()) return;
    if (m_engine->seekSeconds(sec)) {
        m_positionCache = sec;
        emit positionTicked(sec, duration());
    }
}

void PlayerController::stop() {
    m_radioWantsPlay = false;
    m_radioStatus = QStringLiteral("未连接");
    m_radioTitle.clear();
    m_radioSessionKey.clear();
    m_radioQuality.startSession(0);
    if (m_sleepPlan == SleepPlan::AfterTrack) cancelSleepTimer();
    cancelPrefetch();
    abortPendingOpen(); // 停止时也要掐掉在途的电台开流，别让晚到的流把台连上
    m_engine->stop();
    m_positionCache = 0;
    emit playbackStateChanged();
}

// MARK: - 响度均衡 ReplayGain（F02）

ReplayGainDecision PlayerController::replayGainDecision(const Track &track) const {
    return ReplayGainDecision::decide(track.replayGainTags(), m_rgMode, m_rgPreamp, m_rgPeakLimit, track.isRadio());
}

void PlayerController::applyReplayGainForCurrent() {
    const Track t = m_queue.currentTrack();
    if (t.isNull() || t.isRadio()) return;
    m_engine->setReplayGainLinear(replayGainDecision(t).linear);
    schedulePrefetch();
}

void PlayerController::setReplayGainMode(ReplayGainMode m) {
    if (m == m_rgMode) return;
    m_rgMode = m;
    applyReplayGainForCurrent();
    emit replayGainChanged();
}

void PlayerController::setReplayGainPreamp(double db) {
    const double clamped = std::clamp(db, -12.0, 12.0);
    if (std::abs(clamped - m_rgPreamp) <= 0.009) return;
    m_rgPreamp = clamped;
    applyReplayGainForCurrent();
    emit replayGainChanged();
}

void PlayerController::setReplayGainPeakLimit(bool on) {
    if (on == m_rgPeakLimit) return;
    m_rgPeakLimit = on;
    applyReplayGainForCurrent();
    emit replayGainChanged();
}

QString PlayerController::replayGainStatusText(const Track &track, bool applied) const {
    const ReplayGainDecision d = replayGainDecision(track);
    switch (d.source) {
    case ReplayGainDecision::Source::Radio:
        return d.summaryText();
    case ReplayGainDecision::Source::Off:
        return QStringLiteral("已关闭（只听原曲自己的响度）");
    case ReplayGainDecision::Source::NoTag:
        // 没标签与标签还没读到是两回事，不能都写成 0 dB
        return track.replayGainTags() ? d.summaryText() : QStringLiteral("标签还没读到（元数据在后台解析）");
    default: {
        QString text = QStringLiteral("%1%2")
                           .arg(applied ? QStringLiteral("已施加 ") : QStringLiteral("未播放，按现在的设置会加 "))
                           .arg(d.summaryText());
        if (std::abs(m_rgPreamp) > 0.009)
            text += QStringLiteral("｜含前置增益 %1 dB").arg(ReplayGainFormat::signedDb(m_rgPreamp, 1));
        return text;
    }
    }
}

// MARK: - 歌词与时间校准（F10）

void PlayerController::loadLyricForCurrent() {
    const Track t = m_queue.currentTrack();
    if (t.isNull()) {
        m_lyric = Lyric{};
        return;
    }
    // 候选查找与 CUE 整盘时间轴（mirrorShift）都由 loadForTrack 内部定好，
    // 这里不能再强推 0——否则分轨配整盘词会从第一轨的词开始唱（R16）。
    m_lyric = Lyric::loadForTrack(t);
}

double PlayerController::alignedLyricTime(double segmentTime) const {
    if (m_lyric.isEmpty()) return segmentTime;
    return m_lyric.alignedTime(segmentTime, lyricShift());
}

static double clampShift(double v) {
    if (!std::isfinite(v)) return 0;
    return std::clamp(v, -PlayerController::kLyricShiftLimit, PlayerController::kLyricShiftLimit);
}

double PlayerController::lyricShift() const {
    const Track t = m_queue.currentTrack();
    if (t.isNull()) return 0;
    return clampShift(m_lyricShifts.value(t.identityKey(), 0));
}

QString PlayerController::lyricShiftProblem() const {
    const Track t = m_queue.currentTrack();
    if (t.isNull()) return QStringLiteral("现在没有正在播的曲目，没什么可校准");
    if (t.isRadio()) return QStringLiteral("电台是直播，没有歌词可校准");
    if (m_lyric.isEmpty()) return QStringLiteral("这一首没找到可用歌词（同名 .lrc 里没有带时间标签的句子）");
    return QString();
}

QString PlayerController::lyricShiftText() const {
    const double s = lyricShift();
    if (std::abs(s) < 0.001) return QStringLiteral("未校准");
    return s > 0 ? QStringLiteral("延后 %1 秒").arg(s, 0, 'f', 1) : QStringLiteral("提前 %1 秒").arg(-s, 0, 'f', 1);
}

QString PlayerController::lyricShiftDetail() const {
    QString problem = lyricShiftProblem();
    if (!problem.isEmpty()) return problem;
    QString text = QStringLiteral("歌词%1").arg(lyricShiftText());
    const double off = m_lyric.fileOffset();
    if (std::abs(off) > 0.0001)
        text += QStringLiteral("（文件自带 %1%2 秒，已叠加不重算）")
                    .arg(off > 0 ? QLatin1Char('+') : QLatin1Char('-'))
                    .arg(std::abs(off), 0, 'f', 1);
    text += QStringLiteral("；上下限 ±%1 秒，只记在播放器里，不改写 .lrc").arg(int(kLyricShiftLimit));
    return text;
}

QString PlayerController::nudgeLyricShift(double delta) {
    const Track t = m_queue.currentTrack();
    const QString problem = lyricShiftProblem();
    if (t.isNull() || !problem.isEmpty()) return problem.isEmpty() ? QStringLiteral("现在没什么可校准的") : problem;
    const double old = lyricShift();
    const double want = clampShift(std::round((old + delta) * 10.0) / 10.0);
    if (std::abs(want - old) < 0.001) {
        return old > 0 ? QStringLiteral("歌词已经延后到上限 +%1 秒了，再按也不动了").arg(int(kLyricShiftLimit))
                       : QStringLiteral("歌词已经提前到下限 -%1 秒了，再按也不动了").arg(int(kLyricShiftLimit));
    }
    if (std::abs(want) < 0.001)
        m_lyricShifts.remove(t.identityKey());
    else {
        m_lyricShifts.insert(t.identityKey(), want);
    }
    emit lyricShiftChanged();
    return QStringLiteral("歌词%1").arg(lyricShiftText());
}

QString PlayerController::resetLyricShift() {
    const Track t = m_queue.currentTrack();
    const QString problem = lyricShiftProblem();
    if (t.isNull() || !problem.isEmpty()) return problem.isEmpty() ? QStringLiteral("现在没什么可校准的") : problem;
    if (std::abs(lyricShift()) < 0.001) return QStringLiteral("这一首本来就没校准过");
    m_lyricShifts.remove(t.identityKey());
    emit lyricShiftChanged();
    return QStringLiteral("歌词校准已归零（文件自带的 offset 仍然生效）");
}

QString PlayerController::setLyricShift(double seconds) {
    const Track t = m_queue.currentTrack();
    if (t.isNull()) return QStringLiteral("现在没有正在播的曲目，没什么可校准");
    const double v = clampShift(std::round(seconds * 10.0) / 10.0);
    if (std::abs(v) < 0.001)
        m_lyricShifts.remove(t.identityKey());
    else {
        m_lyricShifts.insert(t.identityKey(), v);
    }
    emit lyricShiftChanged();
    return QStringLiteral("歌词%1").arg(lyricShiftText());
}

void PlayerController::setLyricShiftTable(const QMap<QString, double> &t) {
    m_lyricShifts = t;
    emit lyricShiftChanged();
}

// MARK: - 无缝播放（F01）

void PlayerController::setGaplessEnabled(bool on) {
    if (on == m_gapless) return;
    m_gapless = on;
    if (!on) {
        m_prefetchDecoder.reset();
        m_prefetchKey.clear();
    }
    if (!on)
        cancelPrefetch();
    else
        schedulePrefetch(); // 当场补预取，当前曲已排进设备才合法
}

// MARK: - 输出设备（F07）

void PlayerController::setOutputDevice(const QString &uid) {
    if (uid == m_engine->outputDevice()) return;
    const bool reconnect = m_radioWantsPlay && currentTrack().isRadio();
    cancelPrefetch();
    if (reconnect) m_engine->stop();
    m_engine->setOutputDevice(uid);
    if (reconnect)
        retryRadio();
    else
        schedulePrefetch();
}
QString PlayerController::outputDevice() const {
    return m_engine->outputDevice();
}

// MARK: - 睡眠定时器（F09）

void PlayerController::setSleepMinutes(int minutes) {
    if (minutes <= 0) {
        cancelSleepTimer();
        return;
    }
    if (minutes > 7 * 24 * 60) return;
    m_sleepMinutes = minutes;
    m_sleepPlan = SleepPlan::Countdown;
    m_sleepDeadlineMs = m_sleepClock() + qint64(minutes) * 60000;
    m_sleepTrackId.clear();
    m_sleepFading = false;
    applySleepFade(); // 从上一轮淡出残值拉回 1
    m_sleepTick.start();
    schedulePrefetch(); // 从 AfterTrack 换过来时重新排预取，不断歌
    emit sleepChanged();
}

void PlayerController::setSleepAfterCurrentTrack() {
    cancelPrefetch();
    const Track t = m_queue.currentTrack();
    if (t.isNull() || t.isRadio()) {
        emit sleepChanged();
        return;
    } // 无曲 / 电台无「播完」
    m_sleepPlan = SleepPlan::AfterTrack;
    const QueueItem *cur = m_queue.current();
    m_sleepTrackId = cur ? cur->id.toString() : QString();
    m_sleepFading = false;
    applySleepFade();
    m_prefetchDecoder.reset(); // 下一曲不该抢排进流（否则那一条播完会接上）
    m_prefetchKey.clear();
    m_sleepTick.start();
    emit sleepChanged();
}

void PlayerController::cancelSleepTimer() {
    if (m_sleepPlan == SleepPlan::Off) return;
    m_sleepPlan = SleepPlan::Off;
    m_sleepTick.stop();
    m_sleepFading = false;
    applySleepFade();   // 只把链路增益放回 1，不碰用户音量/静音
    schedulePrefetch(); // 取消后重新排预取
    emit sleepChanged();
}

void PlayerController::setSleepFadeEnabled(bool on) {
    if (on == m_sleepFade) return;
    m_sleepFade = on;
    applySleepFade();
    emit sleepChanged();
}

int PlayerController::sleepRemainingSeconds() const {
    if (m_sleepPlan != SleepPlan::Countdown) return 0;
    const qint64 rem = (m_sleepDeadlineMs - m_sleepClock()) / 1000;
    return int(rem > 0 ? rem : 0);
}

QString PlayerController::sleepStatusText() const {
    switch (m_sleepPlan) {
    case SleepPlan::Off:
        return QString();
    case SleepPlan::AfterTrack:
        return QStringLiteral("播完当前曲后停止：%1")
            .arg(currentTrack().isNull() ? QString() : currentTrack().title().left(32));
    case SleepPlan::Countdown: {
        const int s = sleepRemainingSeconds();
        return QStringLiteral("剩 %1:%2").arg(s / 60, 2, 10, QLatin1Char('0')).arg(s % 60, 2, 10, QLatin1Char('0')) +
               QStringLiteral("（%1 分钟定时）").arg(m_sleepMinutes);
    }
    }
    return QString();
}

void PlayerController::sleepTick() {
    if (m_sleepPlan == SleepPlan::Off) {
        m_sleepTick.stop();
        return;
    }
    if (m_sleepPlan == SleepPlan::Countdown) {
        const double rem = (m_sleepDeadlineMs - m_sleepClock()) / 1000.0;
        if (m_sleepFade && rem <= kSleepFadeSeconds && rem > 0 && !m_sleepFading) {
            m_sleepFading = true;
            m_engine->setFadeTarget(0.0, std::max(0.1, rem)); // 剩余秒里线性淡到无声
        }
        if (rem <= 0) {
            fireSleep(QStringLiteral("到点"));
            return;
        }
    } else if (m_sleepPlan == SleepPlan::AfterTrack) {
        const double remaining = duration() - position();
        if (m_sleepFade && remaining > 0 && remaining <= kSleepFadeSeconds && !m_sleepFading) {
            m_sleepFading = true;
            m_engine->setFadeTarget(0, remaining);
        }
        const QueueItem *cur = m_queue.current();
        if (!cur || cur->id.toString() != m_sleepTrackId) { // 手动跳离那一曲：计划作废
            m_sleepPlan = SleepPlan::Off;
            m_sleepTick.stop();
            applySleepFade();
            schedulePrefetch();
            emit sleepChanged();
            return;
        }
    }
    emit sleepChanged(); // 刷新倒计时文案
}

void PlayerController::fireSleep(const QString &reason) {
    Q_UNUSED(reason);
    m_sleepPlan = SleepPlan::Off;
    m_sleepTick.stop();
    m_sleepFading = false;
    stop();           // 内部会重排预取（预取在 AfterTrack 时已被清）
    applySleepFade(); // 已无声，这里只把增益放回 1，不带到下次开播
    emit sleepChanged();
}

// 把淡出增益推到输出链路（fade 那一层，不碰用户音量）。装载/心跳/取消/收摊都推一次，
// 漏一处会把上一轮衰减值带到下一曲。m_sleepFading 假 → 目标 1。
void PlayerController::applySleepFade() {
    m_engine->setFadeTarget(m_sleepFading ? 0.0 : 1.0, 0.0);
}
