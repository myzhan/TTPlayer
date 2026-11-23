#include "Regression.h"
#include "audio/AudioEngine.h"
#include "library/Collections.h"
#include "playback/PlayerController.h"
#include "media/AudioConvert.h"
#include "media/Archive.h"
#include "media/FFmpeg.h"
#include "media/MidiSequence.h"
#include "media/SequencedAudioSource.h"
#include <thread>
#include "ui/MainWindow.h"
#include "ui/PlaylistWindow.h"
#include "ui/PlaylistView.h"
#include "ui/EqWindow.h"
#include "ui/LyricWindow.h"
#include "ui/CoverWindow.h"
#include "ui/PropertyWindow.h"
#include "ui/ConvertWindow.h"
#include "ui/SettingsWindow.h"
#include "ui/SkinDock.h"
#include "ui/SpectrumView.h"
#include "ui/Theme.h"
#include "ui/TransportBar.h"
#include "ui/AppIcon.h"
#include "ui/TrayController.h"
#include <QFontMetricsF>
#include <QLabel>
#include <QScrollBar>
#include <QStyleOptionSlider>
#include <QWheelEvent>
#include <QPainter>
#include <QSystemTrayIcon>
#include <QKeyEvent>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QDialog>
#include <QDialogButtonBox>
#include <QInputDialog>
#include <QMessageBox>
#include <QPushButton>
#include <QTimer>
#include <QMenu>
#include <QContextMenuEvent>
#include <QDropEvent>
#include <QDragEnterEvent>
#include <QMimeData>
#include "media/PlaylistM3U.h"
#include "library/Importer.h"
#include "models/RadioPresets.h"
#include "media/CoverArt.h"
#include "media/Lyric.h"
#include "media/CueSheet.h"
#include "audio/RadioQuality.h"
#include "ui/SkinWidgets.h"
#include <QElapsedTimer>
#include <QApplication>
#include <QDataStream>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QFutureWatcher>
#include <QScreen>
#include <QJsonDocument>
#include <QJsonArray>
#include <QThread>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <cstdio>
#include <limits>
#include <vector>
#ifdef Q_OS_WIN
#include <QAbstractNativeEventFilter>
#include <QFontInfo>
#include <QWindow>
#include <windows.h>
#include <shellapi.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#include <CoreAudio/CoreAudio.h>

namespace {
// CFStringRef 是引用计数指针，CoreAudio 要的“缓冲区大小”就是一个对象指针
constexpr UInt32 kCfStringRefSize = sizeof(void *);
} // namespace
#endif

namespace {
// 每个存档用例独立连接与目录，窗口必须先于守卫析构。
class ScopedTestState {
public:
    ScopedTestState() : m_previous(qgetenv("TTPLAYER_QT_STATE")) {
        LibraryStore::closeDatabase();
        qputenv("TTPLAYER_QT_STATE", (m_dir.path() + "/state.json").toUtf8());
    }
    ~ScopedTestState() {
        LibraryStore::closeDatabase();
        if (m_previous.isNull())
            qunsetenv("TTPLAYER_QT_STATE");
        else
            qputenv("TTPLAYER_QT_STATE", m_previous);
    }

private:
    QTemporaryDir m_dir;
    QByteArray m_previous;
};

// 只计真实事件循环触发的重绘，不用 grab/render 掩盖漏掉的全窗更新。
class ShellPaintObserver final : public QObject {
public:
    int paints = 0;

protected:
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::Paint) ++paints;
        return false;
    }
};

// 纯文本基准也走 QWidget：FreeType 对 QWidget / QImage 请求的字形缓存格式不同，
// 直接在 QImage 上画字会把栅格化差异误报成遮挡。同屏父对象同时保证点字号 DPI 一致。
class VolumeReadoutReference final : public QWidget {
public:
    VolumeReadoutReference(QWidget *source, const QRectF &rect, const QString &text, const QColor &color,
                           int alignment = Qt::AlignVCenter | Qt::AlignRight)
        : QWidget(source), m_rect(rect), m_text(text), m_color(color), m_alignment(alignment) {
        resize(source->size());
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing, true);
        painter.setFont(font());
        painter.setPen(m_color);
        painter.drawText(m_rect, m_alignment, m_text);
    }

private:
    QRectF m_rect;
    QString m_text;
    QColor m_color;
    int m_alignment;
};

#ifdef Q_OS_WIN
// 用真实 HWND 的 owner/扩展样式核对任务栏资格；offscreen 的 Qt flags 不能充当此证据。
bool ownedToolWindow(QWidget *panel, QWidget *owner) {
    const HWND hwnd = reinterpret_cast<HWND>(panel->winId());
    const LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    return (style & WS_EX_TOOLWINDOW) != 0 && (style & WS_EX_APPWINDOW) == 0 &&
           GetWindow(hwnd, GW_OWNER) == reinterpret_cast<HWND>(owner->winId());
}

int nativeTaskbarWindowCount() {
    int count = 0;
    const auto visit = [](HWND hwnd, LPARAM context) -> BOOL {
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        const LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if (pid == GetCurrentProcessId() && IsWindowVisible(hwnd) && (style & WS_EX_TOOLWINDOW) == 0 &&
            ((style & WS_EX_APPWINDOW) != 0 || GetWindow(hwnd, GW_OWNER) == nullptr))
            ++*reinterpret_cast<int *>(context);
        return TRUE;
    };
    return EnumWindows(visit, reinterpret_cast<LPARAM>(&count)) ? count : -1;
}

// 监测整个切换过程，而不只比较最终样式；旧 Qt 路径会先移除再恢复 layered 位。
// 不用 QWidget::grab/render 主动重绘，避免掩盖原生合成表面被重置的问题。
class PinSurfaceMonitor final : public QAbstractNativeEventFilter {
public:
    explicit PinSurfaceMonitor(const QList<QWidget *> &windows) {
        for (QWidget *window : windows) {
            Snapshot snapshot;
            snapshot.window = window;
            snapshot.hwnd = reinterpret_cast<HWND>(window->winId());
            snapshot.owner = GetWindow(snapshot.hwnd, GW_OWNER);
            snapshot.style = GetWindowLongPtrW(snapshot.hwnd, GWL_EXSTYLE) & ~WS_EX_TOPMOST;
            snapshot.flags = window->windowHandle()->flags();
            m_intact &= GetWindowRect(snapshot.hwnd, &snapshot.rect) != FALSE && (snapshot.style & WS_EX_LAYERED) != 0;
            m_windows.append(snapshot);
        }
        qApp->installNativeEventFilter(this);
    }
    ~PinSurfaceMonitor() override { qApp->removeNativeEventFilter(this); }

    bool nativeEventFilter(const QByteArray &, void *message, qintptr *) override {
        const auto *event = static_cast<const MSG *>(message);
        for (const Snapshot &snapshot : std::as_const(m_windows)) {
            if (event->hwnd != snapshot.hwnd) continue;
            if (event->message == WM_STYLECHANGING && event->wParam == static_cast<WPARAM>(GWL_EXSTYLE)) {
                const auto *styles = reinterpret_cast<const STYLESTRUCT *>(event->lParam);
                m_intact &= (styles->styleNew & WS_EX_LAYERED) != 0;
            }
            if (event->message == WM_NCDESTROY || (event->message == WM_SHOWWINDOW && !event->wParam)) m_intact = false;
        }
        return false;
    }

    bool unchanged(bool pinned) const {
        if (!m_intact) return false;
        for (const Snapshot &snapshot : m_windows) {
            RECT rect{};
            const LONG_PTR style = GetWindowLongPtrW(snapshot.hwnd, GWL_EXSTYLE);
            if (reinterpret_cast<HWND>(snapshot.window->internalWinId()) != snapshot.hwnd ||
                !IsWindowVisible(snapshot.hwnd) || GetWindow(snapshot.hwnd, GW_OWNER) != snapshot.owner ||
                (style & ~WS_EX_TOPMOST) != snapshot.style || ((style & WS_EX_TOPMOST) != 0) != pinned ||
                !GetWindowRect(snapshot.hwnd, &rect) || !EqualRect(&rect, &snapshot.rect) ||
                snapshot.window->windowHandle()->flags() != snapshot.flags)
                return false;
        }
        return true;
    }

private:
    struct Snapshot {
        QWidget *window = nullptr;
        HWND hwnd = nullptr, owner = nullptr;
        LONG_PTR style = 0;
        RECT rect{};
        Qt::WindowFlags flags;
    };
    QList<Snapshot> m_windows;
    bool m_intact = true;
};
#endif

// 右键菜单树摊平成「父/子/项」：探针据此核对分组与隐藏规则
QStringList menuPaths(const QMenu &menu, const QString &prefix = QString()) {
    QStringList out;
    for (QAction *action : menu.actions()) {
        if (action->isSeparator()) continue;
        if (QMenu *sub = action->menu())
            out += menuPaths(*sub, prefix + action->text() + QLatin1Char('/'));
        else
            out << prefix + action->text();
    }
    return out;
}

// 菜单树里按文字找动作（含子菜单）
QAction *findMenuAction(QMenu &menu, const QString &text) {
    if (text.isEmpty()) return nullptr; // 只查看菜单时不能把空标题分隔线当作待执行动作。
    for (QAction *action : menu.actions()) {
        if (QMenu *sub = action->menu()) {
            if (QAction *found = findMenuAction(*sub, text)) return found;
        } else if (action->text() == text) {
            return action;
        }
    }
    return nullptr;
}

QByteArray wave(int seconds = 30, int rate = 44100) {
    QByteArray bytes;
    QDataStream w(&bytes, QIODevice::WriteOnly);
    w.setByteOrder(QDataStream::LittleEndian);
    const int size = seconds * rate * 4;
    w.writeRawData("RIFF", 4);
    w << quint32(size + 36);
    w.writeRawData("WAVEfmt ", 8);
    w << quint32(16) << quint16(1) << quint16(2) << quint32(rate) << quint32(rate * 4) << quint16(4) << quint16(16);
    w.writeRawData("data", 4);
    w << quint32(size);
    for (int i = 0; i < seconds * rate; ++i) {
        const qint16 value = qint16(double(i) / (seconds * rate) * 20000);
        w << value << value;
    }
    return bytes;
}
class GateSource final : public StreamSource {
public:
    QByteArray data;
    qint64 pos = 0;
    std::mutex mutex;
    std::condition_variable cv;
    bool armed = false, blocked = false, released = false, allowSeek = true;
    int64_t read(uint8_t *b, int n) override {
        {
            std::unique_lock<std::mutex> lk(mutex);
            if (armed && !released) {
                blocked = true;
                cv.notify_all();
                cv.wait(lk, [&] { return released; });
            }
        }
        n = int(std::min<qint64>(n, std::min<qint64>(4096, data.size() - pos)));
        if (n <= 0) return 0;
        memcpy(b, data.constData() + pos, size_t(n));
        pos += n;
        return n;
    }
    bool seekable() const override { return allowSeek; }
    int64_t seek(int64_t offset, int whence) override {
        if (whence == AVSEEK_SIZE) return data.size();
        whence &= ~AVSEEK_FORCE;
        pos = whence == SEEK_SET ? offset : whence == SEEK_CUR ? pos + offset : data.size() + offset;
        return pos;
    }
    void cancel() override {
        std::lock_guard<std::mutex> lk(mutex);
        released = true;
        cv.notify_all();
    }
};
}

class RegressionTests {
public:
    QTextStream &out;
    int failed = 0;
    void check(const char *name, bool ok) {
        out << "REVIEW_PROBE " << name << (ok ? " PASS" : " FAIL") << '\n';
        if (!ok) ++failed;
    }
    static bool waitFor(const std::function<bool()> &condition, int timeout = 3000) {
        QElapsedTimer timer;
        timer.start();
        while (!condition() && timer.elapsed() < timeout) {
            QCoreApplication::processEvents();
            QThread::msleep(1);
        }
        return condition();
    }
    int sequences(const QString &suite) {
        const bool isMidi = suite == QLatin1String("MIDI");
        const QString root = qEnvironmentVariable("TTPLAYER_TESTDIR") + "/sequences/";
        const auto benchmark = [&](int seconds) {
            QElapsedTimer timer;
            timer.start();
            auto decoder = Decoder::openFile(root + QStringLiteral("long%1.mid").arg(seconds));
            const double openMs = timer.nsecsElapsed() / 1000000.0;
            std::array<float, 1024> left{}, right{};
            const int first = decoder ? decoder->read(left.data(), right.data(), 1024, 0) : 0;
            const double firstFrameMs = timer.nsecsElapsed() / 1000000.0;
            timer.restart();
            const int got = decoder ? decoder->read(left.data(), right.data(), 1024, int64_t(seconds - 1) * 48000) : 0;
            out << "SEQUENCE_BENCH seconds=" << seconds << " open_ms=" << openMs << " first_frame_ms=" << firstFrameMs
                << " cold_seek_ms=" << timer.nsecsElapsed() / 1000000.0 << " frames=" << got << '\n';
            check(qPrintable(QStringLiteral("MIDI_benchmark_%1").arg(seconds)), first == 1024 && got == 1024);
        };
        // 独立进程仅测一个长度，避免完整回归的历史分配干扰峰值内存口径。
        const int benchmarkOnly = qEnvironmentVariableIntValue("TTPLAYER_SEQUENCE_BENCH_ONLY");
        if (isMidi && (benchmarkOnly == 300 || benchmarkOnly == 1800)) {
            benchmark(benchmarkOnly);
            return failed;
        }
        const QStringList names = isMidi ? QStringList{QStringLiteral("旋律.MID"),
                                                       "tempo.midi",
                                                       "words.kar",
                                                       "rmid.mid",
                                                       "smpte24.mid",
                                                       "smpte25.mid",
                                                       "smpte29.mid",
                                                       "smpte30.mid",
                                                       "running.mid",
                                                       "piano.mid",
                                                       "strings.mid",
                                                       "drums.mid",
                                                       "bank.mid"}
                                         : QStringList{"sample.mod", "sample.xm", "sample.s3m", "sample.it"};
        const auto label = [&](const QString &name) { return (suite + "_" + name).toUtf8(); };
        const auto bytes = [](const QString &path) {
            QFile file(path);
            return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
        };
        QHash<QString, std::vector<float>> signatures;
        for (const QString &name : names) {
            QString error;
            QElapsedTimer timer;
            timer.start();
            auto decoder = Decoder::openFile(root + name, {}, &error);
            check(label("open_" + name).constData(), bool(decoder));
            if (!decoder) {
                out << "SEQUENCE_ERROR " << name << " " << error << '\n';
                continue;
            }
            const double openMs = timer.nsecsElapsed() / 1000000.0;
            check(label("metadata_" + name).constData(),
                  decoder->channelCount() == 2 && decoder->sampleRate() == 48000 && decoder->bitRateKbps() == 0 &&
                      decoder->formatName() == (isMidi ? QStringLiteral("MIDI") : QFileInfo(name).suffix().toUpper()));
            const int64_t frames = decoder->totalFrames();
            if (frames <= 48000 || frames >= int64_t(48000) * 10) {
                check(label("bounded_fixture_" + name).constData(), false);
                continue;
            }
            std::vector<float> left(size_t(frames), 0), right(size_t(frames), 0);
            double firstFrameMs = 0;
            int64_t pos = 0;
            while (pos < frames) {
                const int got = decoder->read(left.data() + pos, right.data() + pos,
                                              int(std::min<int64_t>(1024, frames - pos)), pos);
                if (!got) break;
                if (pos == 0) firstFrameMs = timer.nsecsElapsed() / 1000000.0;
                pos += got;
            }
            double power = 0;
            for (const float value : left)
                power += value * value;
            for (const float value : right)
                power += value * value;
            check(label("finite_pcm_" + name).constData(), frames > 48000 && frames < int64_t(48000) * 10 &&
                                                               pos == frames && std::isfinite(power) && power > 0.01);
            std::array<float, 1024> seekL{}, seekR{};
            check(label("single_pass_eof_" + name).constData(),
                  decoder->read(seekL.data(), seekR.data(), 1024, frames) == 0);
            bool exact = true;
            for (const int64_t target : {int64_t(36000), int64_t(12000), int64_t(60000), int64_t(0)}) {
                if (target + 1024 > pos) {
                    exact = false;
                    break;
                }
                const int got = decoder->read(seekL.data(), seekR.data(), 1024, target);
                if (got != 1024) {
                    exact = false;
                    break;
                }
                for (int i = 0; i < got; ++i)
                    exact &= std::abs(seekL[size_t(i)] - left[size_t(target + i)]) < 0.00001f &&
                             std::abs(seekR[size_t(i)] - right[size_t(target + i)]) < 0.00001f;
            }
            check(label("seek_sustain_pcm_" + name).constData(), exact);
            signatures.insert(name,
                              std::vector<float>(left.begin(), left.begin() + std::min<size_t>(left.size(), 48000)));
            if (name == QStringLiteral("旋律.MID") || name == QLatin1String("rmid.mid"))
                check(label("duration_" + name).constData(), frames == 168000);
            if (name == QLatin1String("tempo.midi")) check("MIDI_tempo_map", frames == 216000);
            if (name.startsWith("smpte")) {
                const int64_t expected = name == "smpte29.mid" ? 142446 : 144000;
                check(label("timebase_" + name).constData(), std::abs(frames - expected) <= 1);
            }
            out << "SEQUENCE_METRIC " << name << " open_ms=" << openMs << " first_frame_ms=" << firstFrameMs
                << " frames=" << frames << " energy=" << power << '\n';
        }
        for (const QString &extension :
             isMidi ? QStringList{"mid", "midi", "kar"} : QStringList{"mod", "xm", "s3m", "it"})
            check(label("entry_" + extension).constData(), ff::playableExtensions().contains(extension) &&
                                                               Importer::fileDialogFilter().contains("*." + extension));
        const QStringList bad = isMidi ? QStringList{"format2.mid", "truncated.mid",  "badvlq.mid",   "device.mid",
                                                     "ports.mid",   "eventlimit.mid", "timelimit.mid"}
                                       : QStringList{"bad.mod", "bad.xm", "bad.s3m", "bad.it"};
        for (const QString &name : bad) {
            Track track(QUrl::fromLocalFile(root + name));
            Importer::probe(track);
            check(label("reject_" + name).constData(), !track.decodeProblem().isEmpty());
        }
        const QStringList archived = Archive::listAudioEntries(root + "sequences.zip");
        for (const QString &name : isMidi ? QStringList{QStringLiteral("旋律.MID"), "words.kar"} : names) {
            const QString entry = QStringLiteral("中文/") + name;
            Track track(Archive::entryUrl(root + "sequences.zip", entry));
            const QString identity = track.identityKey();
            Importer::probe(track);
            check(label("archive_" + name).constData(), archived.contains(entry) && track.decodeProblem().isEmpty() &&
                                                            track.identityKey() == identity &&
                                                            !AudioConvert::canConvert(track));
        }
        const QString source = root + names.front();
        const std::atomic<bool> keepGoing{false};
        QTemporaryDir converted;
        for (const QString &name : isMidi ? QStringList{names.front(), "words.kar"} : names) {
            for (const auto codec : {AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_FLAC, AV_CODEC_ID_MP3}) {
                EncodeTarget target;
                target.codecId = codec;
                target.sampleRate = 44100;
                target.channels = 2;
                if (codec == AV_CODEC_ID_MP3) target.encoderName = "libmp3lame";
                const QString extension = codec == AV_CODEC_ID_PCM_S16LE ? "wav"
                                          : codec == AV_CODEC_ID_FLAC    ? "flac"
                                                                         : "mp3";
                const QString destination = converted.filePath(name + "." + extension);
                const auto result = AudioEncoder::convert(root + name, destination, target, {}, keepGoing);
                auto decoder = result.ok ? Decoder::openFile(destination) : nullptr;
                std::array<float, 1024> left{}, right{};
                const int got = decoder ? decoder->read(left.data(), right.data(), 1024, 4410) : 0;
                check(label("convert_" + name + "_" + extension).constData(),
                      result.ok && decoder && decoder->sampleRate() == 44100 && got == 1024);
            }
        }
        if (isMidi) {
            check("MIDI_program_changes_timbre", signatures.value("piano.mid") != signatures.value("strings.mid"));
            check("MIDI_channel10_drums", signatures.value("piano.mid") != signatures.value("drums.mid"));
            check("MIDI_missing_bank_GM_fallback", !signatures.value("bank.mid").empty() &&
                                                       signatures.value("bank.mid") == signatures.value("piano.mid"));
            Track kar(QUrl::fromLocalFile(root + "words.kar"));
            Importer::probe(kar);
            const Lyric words = Lyric::loadForTrack(kar);
            check("MIDI_KAR_timed_embedded_priority",
                  words.lines().size() == 2 && words.lines()[0].text == QStringLiteral("第一句") &&
                      words.lines()[1].text == QStringLiteral("第二句") &&
                      std::abs(words.lines()[1].time - 0.5) < 0.001 && kar.artist().isEmpty());
            Track plain(QUrl::fromLocalFile(source));
            Importer::probe(plain);
            const Lyric external = Lyric::loadForTrack(plain);
            check("MIDI_external_lyrics_fallback",
                  external.isTimed() && external.lines()[0].text == QStringLiteral("外置回退"));
            MidiSequence sequence;
            QString error;
            QByteArray oversized(MidiSequence::kMaxBytes + 1, '\0');
            check("MIDI_size_limit", !MidiSequence::parse(oversized, sequence, error) && error.contains("32 MiB"));
            const std::atomic<bool> cancelled{true};
            check("MIDI_parser_cancel", !MidiSequence::parse(bytes(source), sequence, error, &cancelled));
            bool truncations = true;
            const QByteArray original = bytes(source);
            for (qsizetype size = 0; size < original.size(); ++size)
                truncations &= !MidiSequence::parse(original.left(size), sequence, error);
            check("MIDI_all_truncations_rejected", truncations);
            check("MIDI_stable_track_event_order",
                  MidiSequence::parse(bytes(root + "stable.mid"), sequence, error) && sequence.events.size() == 2 &&
                      sequence.events[0].status == 0xc0 && sequence.events[1].status == 0x90);
            check("MIDI_GM_GS_XG_unknown_sysex",
                  MidiSequence::parse(bytes(root + "reset.mid"), sequence, error) && sequence.events.size() == 3 &&
                      std::all_of(sequence.events.begin(), sequence.events.end(),
                                  [](const MidiEvent &event) { return event.status == 0xf0; }));
            const bool legacyParsed = MidiSequence::parse(bytes(root + "legacy.kar"), sequence, error);
            const Lyric legacy = Lyric::parseEmbedded(sequence.tags.value("lyrics"));
            check("MIDI_KAR_legacy_encoding_long_time",
                  legacyParsed && sequence.tags.value("title") == "Legacy" && legacy.lines().size() == 2 &&
                      legacy.lines()[0].text == QStringLiteral("中文") && legacy.lines()[1].time == 6000);
            std::atomic<bool> abort{false};
            Importer::Result imported;
            std::thread importWorker([&] { imported = Importer::read({source}, true, &abort); });
            QThread::msleep(5);
            abort.store(true);
            importWorker.join();
            check("MIDI_import_initialization_cancel", imported.cancelled && imported.tracks.empty());
            abort.store(false);
            AudioEncoder::Result encoded;
            EncodeTarget target;
            target.codecId = AV_CODEC_ID_PCM_S16LE;
            const QString output = converted.filePath("cancel.wav");
            std::thread convertWorker(
                [&] { encoded = AudioEncoder::convert(root + "long1800.mid", output, target, {}, abort); });
            QThread::msleep(5);
            abort.store(true);
            convertWorker.join();
            check("MIDI_convert_initialization_cancel_cleanup", encoded.cancelled && !QFileInfo::exists(output));
        } else {
            QString error;
            auto stream = SequencedAudioSource::openFile(source, error, {});
            const auto length = stream ? stream->seek(0, AVSEEK_SIZE) : 0;
            check("MODULE_virtual_size_seek_bounds",
                  stream && length > 80 && stream->seek(0, SEEK_END) == length && stream->seek(1, SEEK_END) < 0 &&
                      stream->seek(-1, SEEK_SET) < 0 && stream->seek(0, SEEK_SET) == 0);
            QFile oversized(converted.filePath("oversized.it"));
            const bool created = oversized.open(QIODevice::WriteOnly) && oversized.write("IMPM", 4) == 4 &&
                                 oversized.resize(64 * 1024 * 1024 + 1);
            oversized.close();
            auto rejected = Decoder::openFile(oversized.fileName(), {}, &error);
            check("MODULE_size_limit", created && !rejected && error.contains("64 MiB"));
        }
        // producer 真实合成/冷定位期间 stop 和切歌；旧 EOF 不得重新点亮新曲。
        bool cancellation = true;
        auto engine = AudioEngine::create();
        int finished = 0;
        engine->onFinished = [&] { ++finished; };
        for (int attempt = 0; attempt < 30; ++attempt) {
            auto decoder = Decoder::openFile(isMidi ? root + "long1800.mid" : source);
            if (!decoder) {
                cancellation = false;
                break;
            }
            cancellation &= engine->play(std::move(decoder), 0, -1, false);
            std::shared_ptr<Decoder> observer;
            {
                const std::lock_guard lock(engine->m_mutex);
                observer = engine->m_decoder;
            }
            cancellation &= engine->seekSeconds(isMidi ? 1799 : 2.5) && engine->resume();
            QThread::msleep(2);
            cancellation &= engine->seekSeconds(0.25);
            engine->stop();
            cancellation &= observer && observer->isCancelled();
            auto next = Decoder::openFile(qEnvironmentVariable("TTPLAYER_TESTDIR") + "/demo01.wav");
            cancellation &= bool(next) && engine->play(std::move(next), 0, -1, false);
            QCoreApplication::processEvents();
            cancellation &= !engine->isPlaying() && engine->durationSeconds() > 10 && finished == 0;
            engine->stop();
        }
        engine.reset();
        check(label("cancel_seek_stop_switch_owner_30").constData(), cancellation);
        if (isMidi && qEnvironmentVariableIntValue("TTPLAYER_SEQUENCE_BENCH") != 0) {
            for (const int seconds : {300, 1800})
                benchmark(seconds);
        }
        return failed;
    }
    // 内嵌歌词真实探针：复用已有后台开流/预取，不改源文件或用户存档。
    void embeddedLyrics() {
        const QString root = qEnvironmentVariable("TTPLAYER_TESTDIR") + "/embedded/";
        const auto read = [](const QString &path) {
            QFile file(path);
            return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
        };
        QHash<QString, QByteArray> original;
        for (const QString &name :
             {QStringLiteral("timed.mp3"), QStringLiteral("plain.mp3"), QStringLiteral("empty.mp3"),
              QStringLiteral("bare.mp3"), QStringLiteral("tag.flac"), QStringLiteral("tag.m4a"),
              QStringLiteral("tag.ogg"), QStringLiteral("lyrics.zip"), QStringLiteral("timed.lrc"),
              QStringLiteral("plain.lrc"), QStringLiteral("empty.lrc"), QStringLiteral("bare.lrc")})
            original.insert(name, read(root + name));
        check("embedded_fixtures_present", std::all_of(original.cbegin(), original.cend(),
                                                       [](const QByteArray &bytes) { return !bytes.isEmpty(); }));
        if (original.value("timed.mp3").isEmpty()) return;
        const QString firstLine = QStringLiteral("内嵌第一句");
        for (const QString &name : {QStringLiteral("timed.mp3"), QStringLiteral("tag.flac"), QStringLiteral("tag.m4a"),
                                    QStringLiteral("tag.ogg")}) {
            auto decoder = Decoder::openFile(root + name);
            const Lyric lyric = decoder ? Lyric::parseEmbedded(Lyric::embeddedText(decoder->tags())) : Lyric{};
            check(qPrintable("embedded_decode_" + name), lyric.isTimed() && lyric.lines().front().text == firstLine);
            if (name == "timed.mp3") check("embedded_mp3_real_USLT", decoder && decoder->tags().contains("lyrics-eng"));
            Track imported(QUrl::fromLocalFile(root + name));
            Importer::probe(imported);
            const Lyric importedLyric = Lyric::loadForTrack(imported);
            check(qPrintable("embedded_import_" + name), imported.decodeProblem().isEmpty() &&
                                                             importedLyric.isTimed() &&
                                                             importedLyric.lines().front().text == firstLine);
        }
        Track timed(QUrl::fromLocalFile(root + "timed.mp3"));
        Track plain(QUrl::fromLocalFile(root + "plain.mp3"));
        Track empty(QUrl::fromLocalFile(root + "empty.mp3"));
        Track bare(QUrl::fromLocalFile(root + "bare.mp3"));
        Track archived(Archive::entryUrl(root + "lyrics.zip", "disc/timed.mp3"));
        Importer::probe(archived);
        const Lyric archiveLyric = Lyric::loadForTrack(archived);
        check("embedded_archive_tags", archiveLyric.isTimed() && archiveLyric.lines().front().text == firstLine);
        auto engine = AudioEngine::create();
        PlayerController ctl(engine);
        ctl.setGaplessEnabled(false);
        ctl.setTracks({timed, plain, empty, bare, archived});
        LyricWindow window(&ctl);
        window.show();
        auto *editor = window.findChild<QPlainTextEdit *>("plainLyrics");
        ctl.playRowAt(0); // 不先 probe，确保新建/重启后曲目也会从播放解码器读取标签。
        check("embedded_playback_mp3_USLT_utf16", waitFor([&] {
                  return ctl.currentLyric().isTimed() && ctl.currentLyric().lines().front().text == firstLine;
              }));
        ctl.togglePlay();
        check("embedded_timed_shift",
              ctl.lyricShiftApplies() && std::abs(ctl.currentLyric().fileOffset() - 0.1) < 1e-9 &&
                  ctl.setLyricShift(0.5).contains("延后") && std::abs(ctl.alignedLyricTime(1) - 0.5) < 1e-9 && editor &&
                  editor->isHidden());
        ctl.playRowAt(1);
        check("embedded_pending_clears_previous", ctl.currentLyric().isEmpty());
        check("embedded_playback_mp3_USLT_utf8_plain",
              waitFor([&] { return ctl.currentLyric().plainText().startsWith(QStringLiteral("纯文本歌词第 1 行")); }));
        ctl.togglePlay();
        QCoreApplication::processEvents();
        check("embedded_plain_not_calibratable",
              !ctl.lyricShiftApplies() && ctl.nudgeLyricShift(0.5).contains("纯文本") &&
                  ctl.lyricShiftTable().value(plain.identityKey()) == 0 && ctl.alignedLyricTime(1) == 1);
        check("embedded_plain_widget_readable", editor && editor->isVisible() && editor->isReadOnly() &&
                                                    editor->toPlainText() == ctl.currentLyric().plainText() &&
                                                    editor->verticalScrollBar()->maximum() > 0);
        if (editor) {
            auto *bar = editor->verticalScrollBar();
            bar->setValue(bar->maximum());
            const int scroll = bar->value();
            emit ctl.positionTicked(2, 4);
            check("embedded_plain_position_does_not_scroll", scroll > 0 && bar->value() == scroll);
            bar->setValue(0);
            QImage image(editor->viewport()->size(), QImage::Format_ARGB32_Premultiplied);
            image.fill(Qt::transparent);
            editor->viewport()->render(&image, QPoint(), QRegion(), QWidget::RenderFlags{});
            bool opaqueText = false;
            for (int y = 0; y < image.height(); ++y)
                for (int x = 0; x < image.width(); ++x)
                    opaqueText |= qAlpha(image.pixel(x, y)) == 255;
            check("embedded_plain_glass_foreground",
                  !editor->viewport()->autoFillBackground() && image.pixelColor(0, 0).alpha() == 0 && opaqueText);
            editor->selectAll();
            check("embedded_plain_text_selectable", editor->textCursor().hasSelection());
        }
        for (const int row : {2, 3}) {
            ctl.playRowAt(row);
            check(row == 2 ? "embedded_empty_tag_falls_back" : "embedded_no_tag_falls_back", waitFor([&] {
                      return ctl.currentLyric().isTimed() &&
                             ctl.currentLyric().lines().front().text == QStringLiteral("外置歌词");
                  }));
        }
        ctl.playRowAt(4);
        check("embedded_archive_playback", waitFor([&] {
                  return ctl.currentLyric().isTimed() && ctl.currentLyric().lines().front().text == firstLine;
              }));
        ctl.stop();
        // 先发旧曲开流再立即换新曲/停止，晚回调不能覆盖新曲歌词，至少重复 30 次。
        bool switched = true, cancelled = true;
        for (int i = 0; i < 30; ++i) {
            ctl.playRowAt(0);
            ctl.playRowAt(1);
            switched &= waitFor([&] { return !ctl.currentLyric().plainText().isEmpty(); }) &&
                        ctl.currentTrack().identityKey() == plain.identityKey();
            ctl.stop();
            ctl.playRowAt(0);
            ctl.stop();
            cancelled &= waitFor([&] {
                return std::all_of(ctl.m_openWorkers.cbegin(), ctl.m_openWorkers.cend(),
                                   [](const auto &worker) { return worker.second->finished.load(); });
            });
            QCoreApplication::processEvents();
            cancelled &= ctl.currentLyric().isEmpty() && !ctl.isPlaying();
        }
        check("embedded_switch_generation_30", switched);
        check("embedded_cancel_generation_30", cancelled);
        Track restored(QUrl::fromLocalFile(root + "timed.mp3"));
        const QList<QueueItem> resume{{QUuid::createUuid(), restored}};
        const bool restoredOK = ctl.restoreResume(resume, 0, {}, 0.5, false);
        check("embedded_paused_resume_reloads_tags",
              restoredOK && waitFor([&] { return !ctl.m_openJob && ctl.currentLyric().isTimed(); }) &&
                  !ctl.isPlaying() && ctl.currentLyric().lines().front().text == firstLine);
        ctl.stop();
        // 从无标签曲真正无缝切到带标签曲，歌词缓存必须在引擎交接前就绪。
        Track next(QUrl::fromLocalFile(root + "timed.mp3"));
        const QList<QueueItem> gapless{{QUuid::createUuid(), bare}, {QUuid::createUuid(), next}};
        ctl.setGaplessEnabled(true);
        const bool gaplessOK = ctl.restoreResume(gapless, 0, {}, 3.0, false);
        // 暂停时 producer 不读取 PCM，先验下一曲 Decoder 已交给引擎，再恢复消费。
        const bool prepared = gaplessOK && waitFor([&] {
                                  std::lock_guard<std::mutex> lock(engine->m_mutex);
                                  return engine->m_next && engine->m_next->key == gapless[1].id.toString();
                              });
        check("embedded_gapless_prefetch_tags", prepared && !next.embeddedLyrics().isEmpty());
        int transitions = 0;
        const auto onTransition = engine->onTransition;
        engine->onTransition = [&, onTransition](const QString &key) {
            ++transitions;
            onTransition(key);
        };
        if (prepared) ctl.togglePlay();
        check("embedded_gapless_transition",
              prepared && waitFor(
                              [&] {
                                  return transitions == 1 && ctl.queue().currentIndex() == 1 &&
                                         ctl.currentLyric().isTimed() &&
                                         ctl.currentLyric().lines().front().text == firstLine;
                              },
                              5000));
        ctl.stop();
        engine->onTransition = onTransition;
        bool unchanged = true;
        for (auto file = original.cbegin(); file != original.cend(); ++file)
            unchanged &= read(root + file.key()) == file.value();
        check("embedded_sources_unchanged", unchanged);
    }

    // 驱动真实模态表单；超时自动取消，缺控件/旧对话框不会让整个 suite 永久阻塞。
    static bool driveRadioDialog(MainWindow &window, const std::function<void(QDialog &)> &input,
                                 const std::function<void()> &launch) {
        bool found = false;
        QTimer action, timeout;
        action.setSingleShot(true);
        timeout.setSingleShot(true);
        QObject::connect(&action, &QTimer::timeout, &window, [&] {
            if (auto *dialog = window.findChild<QDialog *>(QStringLiteral("radioInfoDialog"))) {
                found = true;
                input(*dialog);
            }
        });
        QObject::connect(&timeout, &QTimer::timeout, &window, [] {
            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget())) dialog->reject();
        });
        action.start(0);
        timeout.start(1000);
        launch();
        return found;
    }

    // 某个位置的样本峰值（左声道），用于比对增益是否真的生效
    static float peakAt(const QString &path, int64_t pos) {
        auto dec = Decoder::openFile(path);
        if (!dec) return -1.0f;
        std::vector<float> left(4096), right(4096);
        const int got = dec->read(left.data(), right.data(), 4096, pos);
        float peak = 0.0f;
        for (int i = 0; i < got; ++i)
            peak = std::max(peak, std::abs(left[static_cast<size_t>(i)]));
        return got > 0 ? peak : -1.0f;
    }
    // 格式转换：格式表 / 输出路径 / 参数翻译 / 真编解码回读（不开设备，不碰用户文件）
    int convert() {
        QTemporaryDir dir;
        const QString srcPath = dir.path() + "/ramp.wav";
        {
            QFile file(srcPath);
            file.open(QIODevice::WriteOnly);
            file.write(wave(2));
        }

        // —— 格式表必须都能真编（找不到编码器 = 这个构建被裁掉了）——
        QStringList ids;
        bool hasEncoder = true;
        for (const ConvertFormat &f : AudioConvert::formats()) {
            ids << f.id;
            // 外部库格式按 encoderName 找（mp3/vorbis/opus），其余按 codecId。
            const AVCodec *enc = f.encoderName
                                     ? avcodec_find_encoder_by_name(f.encoderName)
                                     : (f.codecId != AV_CODEC_ID_NONE ? avcodec_find_encoder(f.codecId) : nullptr);
            hasEncoder = hasEncoder && enc != nullptr;
        }
        bool uniqueIds = !ids.isEmpty();
        for (int i = 0; i < ids.size(); ++i)
            for (int j = i + 1; j < ids.size(); ++j)
                uniqueIds = uniqueIds && ids[i] != ids[j];
        check("convert_formats_unique", uniqueIds);
        check("convert_formats_have_encoder", hasEncoder);
        check("convert_format_lookup", AudioConvert::formatById(QStringLiteral("flac")) != nullptr &&
                                           AudioConvert::formatById(QStringLiteral("mp3")) != nullptr &&
                                           AudioConvert::formatById(QStringLiteral("vorbis")) != nullptr &&
                                           AudioConvert::formatById(QStringLiteral("opus")) != nullptr &&
                                           AudioConvert::formatById(QStringLiteral("nope")) == nullptr);

        // —— 输出路径：换后缀、同名加序号、绝不写回源文件 ——
        check("convert_output_name", AudioConvert::outputName(QStringLiteral("/a/b/song.flac"),
                                                              QStringLiteral("m4a")) == QStringLiteral("song.m4a"));
        const QString sameExt = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("wav"));
        check("convert_output_never_overwrites",
              sameExt != srcPath && sameExt.endsWith(QStringLiteral("ramp (2).wav")));
        // 用真实临时目录，而不是 "/x/y" 这种 POSIX 字面量：Windows 会把它解析到当前盘符
        // （C:/x/y），直接比字符串就假失败了。
        const QString defaultSource = dir.path() + QStringLiteral("/song.wav");
        const QString defaultDir =
            QFileInfo(AudioConvert::uniqueOutputPath(defaultSource, QString(), QStringLiteral("flac"))).absolutePath();
        check("convert_output_dir_defaults_to_source", defaultDir == QDir(dir.path()).absolutePath());

        // —— 参数翻译：有损只带码率，无损只带压缩档 ——
        ConvertParams lossyParams;
        lossyParams.formatId = QStringLiteral("aac");
        lossyParams.bitrateKbps = 192;
        lossyParams.sampleRate = 48000;
        lossyParams.channels = 1;
        lossyParams.compressionLevel = 9;
        lossyParams.gainDb = -3.0;
        const EncodeTarget lossy = AudioConvert::targetFor(lossyParams);
        check("convert_target_lossy", lossy.codecId == AV_CODEC_ID_AAC && lossy.bitrateKbps == 192 &&
                                          lossy.sampleRate == 48000 && lossy.channels == 1 &&
                                          lossy.compressionLevel == -1 && lossy.gainDb == -3.0);
        ConvertParams flacParams;
        flacParams.formatId = QStringLiteral("flac");
        flacParams.bitrateKbps = 320;
        flacParams.compressionLevel = 8;
        const EncodeTarget flacTarget = AudioConvert::targetFor(flacParams);
        check("convert_target_lossless", flacTarget.codecId == AV_CODEC_ID_FLAC && flacTarget.bitrateKbps == 0 &&
                                             flacTarget.compressionLevel == 8 && flacTarget.sampleRate == 0 &&
                                             flacTarget.channels == 0);

        const std::atomic<bool> never{false};

        // —— 真转 FLAC（无损）：能回读、采样参数不变、时长不能短 ——
        const QString flacOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("flac"));
        const AudioEncoder::Result flacResult = AudioEncoder::convert(srcPath, flacOut, flacTarget, {}, never);
        check("convert_flac_ok", flacResult.ok && QFileInfo(flacOut).size() > 1000);
        auto flacBack = Decoder::openFile(flacOut);
        check("convert_flac_reopen", flacBack && flacBack->sampleRate() == 44100 && flacBack->channelCount() == 2);
        check("convert_flac_length", flacBack && qAbs(flacBack->totalFrames() - 88200) < 4096);

        // —— 真转 AAC（48k / 单声道 / 192k）——
        const QString aacOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("m4a"));
        const AudioEncoder::Result aacResult = AudioEncoder::convert(srcPath, aacOut, lossy, {}, never);
        check("convert_aac_ok", aacResult.ok && QFileInfo(aacOut).size() > 1000);
        auto aacBack = Decoder::openFile(aacOut);
        check("convert_aac_reopen", aacBack && aacBack->sampleRate() == 48000 && aacBack->channelCount() == 1);

        // —— 真转 ALAC（M4A 无损）——
        ConvertParams alacParams;
        alacParams.formatId = QStringLiteral("alac");
        alacParams.compressionLevel = 4;
        const QString alacOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("m4a"));
        const AudioEncoder::Result alacResult =
            AudioEncoder::convert(srcPath, alacOut, AudioConvert::targetFor(alacParams), {}, never);
        auto alacBack = Decoder::openFile(alacOut);
        check("convert_alac_ok", alacResult.ok && alacBack && alacBack->sampleRate() == 44100 &&
                                     alacBack->channelCount() == 2 && QFileInfo(alacOut).size() > 1000);

        // —— 真转 WAV（PCM 编码器 frame_size = 0，走固定 4096 分块）——
        ConvertParams wavParams;
        wavParams.formatId = QStringLiteral("wav");
        const QString wavOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("wav"));
        const AudioEncoder::Result wavResult =
            AudioEncoder::convert(srcPath, wavOut, AudioConvert::targetFor(wavParams), {}, never);
        auto wavBack = Decoder::openFile(wavOut);
        check("convert_wav_ok", wavResult.ok && wavBack && wavBack->sampleRate() == 44100 &&
                                    wavBack->channelCount() == 2 && qAbs(wavBack->totalFrames() - 88200) < 4096);

        // —— 外部编码库：MP3 / OGG Vorbis / Opus 各真转一篇并回读 ——
        // 这三项能过，说明 vendored 编码库真的链进了 libavcodec，而不只是“表里有名字”。
        ConvertParams mp3Params;
        mp3Params.formatId = QStringLiteral("mp3");
        const QString mp3Out = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("mp3"));
        const AudioEncoder::Result mp3Result =
            AudioEncoder::convert(srcPath, mp3Out, AudioConvert::targetFor(mp3Params), {}, never);
        auto mp3Back = Decoder::openFile(mp3Out);
        // MP3 有编码器延迟 + 尾部填充，帧数比源多出几个帧长是正常的。
        check("convert_mp3_ok", mp3Result.ok && mp3Back && mp3Back->sampleRate() == 44100 &&
                                    mp3Back->channelCount() == 2 && qAbs(mp3Back->totalFrames() - 88200) < 8192 &&
                                    QFileInfo(mp3Out).size() > 1000);

        ConvertParams vorbisParams;
        vorbisParams.formatId = QStringLiteral("vorbis");
        const QString vorbisOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("ogg"));
        const AudioEncoder::Result vorbisResult =
            AudioEncoder::convert(srcPath, vorbisOut, AudioConvert::targetFor(vorbisParams), {}, never);
        auto vorbisBack = Decoder::openFile(vorbisOut);
        check("convert_vorbis_ok",
              vorbisResult.ok && vorbisBack && vorbisBack->sampleRate() == 44100 && vorbisBack->channelCount() == 2 &&
                  qAbs(vorbisBack->totalFrames() - 88200) < 8192 && QFileInfo(vorbisOut).size() > 1000);

        ConvertParams opusParams;
        opusParams.formatId = QStringLiteral("opus");
        const QString opusOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("opus"));
        const AudioEncoder::Result opusResult =
            AudioEncoder::convert(srcPath, opusOut, AudioConvert::targetFor(opusParams), {}, never);
        auto opusBack = Decoder::openFile(opusOut);
        // 44.1k 源进 libopus 会被映射到 48k：这是 Opus 的格式约束（只认 8/12/16/24/48k），
        // 不是“跟源”失效；回读的采样率就是证据。时长不变，所以帧数按 48k 算（2s ≈ 96000）。
        check("convert_opus_ok", opusResult.ok && opusBack && opusBack->sampleRate() == 48000 &&
                                     opusBack->channelCount() == 2 && qAbs(opusBack->totalFrames() - 96000) < 8192 &&
                                     QFileInfo(opusOut).size() > 1000);

        // —— 增益真的落在样本上：-3 dB ≈ 0.708 倍（用无损格比对，避开有损编码误差）——
        ConvertParams gainParams = flacParams;
        gainParams.gainDb = -3.0;
        const QString gainOut = AudioConvert::uniqueOutputPath(srcPath, dir.path(), QStringLiteral("flac"));
        const AudioEncoder::Result gainResult =
            AudioEncoder::convert(srcPath, gainOut, AudioConvert::targetFor(gainParams), {}, never);
        const float srcPeak = peakAt(srcPath, 4410);
        const float outPeak = peakAt(gainOut, 4410);
        check("convert_gain_applied", gainResult.ok && srcPeak > 0.05f && qAbs(outPeak / srcPeak - 0.708f) < 0.05f);

        // —— 取消：不留半截文件 ——
        const QString cancelOut = dir.path() + "/cancelled.flac";
        std::atomic<bool> cancel{true};
        const AudioEncoder::Result cancelResult = AudioEncoder::convert(srcPath, cancelOut, flacTarget, {}, cancel);
        check("convert_cancel_cleans_output", cancelResult.cancelled && !QFileInfo::exists(cancelOut));

        // —— 坏来源：报错且不留垃圾输出 ——
        const QString junkSrc = dir.path() + "/junk.bin";
        {
            QFile file(junkSrc);
            file.open(QIODevice::WriteOnly);
            file.write("not audio");
        }
        const QString junkOut = dir.path() + "/junk.flac";
        const AudioEncoder::Result badResult = AudioEncoder::convert(junkSrc, junkOut, flacTarget, {}, never);
        check("convert_invalid_source_fails",
              !badResult.ok && !badResult.error.isEmpty() && !QFileInfo::exists(junkOut));

        // —— 真实 CUE：非零首轨、75 fps 边界、中轨与末轨；逐样本核对而非仅看容器时长 ——
        const auto cueTracks = [&](const QString &fileName, const QString &sheetName) {
            return CueSheet::toTracks(CueSheet::parse(
                QStringLiteral("FILE \"%1\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:03\n"
                               "TRACK 02 AUDIO\nTITLE \"../不安全/标题\"\nINDEX 00 00:00:25\nINDEX 01 00:00:31\n"
                               "TRACK 03 AUDIO\nINDEX 01 00:01:07\n")
                    .arg(fileName),
                QUrl::fromLocalFile(dir.path() + '/' + sheetName)));
        };
        const QList<Track> segments = cueTracks(QStringLiteral("ramp.wav"), QStringLiteral("ramp.cue"));
        const QList<Track> compressedSegments = cueTracks(QFileInfo(flacOut).fileName(), QStringLiteral("flac.cue"));
        check("convert_cue_fixture", segments.size() == 3 && compressedSegments.size() == 3);
        const auto matchesRange = [&](const QString &output, const EncodeRange &range) {
            auto back = Decoder::openFile(output);
            auto source = Decoder::openFile(srcPath);
            const int first = int(std::llround(range.start * 44100));
            const int end = range.end >= 0 ? int(std::llround(range.end * 44100)) : 88200;
            const int count = end - first;
            if (!back || !source || back->sampleRate() != 44100 || back->channelCount() != 2 || count <= 0)
                return false;
            std::vector<float> left(count + 1), right(count + 1), expectedL(count), expectedR(count);
            const int got = back->read(left.data(), right.data(), count + 1, 0);
            if (got != count || source->read(expectedL.data(), expectedR.data(), count, first) != count) return false;
            for (int i = 0; i < count; ++i)
                if (std::abs(left[i] - expectedL[i]) > 0.00004f || std::abs(right[i] - expectedR[i]) > 0.00004f)
                    return false;
            return true;
        };
        if (segments.size() == 3 && compressedSegments.size() == 3) {
            const Track &middle = segments[1];
            check("convert_cue_names_independent",
                  AudioConvert::outputName(segments[0], "wav") == "ramp - 01.wav" &&
                      AudioConvert::outputName(middle, "wav") == "ramp - 02.wav" &&
                      QFileInfo(AudioConvert::uniqueOutputPath(middle, QString(), "wav")).absolutePath() ==
                          QFileInfo(srcPath).absolutePath());
            Track archived(Archive::entryUrl(srcPath, "disc/audio.wav"));
            check("convert_cue_eligibility",
                  AudioConvert::canConvert(middle) && !AudioConvert::canConvert(archived) &&
                      !AudioConvert::canConvert(Track{}) &&
                      !AudioConvert::canConvert(Track::fromRadio(QUrl("https://example.com/live"))) &&
                      !AudioConvert::canConvert(Track(QUrl::fromLocalFile(dir.path()))));
            for (const QList<Track> &tracks : {segments, compressedSegments}) {
                for (const Track &track : tracks) {
                    for (const QString &format : {QStringLiteral("wav"), QStringLiteral("flac")}) {
                        ConvertParams params;
                        params.formatId = format;
                        const QString output = AudioConvert::uniqueOutputPath(track, dir.path(), format);
                        double previous = 0;
                        bool progressOk = true;
                        const EncodeRange range = AudioConvert::inputRange(track);
                        const auto result = AudioEncoder::convert(
                            track.url().toLocalFile(), output, AudioConvert::targetFor(params),
                            [&](double ratio) {
                                progressOk &= ratio >= previous && ratio <= 1 && ratio >= 0;
                                if (previous == 0) progressOk &= ratio < 0.3;
                                previous = ratio;
                            },
                            never, range);
                        const QString label = QStringLiteral("convert_cue_%1_%2_%3_samples")
                                                  .arg(track.url().toLocalFile().endsWith(".wav") ? "wav" : "flac")
                                                  .arg(track.cueNumber())
                                                  .arg(format);
                        check(qUtf8Printable(label), result.ok && matchesRange(output, range));
                        check(qUtf8Printable(label + "_progress"), progressOk && previous == 1);
                    }
                }
            }
            check("convert_cue_existing_output_preserved",
                  AudioConvert::uniqueOutputPath(middle, dir.path(), "wav").endsWith("ramp - 02 (3).wav"));

            const auto multiFile = CueSheet::toTracks(
                CueSheet::parse(QStringLiteral("FILE \"ramp.wav\" WAVE\nTRACK 04 AUDIO\nINDEX 01 00:01:00\n"
                                               "FILE \"%1\" WAVE\nTRACK 05 AUDIO\nINDEX 01 00:00:03\n")
                                    .arg(QFileInfo(flacOut).fileName()),
                                QUrl::fromLocalFile(dir.path() + "/multi.cue")));
            bool separateFiles = multiFile.size() == 2;
            for (const Track &track : multiFile) {
                const QString output = AudioConvert::uniqueOutputPath(track, dir.path(), "wav");
                const EncodeRange fileRange = AudioConvert::inputRange(track);
                const auto result = AudioEncoder::convert(track.url().toLocalFile(), output,
                                                          AudioConvert::targetFor(wavParams), {}, never, fileRange);
                separateFiles &= fileRange.end == -1 && result.ok && matchesRange(output, fileRange);
            }
            check("convert_cue_multiple_file_boundaries", separateFiles);

            const EncodeRange range = AudioConvert::inputRange(middle);
            ConvertParams resampled = wavParams;
            resampled.sampleRate = 48000;
            const QString resampleOut = dir.path() + "/cue-48000.wav";
            const auto resampleResult =
                AudioEncoder::convert(srcPath, resampleOut, AudioConvert::targetFor(resampled), {}, never, range);
            auto resampleBack = Decoder::openFile(resampleOut);
            check("convert_cue_resample_length", resampleResult.ok && resampleBack &&
                                                     resampleBack->sampleRate() == 48000 &&
                                                     resampleBack->countProducedFrames() == 32640);
            float l[128], r[128];
            const int got = resampleBack ? resampleBack->read(l, r, 128, 16000) : 0;
            const double expected = (range.start + 16000.0 / 48000) / 2 * 20000 / 32768;
            check("convert_cue_resample_offset", got == 128 && std::abs(l[0] - expected) < 0.001);
            const QString lossyOut = dir.path() + "/cue-aac.m4a";
            const auto lossyResult = AudioEncoder::convert(srcPath, lossyOut, lossy, {}, never, range);
            auto lossyBack = Decoder::openFile(lossyOut);
            check("convert_cue_lossy_not_whole_disc",
                  lossyResult.ok && lossyBack && qAbs(lossyBack->countProducedFrames() - 32640) < 2048);

            // 转换已读入样本后取消；重复验证末块及普通块边界均不留下半截文件。
            bool cancelledCleanly = true;
            for (int n = 0; n < 30; ++n) {
                std::atomic<bool> stop{false};
                const QString output = dir.path() + "/cue-cancel.flac";
                const auto result = AudioEncoder::convert(
                    srcPath, output, flacTarget,
                    [&](double ratio) {
                        if (ratio >= (n % 2 == 0 ? 0.1 : 1.0)) stop.store(true);
                    },
                    stop, range);
                cancelledCleanly &= result.cancelled && !result.ok && !QFileInfo::exists(output);
            }
            check("convert_cue_inflight_cancel_30", cancelledCleanly);

            // 窗口真实后台批量通路：同一镜像三条身份不能合并成一条整盘任务。
            const QString batchDir = dir.path() + "/batch";
            QDir().mkpath(batchDir);
            ConvertWindow win(segments);
            const auto combos = win.findChildren<SkinComboBox *>();
            if (!combos.isEmpty())
                for (int i = 0; i < combos.first()->count(); ++i)
                    if (combos.first()->itemData(i).toString() == "wav") combos.first()->setCurrentIndex(i);
            const auto edits = win.findChildren<SkinLineEdit *>();
            if (!edits.isEmpty()) edits.first()->setText(batchDir);
            bool finished = false;
            int done = -1, errors = -1;
            bool stopped = true;
            QStringList started;
            QObject::connect(&win, &ConvertWindow::jobStarted, &win,
                             [&](int, const QString &name) { started << name; });
            QObject::connect(&win, &ConvertWindow::batchFinished, &win, [&](int ok, int bad, bool wasCancelled) {
                done = ok;
                errors = bad;
                stopped = wasCancelled;
                finished = true;
            });
            win.start();
            QElapsedTimer timer;
            timer.start();
            while (!finished && timer.elapsed() < 20000) {
                QCoreApplication::processEvents();
                QThread::msleep(1);
            }
            bool batchSamples = finished && done == 3 && errors == 0 && !stopped;
            for (const Track &track : segments)
                batchSamples &= matchesRange(QDir(batchDir).filePath(AudioConvert::outputName(track, "wav")),
                                             AudioConvert::inputRange(track));
            check("convert_cue_window_batch_samples",
                  batchSamples && started == QStringList{"ramp - 01.wav", "ramp - 02.wav", "ramp - 03.wav"});
        }
        bool invalidRangesFail = true;
        for (const EncodeRange &range :
             {EncodeRange{-1, 1}, EncodeRange{1, 1}, EncodeRange{1, 0.5}, EncodeRange{0, 0.000001}, EncodeRange{3, -1},
              EncodeRange{1, 3}, EncodeRange{std::numeric_limits<double>::quiet_NaN(), -1},
              EncodeRange{0, std::numeric_limits<double>::infinity()}, EncodeRange{1e30, -1}}) {
            const QString output = dir.path() + "/invalid-range.wav";
            const auto result =
                AudioEncoder::convert(srcPath, output, AudioConvert::targetFor(wavParams), {}, never, range);
            invalidRangesFail &= !result.ok && !result.error.isEmpty() && !QFileInfo::exists(output);
        }
        check("convert_cue_invalid_ranges_fail", invalidRangesFail);
        QFile original(srcPath);
        check("convert_cue_source_unchanged", original.open(QIODevice::ReadOnly) && original.readAll() == wave(2));

        // —— 窗口层：能构造，且下拉项与格式表同源 ——
        {
            QDir outDir(dir.path());
            const QStringList flacBefore = outDir.entryList({QStringLiteral("*.flac")}, QDir::Files);
            ConvertWindow win({Track(QUrl::fromLocalFile(srcPath)),
                               Track(QUrl::fromLocalFile(dir.path() + QStringLiteral("/gone.flac")))});
            const QList<SkinComboBox *> combos = win.findChildren<SkinComboBox *>();
            check("convert_window_formats_listed",
                  !combos.isEmpty() && combos.first()->count() == int(AudioConvert::formats().size()));

            // 选 FLAC，然后走对话框自己的异步通路（worker 线程 + 排队信号）真转一首。
            if (!combos.isEmpty()) {
                for (int i = 0; i < combos.first()->count(); ++i)
                    if (combos.first()->itemData(i).toString() == QStringLiteral("flac"))
                        combos.first()->setCurrentIndex(i);
            }
            win.start();
            bool finished = false;
            QElapsedTimer timer;
            timer.start();
            while (timer.elapsed() < 20000) {
                QCoreApplication::processEvents();
                for (const QString &name : outDir.entryList({QStringLiteral("*.flac")}, QDir::Files)) {
                    if (flacBefore.contains(name)) continue;
                    auto probe = Decoder::openFile(outDir.filePath(name));
                    finished = probe && qAbs(probe->totalFrames() - 88200) < 4096;
                    if (finished) break;
                }
                if (finished) break;
                QThread::msleep(10);
            }
            check("convert_window_end_to_end", finished);
        }
        return failed;
    }

    int audio(const QString &suite) {
        QTemporaryDir dir;
        qputenv("TTPLAYER_QT_STATE", (dir.path() + "/state.json").toUtf8());
        const QString path = dir.path() + "/ramp.wav";
        QFile file(path);
        file.open(QIODevice::WriteOnly);
        file.write(wave(3));
        file.close();
        auto engine = AudioEngine::create();
        engine->stopPump();
        engine->m_silentOutput = false;
        if (suite == "DECODER" || suite == "FORMAT") {
            if (suite == "FORMAT") {
                const QDir formats(qEnvironmentVariable("TTPLAYER_TESTDIR", QStringLiteral("testlib")) +
                                   QStringLiteral("/formats"));
                // 注册检查不等于真实解码：没有现场编码器的档另报 fixture SKIP。
                for (const char *name : {"mp1", "mp2", "wmapro", "wmalossless", "wmavoice", "dca", "mpc7", "mpc8",
                                         "tak", "shorten", "amrnb", "amrwb"})
                    check((QByteArray("decoder_registered_") + name).constData(), avcodec_find_decoder_by_name(name));
                for (const char *name :
                     {"dts", "dtshd", "mpc", "mpc8", "tak", "shn", "amr", "ac3", "eac3", "mlp", "truehd"})
                    check((QByteArray("demuxer_registered_") + name).constData(), av_find_input_format(name));
                bool filtersAligned = true;
                for (const QString &extension :
                     {"mp1", "mp2", "wma", "dts", "dtshd", "mpc", "mpp",    "mp+", "tak", "shn",
                      "amr", "awb", "ac3", "ec3", "mlp",   "thd", "truehd", "caf", "au",  "w64"}) {
                    const bool aligned = ff::playableExtensions().contains(extension) &&
                                         Importer::fileDialogFilter().contains(QStringLiteral("*.") + extension);
                    if (!aligned) qInfo("格式白名单缺项：%s", qUtf8Printable(extension));
                    filtersAligned &= aligned;
                }
                check("format_import_filters_aligned", filtersAligned);
                check("format_profile_labels", ff::codecName(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA) == "DTS-HD MA" &&
                                                   ff::codecName(AV_CODEC_ID_WMALOSSLESS) == "WMA Lossless" &&
                                                   ff::codecName(AV_CODEC_ID_MUSEPACK8) == "Musepack SV8");
                int count = 0;
                for (const QString &name : formats.entryList(QDir::Files, QDir::Name)) {
                    auto decoder = Decoder::openFile(formats.filePath(name));
                    const QByteArray label = ("format_" + name).toUtf8();
                    check(label.constData(), bool(decoder));
                    if (!decoder) continue;
                    check("format_real_frames", decoder->countProducedFrames() > 10000);
                    check("format_real_codec", !decoder->formatName().isEmpty());
                    if (name == "surround.wav") check("source_surround_channels", decoder->channelCount() == 6);
                    if (name == "hires.wav") check("source_hires", decoder->sampleRate() == 96000);
                    ++count;
                }
                check("encoded_matrix_available", count >= 26);
                const auto imported = Importer::read({formats.path()});
                if (!imported.problems.isEmpty())
                    qInfo("格式导入拒收：%s", qUtf8Printable(imported.problems.join(QLatin1Char('\n'))));
                check("format_matrix_directory_import", imported.tracks.size() == count && imported.problems.isEmpty());
                const QString uppercase = dir.path() + QStringLiteral("/CORE.DTS");
                QFile::copy(formats.filePath(QStringLiteral("core.dts")), uppercase);
                const auto upper = Importer::read({uppercase});
                check("format_uppercase_import", upper.tracks.size() == 1 && upper.problems.isEmpty());
            }
            for (int rate : {22050, 44100, 48000, 96000}) {
                QFile input(path);
                input.open(QIODevice::WriteOnly);
                input.write(wave(1, rate));
                input.close();
                auto decoder = Decoder::openFile(path);
                check("PCM_rate", decoder && decoder->sampleRate() == rate);
                if (!decoder) continue;
                check("PCM_frame_count", decoder->countProducedFrames() == rate);
                float l[128], r[128], again[128], other[128];
                decoder->read(l, r, 128, rate / 2);
                decoder->read(again, other, 128, rate / 2);
                check("seek_exact_repeat", std::equal(l, l + 128, again));
                check("PCM_stereo", std::equal(l, l + 128, r));
            }
            if (suite == "DECODER") {
                const QDir formats(qEnvironmentVariable("TTPLAYER_TESTDIR") + QStringLiteral("/formats"));
                // 输入 PTS 不能把实交 PCM 位置推前：比较整段解码与 producer 分块的每个样本。
                for (const QString &name :
                     {QStringLiteral("mp3.mp3"), QStringLiteral("mp3-320.mp3"), QStringLiteral("s16.wav"),
                      QStringLiteral("aac.m4a"), QStringLiteral("opus.ogg"), QStringLiteral("dsd.dsf"),
                      QStringLiteral("dsd.dff")}) {
                    for (int rate : {22050, 44100, 48000, 96000}) {
                        const QString prefix = QStringLiteral("resample_%1_%2_").arg(name).arg(rate);
                        const auto verify = [&](const char *what, bool ok) {
                            check((prefix + QString::fromLatin1(what)).toUtf8().constData(), ok);
                        };
                        auto reference = Decoder::openFile(formats.filePath(name));
                        auto chunked = Decoder::openFile(formats.filePath(name));
                        const bool ready =
                            reference && chunked && reference->resampleTo(rate) && chunked->resampleTo(rate);
                        verify("available", ready);
                        if (!ready) continue;
                        if (name == QStringLiteral("mp3-320.mp3")) verify("bitrate", chunked->bitRateKbps() == 320);
                        const int capacity = rate * 14;
                        std::vector<float> left(capacity), right(capacity), expectedL(capacity), expectedR(capacity);
                        const int total = reference->read(expectedL.data(), expectedR.data(), capacity, 0);
                        bool sequential = true;
                        int pos = 0;
                        while (pos < capacity) {
                            if (pos > 0) sequential &= chunked->m_nextOutPos == pos && chunked->m_discardUntil < 0;
                            const int need = std::min(2048, capacity - pos);
                            const int got = chunked->read(left.data() + pos, right.data() + pos, need, pos);
                            pos += got;
                            sequential &= chunked->m_nextOutPos == pos;
                            if (got <= 0) break;
                        }
                        verify("sequential_position", sequential);
                        verify("continuous_PCM", total > 10000 && pos == total &&
                                                     std::equal(left.begin(), left.begin() + pos, expectedL.begin()) &&
                                                     std::equal(right.begin(), right.begin() + pos, expectedR.begin()));
                        if (name == QStringLiteral("mp3-320.mp3")) verify("twelve_seconds", total == rate * 12);
                        // 真正不连续的位置仍要 seek；重复定位和其后的短块继续读都必须稳定。
                        const int target = rate / 3;
                        float firstL[257], firstR[257], againL[257], againR[257], tailL[31], tailR[31];
                        const int first = chunked->read(firstL, firstR, 257, target);
                        const int tail = chunked->read(tailL, tailR, 31, target + first);
                        bool repeated = first == 257 && tail == 31;
                        bool identical = true;
                        for (int repeat = 0; repeat < 30; ++repeat) {
                            const int got = chunked->read(againL, againR, 257, target);
                            repeated &= got == first && chunked->m_nextOutPos == target + got;
                            identical &= got == first && std::equal(firstL, firstL + first, againL) &&
                                         std::equal(firstR, firstR + first, againR);
                        }
                        verify("seek_position_repeat_30", repeated);
                        // FFmpeg AAC 的 PNS 随机状态不由 flush 重置，重复 seek 不保证逐位相同。
                        // 上面的顺序解码仍逐样本比较；其它这些编码另核对重复 seek 的 PCM。
                        if (name != QStringLiteral("aac.m4a")) verify("seek_PCM_repeat_30", repeated && identical);
                        // EOF 附近的短读和尾部冲刷，也不能把后续顺序请求当成重新定位。
                        chunked->seek(total + rate);
                        const int beyond = chunked->read(firstL, firstR, 257, total + rate);
                        const int eofAgain = chunked->read(firstL, firstR, 257, total + rate);
                        verify("EOF_stable", beyond == 0 && eofAgain == 0 && chunked->m_nextOutPos == total + rate);
                    }
                }
                // 用可计算的斜坡核对重采样后的真实定位，不能只比较两次同样错位的 seek。
                const QString rampPath = dir.path() + QStringLiteral("/seek-ramp.wav");
                QFile ramp(rampPath);
                ramp.open(QIODevice::WriteOnly);
                ramp.write(wave(3, 44100));
                ramp.close();
                for (int rate : {22050, 48000, 96000}) {
                    auto decoder = Decoder::openFile(rampPath);
                    const bool ready = decoder && decoder->resampleTo(rate);
                    bool accurate = ready;
                    if (ready) {
                        float left[257], right[257];
                        for (int target : {rate / 3, rate + 37, rate * 2 + 113}) {
                            const int got = decoder->read(left, right, 257, target);
                            accurate &= got == 257 && decoder->m_nextOutPos == target + got;
                            for (int i = 0; i < got; ++i) {
                                const double expected = double(target + i) / (rate * 3) * 20000 / 32768;
                                accurate &= std::abs(left[i] - expected) < 0.0001 && left[i] == right[i];
                            }
                        }
                    }
                    check(QStringLiteral("resample_ramp_%1_seek_accuracy").arg(rate).toUtf8().constData(), accurate);
                }
                auto live = std::make_shared<GateSource>();
                live->allowSeek = false;
                live->data = wave(3, 44100);
                auto decoder = Decoder::openStream(live, "live PCM");
                check("live_44100_to_48000_preserves_three_seconds",
                      decoder && decoder->resampleTo(48000) && decoder->countProducedFrames() == 144000);
            }
            check("missing_rejected", !Decoder::openFile(dir.path() + "/missing.wav"));
            return failed;
        }
        if (suite == "GAPLESS") {
            for (int n = 0; n < 30; ++n) {
                auto current = Decoder::openFile(path);
                engine->m_decoder = std::shared_ptr<Decoder>(std::move(current));
                engine->m_sampleRate = 44100;
                engine->m_playing = true;
                engine->m_eos = true;
                engine->m_delivered = 0;
                engine->ringClear();
                float l[128], r[128];
                std::fill_n(l, 128, 0.25f);
                std::fill_n(r, 128, 0.25f);
                engine->ringPush(l, r, 128);
                engine->prepareNext(Decoder::openFile(path), 1, 2, 0.5f, "next");
                // Prepare the real decoder's first samples on the producer thread, then freeze it.
                engine->startPump();
                for (int k = 0; k < 200; ++k) {
                    QThread::msleep(1);
                    std::lock_guard<std::mutex> lk(engine->m_mutex);
                    if (engine->m_next && engine->m_next->ready) break;
                }
                engine->stopPump();
                engine->m_volume = 1;
                engine->m_eq.setEnabled(false);
                std::vector<float> output(512);
                engine->callback(output.data(), 256);
                check("gapless_boundary_no_silence",
                      std::all_of(output.begin(), output.end(), [](float v) { return v > 0.05f; }));
                check("gapless_next_gain", output[256] > 0.09f && output[256] < 0.12f);
                check("gapless_position", std::abs(engine->positionSeconds() - 128.0 / 44100) < 0.00001);
                engine->stop();
                QCoreApplication::processEvents();
            }
            engine->m_silentOutput = true;
            engine->startPump();
            {
                PlayerController ctl(engine);
                engine->setVolume(1);
                engine->setEQEnabled(false);
                const QUrl sheet = QUrl::fromLocalFile(dir.path() + "/disc.cue");
                Track first = Track::fromCueSegment(QUrl::fromLocalFile(path), 1, sheet, 1, 1.35);
                Track second = Track::fromCueSegment(QUrl::fromLocalFile(path), 2, sheet, 2, 2.35);
                engine->m_testCapture.resize(std::size_t{44100} * 2);
                engine->m_testCaptured = 0;
                ctl.setTracks({first, second});
                ctl.playRowAt(0);
                check("gapless_public_start", waitFor([&] { return ctl.isPlaying(); }));
                check("gapless_public_transition",
                      waitFor([&] { return ctl.currentTrack().identityKey() == second.identityKey(); }));
                ctl.stop();
                std::lock_guard<std::mutex> lock(engine->m_mutex);
                bool begun = false, ended = false;
                int interiorSilence = 0;
                float peak = 0;
                for (size_t i = 0; i < engine->m_testCaptured; i += 2) {
                    const float value = engine->m_testCapture[i];
                    peak = std::max(peak, value);
                    if (value > 0.05f) {
                        if (ended) ++interiorSilence;
                        begun = true;
                    } else if (begun)
                        ended = true;
                }
                check("gapless_real_callback_continuity", begun && interiorSilence == 0 && peak > 0.39f);
                engine->m_testCapture.clear();
                engine->m_testCaptured = 0;
            }
            const QDir formats(qEnvironmentVariable("TTPLAYER_TESTDIR") + "/formats");
            const QStringList encoded{"mp3.mp3", "aac.m4a", "alac.m4a", "flac.flac", "vorbis.ogg", "opus.ogg"};
            engine->stopPump();
            engine->closeDevice();
            for (int codec = 0; codec < encoded.size(); ++codec) {
                const QString from = formats.filePath(encoded[codec]),
                              to = formats.filePath(encoded[(codec + 1) % encoded.size()]);
                auto first = Decoder::openFile(from), second = Decoder::openFile(to), reference = Decoder::openFile(to);
                check("gapless_encoded_decoders", first && second && reference);
                if (!first || !second || !reference) continue;
                first->resampleTo(44100);
                second->resampleTo(44100);
                reference->resampleTo(44100);
                const int64_t total = first->countProducedFrames();
                float l[256], r[256], expectedL[256], expectedR[256];
                const int tail = first->read(l, r, 256, total - 256),
                          head = reference->read(expectedL, expectedR, 256, 0);
                check("gapless_encoded_tail_head_available", tail == 256 && head == 256);
                engine->m_decoder = std::shared_ptr<Decoder>(std::move(first));
                engine->m_sampleRate = 44100;
                engine->m_eos = true;
                engine->m_playing = true;
                engine->m_finishPending = false;
                engine->ringClear();
                engine->ringPush(l, r, 256);
                engine->m_replayGainLinear = 0.7f;
                engine->m_silentOutput = false;
                engine->prepareNext(std::move(second), 0, -1, 0.3f, "encoded");
                engine->startPump();
                for (int k = 0; k < 1000; ++k) {
                    QThread::msleep(1);
                    std::lock_guard<std::mutex> lock(engine->m_mutex);
                    if (engine->m_next && engine->m_next->ready) break;
                }
                engine->stopPump();
                float output[1024];
                engine->callback(output, 512);
                bool identical = true;
                float error = 0;
                for (int i = 0; i < 256; ++i) {
                    error = std::max(error, std::max(std::abs(output[std::size_t(i) * 2] - l[i] * 0.7f),
                                                     std::abs(output[std::size_t(i + 256) * 2] - expectedL[i] * 0.3f)));
                }
                identical = error < 0.00001f;
                if (!identical)
                    out << "GAPLESS detail " << encoded[codec] << " -> " << encoded[(codec + 1) % encoded.size()]
                        << " max_error=" << error << " ring=" << engine->m_ringCount << " rate=" << engine->m_sampleRate
                        << " playing=" << engine->m_playing << " volume=" << engine->m_volume
                        << " fade=" << engine->m_fadeCur << '\n';
                check("gapless_encoded_no_inserted_or_skipped_frames", identical);
                engine->stop();
                QCoreApplication::processEvents();
            }
            return failed;
        }
        if (suite == "GAIN") {
            for (const QString &bad : QStringList{"", "nan", "inf", "31 dB", "junk"})
                check("gain_invalid_db", !ReplayGainTags::decibel(bad));
            for (const QString &bad : QStringList{"0", "-1", "nan", "11"})
                check("gain_invalid_peak", !ReplayGainTags::peak(bad));
            check("gain_decimal_comma", ReplayGainTags::decibel("-0,5 dB") == -0.5);
            for (auto mode : {ReplayGainMode::Off, ReplayGainMode::Track, ReplayGainMode::Album}) {
                ReplayGainTags tags;
                tags.trackGain = -6;
                tags.albumGain = -12;
                tags.trackPeak = 0.8;
                tags.albumPeak = 0.6;
                for (double preamp : {-12.0, 0.0, 12.0})
                    for (bool limited : {false, true}) {
                        const auto decision = ReplayGainDecision::decide(tags, mode, preamp, limited, false);
                        const double db =
                            mode == ReplayGainMode::Off ? 0 : (mode == ReplayGainMode::Track ? -6 : -12) + preamp;
                        const double expected = std::pow(10.0, db / 20.0);
                        check("gain_mode_preamp_math",
                              std::abs(decision.linear -
                                       (limited && mode != ReplayGainMode::Off
                                            ? std::min(expected, 1.0 / (mode == ReplayGainMode::Track ? 0.8 : 0.6))
                                            : expected)) < 0.00001);
                    }
            }
            for (float gain : {0.25f, 0.5f, 1.0f, 2.0f}) {
                engine->m_playing = true;
                engine->m_volume = 0.8;
                engine->m_replayGainLinear = gain;
                engine->m_eq.setEnabled(false);
                engine->ringClear();
                float l[128], r[128];
                std::fill_n(l, 128, 0.1f);
                std::fill_n(r, 128, -0.1f);
                engine->ringPush(l, r, 128);
                float samples[256];
                engine->callback(samples, 128);
                check("gain_real_output", std::all_of(samples, samples + 256, [gain](float v) {
                          return std::abs(std::abs(v) - 0.08f * gain) < 0.00001;
                      }));
            }
            const auto tags =
                ReplayGainTags::fromTags({{"replaygain_track_gain", "-6 dB"}, {"replaygain_track_peak", "0.95"}});
            const auto limited = ReplayGainDecision::decide(tags, ReplayGainMode::Track, 12, true, false);
            check("gain_peak_limit", limited.linear <= 1.0 / 0.95 + 0.0001);
            check("gain_radio_unity",
                  ReplayGainDecision::decide(tags, ReplayGainMode::Track, 12, true, true).linear == 1);
            engine->m_silentOutput = true;
            engine->startPump();
            PlayerController ctl(engine);
            ctl.setGaplessEnabled(false);
            engine->setEQEnabled(false);
            engine->setVolume(1);
            Track track(QUrl::fromLocalFile(qEnvironmentVariable("TTPLAYER_TESTDIR") + QStringLiteral("/cover.flac")));
            Importer::probe(track);
            ctl.setTracks({track});
            auto rms = [&](ReplayGainMode mode, double preamp, bool peak) {
                ctl.stop();
                ctl.setReplayGainMode(mode);
                ctl.setReplayGainPreamp(preamp);
                ctl.setReplayGainPeakLimit(peak);
                {
                    std::lock_guard<std::mutex> lock(engine->m_mutex);
                    engine->m_testCapture.assign(16384, 0);
                    engine->m_testCaptured = 0;
                }
                ctl.playRowAt(0);
                const bool ready = waitFor([&] {
                    std::lock_guard<std::mutex> lock(engine->m_mutex);
                    return engine->m_testCaptured == engine->m_testCapture.size();
                });
                ctl.stop();
                double sum = 0;
                int count = 0;
                {
                    std::lock_guard<std::mutex> lock(engine->m_mutex);
                    for (size_t i = 0; i < engine->m_testCaptured; i += 2) {
                        const double value = engine->m_testCapture[i];
                        if (std::abs(value) > 0.0001) {
                            sum += value * value;
                            ++count;
                        }
                    }
                    engine->m_testCapture.clear();
                    engine->m_testCaptured = 0;
                }
                check("gain_public_PCM_available", ready && count > 1000);
                return count ? std::sqrt(sum / count) : 0.0;
            };
            const double reference = rms(ReplayGainMode::Off, 0, true);
            const double repeat = rms(ReplayGainMode::Off, 0, true);
            check("gain_same_condition_repeat", reference > 0 && std::abs(repeat / reference - 1) < 0.03);
            const double reduced = rms(ReplayGainMode::Track, 0, true);
            check("gain_real_RMS_track",
                  reference > 0 && std::abs(reduced / reference - std::pow(10.0, -6.0 / 20)) < 0.03);
            const double limitedRMS = rms(ReplayGainMode::Track, 12, true);
            check("gain_real_RMS_peak_limit", reference > 0 && std::abs(limitedRMS / reference - 1.25) < 0.04);
            return failed;
        }
        if (suite == "SPECTRUM") {
            SpectrumAnalyzer analyzer;
            analyzer.setSampleRate(44100);
            float l[4096], r[4096], bands[64];
            for (int i = 0; i < 4096; ++i)
                l[i] = r[i] = float(std::sin(i * 2 * 3.141592653589793 * 880 / 44100));
            analyzer.feed(l, r, 4096);
            check("FFT_energy", analyzer.bands(bands) && *std::max_element(bands, bands + 64) > 0.1f);
            analyzer.setEnabled(false);
            check("FFT_disabled", !analyzer.bands(bands));
            return failed;
        }
        engine->m_silentOutput = true;
        engine->startPump();
        PlayerController controller(engine);
        Track track(QUrl::fromLocalFile(path));
        Importer::probe(track);
        controller.setGaplessEnabled(false);
        controller.setTracks({track});
        if (suite == "PLAYBACK") {
            bool natural = true, preview = true, manual = true;
            int cases = 0;
            for (int size = 1; size <= 5; ++size) {
                QList<Track> base;
                for (int i = 0; i < size; ++i)
                    base.append(Track(QUrl::fromLocalFile(QStringLiteral("/base%1.flac").arg(i))));
                for (int cursor = 0; cursor < size; ++cursor)
                    for (PlayMode mode :
                         {PlayMode::Order, PlayMode::ListLoop, PlayMode::SingleLoop, PlayMode::Random}) {
                        PlayQueue queue;
                        queue.begin(base, cursor);
                        queue.randomIndex = [](int, int) { return 0; };
                        const QString expected = mode == PlayMode::SingleLoop ? base[cursor].identityKey()
                                                 : mode == PlayMode::Random   ? base.first().identityKey()
                                                 : cursor + 1 < size          ? base[cursor + 1].identityKey()
                                                 : mode == PlayMode::ListLoop ? base.first().identityKey()
                                                                              : QString();
                        const auto *peek = queue.peekOnFinish(mode);
                        const QUuid id = peek ? peek->id : QUuid();
                        const auto *again = queue.peekOnFinish(mode);
                        preview &= queue.cursor() == cursor && (again ? again->id : QUuid()) == id;
                        const auto *actual = queue.advanceOnFinish(mode);
                        natural &= (actual ? actual->track.identityKey() : QString()) == expected &&
                                   (actual ? actual->id : QUuid()) == id;
                        queue.begin(base, cursor);
                        const auto *selected = queue.advanceByUser(mode);
                        const QString wanted = mode == PlayMode::Random  ? base.first().identityKey()
                                               : cursor + 1 < size       ? base[cursor + 1].identityKey()
                                               : mode == PlayMode::Order ? QString()
                                                                         : base.first().identityKey();
                        manual &= (selected ? selected->track.identityKey() : QString()) == wanted;
                        ++cases;
                    }
            }
            check("base_modes_natural_matrix", natural);
            check("base_peek_and_advance_same_UUID", preview);
            check("base_manual_next_matrix", manual);
            out << "PLAYBACK matrix_cases=" << cases << '\n';
            PlayQueue history;
            const Track other(QUrl::fromLocalFile("/other.wav"));
            history.begin({track, other, track}, 0);
            const QUuid current = history.current()->id;
            history.dropTracks({track.identityKey()});
            check("base_drop_duplicate_preserves_current", history.count() == 2 && history.current()->id == current);
            const auto *next = history.advanceByUser(PlayMode::Order);
            history.markPlayed(next->id);
            const auto *previous = history.retreat(PlayMode::Random);
            check("base_random_actual_history", previous && previous->id == current);
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            check("play_without_context", controller.isPlaying());
            controller.togglePlay();
            check("pause", !controller.isPlaying());
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            check("resume", controller.isPlaying());
            controller.stop();
            controller.queue().reset();
            controller.queue().begin({track}, 0);
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            check("play_base_context",
                  controller.isPlaying() && controller.currentTrack().identityKey() == track.identityKey());
            controller.stop();
            check("stop_position", controller.position() == 0);
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            check("restart", controller.isPlaying());
        } else if (suite == "SLEEP") {
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            controller.setSleepAfterCurrentTrack();
            check("sleep_armed", controller.sleepArmed());
            controller.stop();
            check("stop_cancels_aftertrack", !controller.sleepArmed());
            controller.togglePlay();
            controller.setSleepAfterCurrentTrack();
            controller.m_positionCache = 2.5;
            controller.sleepTick();
            check("aftertrack_fading", controller.m_sleepFading);
            controller.cancelSleepTimer();
            check("cancel_restores_fade", !controller.m_sleepFading && engine->m_fadeTarget == 1);
            controller.setSleepMinutes(1);
            controller.m_sleepDeadlineMs = 0;
            controller.sleepTick();
            check("countdown_stops", !controller.isPlaying() && !controller.sleepArmed());
        } else if (suite == "SCENE") {
            MainWindow window(&controller, engine);
            window.collections().registerTracks({track});
            controller.restoreResume({QueueItem{.track = track}}, 0, {}, 1, false);
            waitFor([&] { return engine->durationSeconds() > 0; });
            check("restore_paused", !controller.isPlaying());
            check("restore_target_position", std::abs(engine->positionSeconds() - 1) < 0.00001);
            window.requestSave();
            controller.stop();
            controller.queue().reset();
            window.restoreLibrary();
            check("restore_yields_to_event_loop", window.isRestoringLibrary());
            window.requestSave();
            check("restore_does_not_save_partial_library", LibraryStore::load().trackPaths.size() == 1);
            window.restoreLibrary(); // Supersede an in-flight restore; only the latest may commit.
            check("restore_latest_generation_completes", waitFor([&] { return !window.isRestoringLibrary(); }));
            check("resume_metadata_shared", controller.currentTrack().replayGainTags().has_value());
            check("resume_identity", controller.currentTrack().identityKey() == track.identityKey());
            waitFor([&] { return engine->durationSeconds() > 0; });
            {
                std::lock_guard<std::mutex> lock(engine->m_mutex);
                engine->m_testCapture.resize(8192);
                engine->m_testCaptured = 0;
            }
            engine->setVolume(1);
            engine->setEQEnabled(false);
            controller.togglePlay();
            check("resume_real_pcm_available", waitFor([&] {
                      std::lock_guard<std::mutex> lock(engine->m_mutex);
                      return engine->m_testCaptured >= 4096;
                  }));
            controller.togglePlay();
            {
                std::lock_guard<std::mutex> lock(engine->m_mutex);
                const auto end = engine->m_testCapture.begin() + engine->m_testCaptured;
                const auto first =
                    std::find_if(engine->m_testCapture.begin(), end, [](float value) { return value > 0.01f; });
                check("resume_real_pcm_at_saved_segment", first != end && *first > 0.20f && *first < 0.23f);
                engine->m_testCapture.clear();
                engine->m_testCaptured = 0;
            }
            controller.stop();
            controller.queue().reset();
            window.requestSave();
            check("unestablished_scene_not_saved", !LibraryStore::load().resumeValid);
            Track missing(QUrl::fromLocalFile(dir.path() + "/missing.wav"));
            controller.setMode(PlayMode::Order);
            controller.restoreResume({QueueItem{.track = missing}, QueueItem{.track = track}}, 0, {}, 0, false);
            waitFor([&] { return !controller.m_openJob; });
            check("failed_paused_restore_does_not_advance_or_play",
                  controller.currentTrack().identityKey() == missing.identityKey() && !controller.isPlaying());
        } else if (suite == "DEVICE") {
            engine->setOutputDevice("missing-review-device");
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            check("device_fallback_plays", controller.isPlaying());
            engine->setOutputDevice({});
            check("device_follow_default", engine->outputDevice().isEmpty());
            controller.togglePlay();
            engine->setOutputDevice("missing-review-device");
            check("device_preserves_pause", !controller.isPlaying());
#ifdef __APPLE__
            if (QString::fromUtf8(SDL_GetCurrentAudioDriver()) == "coreaudio") {
                struct Devices {
                    AudioDeviceID first = 0, second = 0;
                    ~Devices() {
                        if (first) AudioHardwareDestroyAggregateDevice(first);
                        if (second) AudioHardwareDestroyAggregateDevice(second);
                    }
                } devices;
                AudioDeviceID base = 0;
                UInt32 size = sizeof(base);
                AudioObjectPropertyAddress property{kAudioHardwarePropertyDefaultOutputDevice,
                                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, nullptr, &size, &base);
                CFStringRef baseUID = nullptr;
                size = kCfStringRefSize;
                property.mSelector = kAudioDevicePropertyDeviceUID;
                AudioObjectGetPropertyData(base, &property, 0, nullptr, &size, reinterpret_cast<void *>(&baseUID));
                const QString uidA = "org.ttplayer.selftest.a." + QUuid::createUuid().toString(QUuid::Id128),
                              uidB = "org.ttplayer.selftest.b." + QUuid::createUuid().toString(QUuid::Id128);
                auto create = [&](const QString &uid, AudioDeviceID &id) {
                    if (!baseUID) return OSStatus(-1);
                    const void *subKeys[] = {CFSTR(kAudioSubDeviceUIDKey)}, *subValues[] = {baseUID};
                    CFDictionaryRef sub =
                        CFDictionaryCreate(nullptr, subKeys, subValues, 1, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
                    const void *subItems[] = {sub};
                    CFArrayRef subs = CFArrayCreate(nullptr, subItems, 1, &kCFTypeArrayCallBacks);
                    CFStringRef identity = uid.toCFString();
                    const void *keys[] = {CFSTR(kAudioAggregateDeviceUIDKey), CFSTR(kAudioAggregateDeviceNameKey),
                                          CFSTR(kAudioAggregateDeviceSubDeviceListKey),
                                          CFSTR(kAudioAggregateDeviceMainSubDeviceKey),
                                          CFSTR(kAudioAggregateDeviceIsPrivateKey)};
                    const void *values[] = {identity, CFSTR("TTPlayer selftest same name"), subs, baseUID,
                                            kCFBooleanFalse};
                    CFDictionaryRef options = CFDictionaryCreate(
                        nullptr, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                    const OSStatus result = AudioHardwareCreateAggregateDevice(options, &id);
                    CFRelease(options);
                    CFRelease(identity);
                    CFRelease(subs);
                    CFRelease(sub);
                    return result;
                };
                if (create(uidA, devices.first) == noErr && create(uidB, devices.second) == noErr) {
                    waitFor([&] { return AudioEngine::outputDeviceDescriptors().size() >= 2; });
                    controller.setOutputDevice(uidA);
                    check("duplicate_name_UID_first", engine->m_boundDevice == devices.first);
                    controller.setOutputDevice(uidB);
                    check("duplicate_name_UID_second", engine->m_boundDevice == devices.second);
                    AudioHardwareDestroyAggregateDevice(devices.second);
                    devices.second = 0;
                    check("device_removed_falls_back", waitFor([&] {
                              engine->pollDevices();
                              return engine->m_boundDevice == base && !engine->outputProblem().isEmpty();
                          }));
                    check("device_return_fixture", create(uidB, devices.second) == noErr);
                    check("device_return_restores_UID", waitFor([&] {
                              engine->pollDevices();
                              return engine->m_boundDevice == devices.second && engine->outputProblem().isEmpty();
                          }));
                    controller.setOutputDevice({});
                    check("device_default_recovered",
                          engine->m_boundDevice == base && engine->outputDevice().isEmpty());
                } else
                    out << "DEVICE_PROBE duplicate_device_fixture SKIP aggregate creation unavailable\n";
                if (baseUID) CFRelease(baseUID);
            }
#endif
        }
        controller.stop();
        return failed;
    }

    int models(const QString &suite) {
        QTemporaryDir dir;
        qputenv("TTPLAYER_QT_STATE", (dir.path() + "/state.json").toUtf8());
        const QString path = dir.path() + "/a.wav";
        QFile file(path);
        file.open(QIODevice::WriteOnly);
        file.write(wave(1));
        file.close();
        Track a(QUrl::fromLocalFile(path));
        a.setTitle("Alpha");
        Track b(QUrl::fromLocalFile(dir.path() + "/b.flac"));
        b.setTitle("Beta");
        if (suite == "CUE") {
            const QUrl sheet = QUrl::fromLocalFile(dir.path() + "/disc.cue");
            const auto infos = CueSheet::parse(
                "PERFORMER \"Album Artist\"\nTITLE \"Album\"\nFILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nTITLE \"One\"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"Two\"\nINDEX 00 00:00:20\nINDEX 01 00:00:30\n",
                sheet);
            const auto tracks = CueSheet::toTracks(infos);
            check("cue_two_segments", tracks.size() == 2);
            if (tracks.size() == 2) {
                check("cue_precise_75fps", std::abs(tracks[0].playEnd() - 0.4) < 1e-9 && tracks[1].playStart() == 0.4);
                check("cue_distinct_identity", tracks[0].identityKey() != tracks[1].identityKey());
                check("cue_sheet_identity", tracks[1].identityKey().endsWith("#track=2"));
                check("cue_metadata", tracks[1].title().contains("Two") && tracks[1].artist() == "Album Artist" &&
                                          tracks[1].album() == "Album");
            }
            for (const QString &bad : QStringList{"", "a:b:c", "1:90:00", "00:00:75", "-1:00:00"})
                check("cue_invalid_time", CueSheet::parseCueTime(bad) < 0);
            check("cue_frame_time", std::abs(CueSheet::parseCueTime("02:03:37") - (123 + 37.0 / 75)) < 1e-9);
            check("missing_cue_keeps_identity",
                  Collections::resolveToken(dir.path() + "/missing.cue#track=2").identityKey() ==
                      dir.path() + "/missing.cue#track=2");
        } else if (suite == "LISTS" || suite == "PLAYLIST") {
            UserPlaylists lists;
            QString one, two, note;
            check("list_empty_name_rejected", !lists.create("  ", &one));
            check("list_create", lists.create("Road", &one));
            check("list_duplicate_name_distinguished",
                  lists.create("Road", &two, &note) && one != two && lists.nameOf(one) != lists.nameOf(two) &&
                      note == QStringLiteral("已经有叫「Road」的列表，新列表命名为「%1」").arg(lists.nameOf(two)));
            check("list_rename_errors_use_list_name",
                  lists.rename("missing", "Name") == QStringLiteral("这个列表已经不在了") &&
                      lists.rename(one, "  ") == QStringLiteral("列表名不能是空的") && lists.nameOf(one) == "Road");
            UserPlaylists restoredNames;
            restoredNames.restore({UserPlaylist("saved", QStringLiteral("我的歌单"), {a.identityKey()})});
            check("list_user_name_and_identity_preserved",
                  restoredNames.nameOf("saved") == QStringLiteral("我的歌单") &&
                      restoredNames.snapshot().first().id == "saved" &&
                      restoredNames.keysOf("saved") == QStringList{a.identityKey()});
            check("list_dedup", lists.addKeys({a.identityKey(), b.identityKey(), a.identityKey()}, one) == 2);
            check("list_invalid_reorder_atomic",
                  !lists.reorder(one, {a.identityKey()}) && lists.keysOf(one).size() == 2);
            check("list_reorder", lists.reorder(one, {b.identityKey(), a.identityKey()}));
            check("list_rename_stable_id", lists.rename(one, "New").isEmpty() && lists.contains(one));
            const auto before = lists.keysOf(one);
            lists.addKeys(before, two);
            lists.removeKeys({a.identityKey()}, one);
            check("list_membership_independent", lists.keysOf(one).size() == 1 && lists.keysOf(two).size() == 2);
            lists.replaceKeys({{b.identityKey(), a.identityKey()}});
            check("list_replace_collision_dedup", lists.keysOf(two).size() == 1);
            const QString url = Archive::entryUrl(dir.path() + "/专辑 #%.zip", "disc #/曲%.flac").toString();
            const QList<Track> source{a, Track(QUrl(url)), Track::fromRadio(QUrl("http://example.com/live?q=1"))};
            for (const QString &ext : QStringList{"m3u", "m3u8"}) {
                const QString playlistPath = dir.path() + "/list." + ext;
                check("list_export", PlaylistM3U::exportTracks(source, playlistPath));
                PlaylistM3U::Imported imported;
                check("list_import", PlaylistM3U::importFile(playlistPath, imported));
                check("list_roundtrip_identity",
                      imported.keys == QStringList{a.identityKey(), url, source.last().identityKey()});
            }
            check("list_delete", lists.remove(one) && !lists.contains(one) && lists.contains(two));
        } else if (suite == "SHIFT") {
            QFile lrc(dir.path() + "/a.lrc");
            lrc.open(QIODevice::WriteOnly);
            lrc.write("[offset:100]\n[00:00.50]Hello\n[00:01.00]World\n");
            lrc.close();
            auto engine = AudioEngine::create();
            PlayerController ctl(engine);
            ctl.setGaplessEnabled(false);
            ctl.setTracks({a});
            ctl.playRowAt(0);
            check("shift_real_load", waitFor([&] { return ctl.isPlaying(); }));
            check("shift_default", ctl.lyricShift() == 0 && ctl.lyricShiftApplies());
            ctl.nudgeLyricShift(0.5);
            check("shift_step", ctl.lyricShift() == 0.5);
            check("shift_aligned_time", std::abs(ctl.alignedLyricTime(1) - 0.5) < 1e-9);
            ctl.setLyricShift(100);
            check("shift_upper_limit", ctl.lyricShift() == 30);
            ctl.setLyricShift(-100);
            check("shift_lower_limit", ctl.lyricShift() == -30);
            ctl.resetLyricShift();
            check("shift_reset", ctl.lyricShift() == 0 && ctl.lyricShiftTable().isEmpty());
            QFile bytes(lrc.fileName());
            bytes.open(QIODevice::ReadOnly);
            check("shift_does_not_rewrite_lyric", bytes.readAll().contains("[offset:100]"));
            ctl.stop();
            embeddedLyrics();
        } else if (suite == "LIBRARY") {
            Collections col;
            col.registerTracks({a});
            col.replaceLibrary({a, b});
            check("library_not_default",
                  col.currentTracks().size() == 1 && col.tracksOf(Collections::kLibraryViewId).size() == 2);
            col.replaceLibrary({b});
            check("scan_keeps_manual", col.currentTracks().size() == 1);
            col.replaceLibrary({a, b});
            col.removeTrackFromView(Collections::kAllViewId, a.identityKey());
            check("default_delete_keeps_library",
                  col.currentTracks().isEmpty() && col.tracksOf(Collections::kLibraryViewId).size() == 2);
            LibraryStore::Loaded snapshot;
            col.saveTo(snapshot);
            snapshot.trackPaths = {a.url().toString(), b.url().toString()};
            LibraryStore::save(snapshot);
            Collections restored;
            restored.loadFrom(LibraryStore::load());
            restored.setAllTracks({a, b});
            check("library_membership_persisted",
                  restored.currentTracks().isEmpty() && restored.tracksOf(Collections::kLibraryViewId).size() == 2);
            auto engine = AudioEngine::create();
            PlayerController ctl(engine);
            MainWindow window(&ctl, engine);
            QDir().mkpath(dir.path() + "/new");
            QFile::copy(path, dir.path() + "/new/a.wav");
            window.m_libraryFolders = {dir.path()};
            window.collections().setAllTracks({a});
            window.collections().toggleFavorite(a.identityKey());
            QString id;
            window.collections().playlists().create("Saved", &id);
            window.collections().playlists().addKeys({a.identityKey()}, id);
            ctl.queue().begin({a}, 0);
            const auto entry = ctl.queue().items().value(0).id;
            const QString old = a.identityKey();
            ctl.setLyricShiftTable({{old, 1.5}});
            check("root_relocation", window.relocateLibraryRoot(dir.path(), dir.path() + "/new").isEmpty());
            const QString moved = QUrl::fromLocalFile(dir.path() + "/new/a.wav").toLocalFile();
            check("root_favorite_migrated", window.collections().favorites() == QStringList{moved});
            check("root_list_migrated", window.collections().playlists().keysOf(id) == QStringList{moved});
            check("root_context_identity", !ctl.queue().items().isEmpty() && ctl.queue().items().first().id == entry &&
                                               ctl.queue().items().first().track.identityKey() == moved);
            check("root_old_reference_gone", !window.collections().allTracks().isEmpty() &&
                                                 window.collections().allTracks().first().identityKey() != old);
            check("root_lyric_calibration_migrated",
                  ctl.lyricShiftTable().value(moved) == 1.5 && !ctl.lyricShiftTable().contains(old));
        } else if (suite == "IMPORT") {
            QDir().mkpath(dir.path() + "/nested/deep");
            QFile::copy(path, dir.path() + "/nested/deep/deep.wav");
            const auto result = Importer::read({dir.path()});
            check("recursive_import", result.tracks.size() == 2);
            const auto duplicate = Importer::read({path, path});
            check("import_dedup", duplicate.tracks.size() == 1);
            const auto bad = Importer::read({dir.path() + "/notes.txt"});
            check("import_reason", !bad.problems.isEmpty());
            QFile cue(dir.path() + "/disc.cue");
            cue.open(QIODevice::WriteOnly);
            cue.write("FILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:00:30\n");
            cue.close();
            const auto cues = Importer::read({dir.path() + "/disc.cue", path});
            check("CUE_suppresses_mirror", cues.tracks.size() == 2 && cues.tracks[1].isCueSegment());
            QFile list(dir.path() + "/radio.m3u");
            list.open(QIODevice::WriteOnly);
            list.write("#EXTM3U\n#EXTINF:-1,Named radio\nhttp://example.com/live\n");
            list.close();
            const auto radio = Importer::read({list.fileName()});
            check("EXTINF_name", radio.tracks.size() == 1 && radio.tracks.first().title() == "Named radio");
            auto engine = AudioEngine::create();
            PlayerController ctl(engine);
            MainWindow window(&ctl, engine);
            bool cancelledInfoAbsent = true;
            for (int i = 0; i < 30; ++i) {
                const QString oldKey = QStringLiteral("http://127.0.0.1:1/old-%1").arg(i);
                const QString newKey = QStringLiteral("http://127.0.0.1:1/new-%1").arg(i);
                window.loadDirOrFiles(
                    {oldKey},
                    {{oldKey, QJsonObject{{"title", "Cancelled"}, {"artist", "Old artist"}, {"album", "Old album"}}}});
                window.loadPaths({newKey});
                const bool committed = waitFor([&] {
                    const auto tracks = window.collections().allTracks();
                    return std::any_of(tracks.cbegin(), tracks.cend(),
                                       [&](const Track &track) { return track.identityKey() == newKey; });
                });
                ctl.stop();
                LibraryStore::Loaded snapshot;
                window.collections().saveTo(snapshot);
                cancelledInfoAbsent &= committed && !snapshot.radioAliases.contains(oldKey) &&
                                       !snapshot.trackEdits.contains(oldKey) && !snapshot.defaultKeys.contains(oldKey);
            }
            check("import_cancelled_radio_info_30", cancelledInfoAbsent);
            {
                QTemporaryDir scanRoot;
                const QString good = scanRoot.path() + "/good.wav";
                const QString broken = scanRoot.path() + "/损坏.wav";
                const QString notes = scanRoot.path() + "/说明.txt";
                QFile::copy(path, good);
                QFile corrupt(broken);
                corrupt.open(QIODevice::WriteOnly);
                corrupt.write("not audio");
                corrupt.close();
                for (int i = 0; i < 50; ++i) {
                    QFile text(scanRoot.path() + QStringLiteral("/拒收-%1.txt").arg(i));
                    text.open(QIODevice::WriteOnly);
                    text.write("unsupported");
                }
                QFile text(notes);
                text.open(QIODevice::WriteOnly);
                text.write("unsupported");
                text.close();
                const auto expected = Importer::read({scanRoot.path()});
                const QString report = expected.problems.join(QLatin1Char('\n'));
                window.setLibraryWatchEnabled(false);
                window.m_libraryFolders = {scanRoot.path()};
                window.rescanLibrary();
                const bool scanned = waitFor([&] { return window.operationStatus().startsWith("扫描完成"); });
                check("scan_mixed_rejections_full_paths_and_reasons",
                      scanned && expected.tracks.size() == 1 && window.operationProblems() == report &&
                          report.contains(broken + "：音频解码失败") && report.contains(notes + "：不支持的文件格式") &&
                          window.operationStatus().contains("52"));
                SettingsWindow settings(&window);
                settings.findChild<SkinTabWidget *>()->setCurrentIndex(5);
                settings.show();
                auto *details = settings.findChild<QPlainTextEdit *>("libraryProblems");
                const bool visible = waitFor([&] { return details && details->toPlainText() == report; });
                check("scan_report_readonly_scrollable",
                      visible && details->isReadOnly() && details->verticalScrollBar()->maximum() > 0 &&
                          !details->autoFillBackground() && !details->viewport()->autoFillBackground());
                if (visible) {
                    QTextCursor cursor = details->textCursor();
                    cursor.setPosition(5);
                    cursor.setPosition(18, QTextCursor::KeepAnchor);
                    details->setTextCursor(cursor);
                    details->verticalScrollBar()->setValue(details->verticalScrollBar()->maximum() / 2);
                    const int scroll = details->verticalScrollBar()->value();
                    const QString selected = details->textCursor().selectedText();
                    QElapsedTimer elapsed;
                    elapsed.start();
                    waitFor([&] { return elapsed.elapsed() >= 600; });
                    check("scan_report_poll_preserves_selection_scroll",
                          details->textCursor().selectedText() == selected &&
                              details->verticalScrollBar()->value() == scroll);
                }
                window.loadPaths({broken, notes});
                const bool rejected = waitFor([&] { return window.operationStatus().startsWith("已导入 0 首"); });
                check("import_all_rejected_details", rejected && window.operationProblems().contains(broken) &&
                                                         window.operationProblems().contains(notes));
                const auto drained = [&] {
                    const auto watchers = window.findChildren<QFutureWatcherBase *>();
                    return std::all_of(watchers.cbegin(), watchers.cend(),
                                       [](const auto *watcher) { return watcher->isFinished(); });
                };
                bool cancelledReport = true, latestReport = true;
                for (int repeat = 0; repeat < 30; ++repeat) {
                    window.rescanLibrary();
                    window.cancelLibraryScan();
                    cancelledReport &= window.operationProblems().isEmpty() && waitFor(drained);
                    QCoreApplication::processEvents();
                    cancelledReport &= window.operationProblems().isEmpty() && window.operationStatus() == "扫描已取消";
                    window.rescanLibrary();
                    window.loadPaths({good});
                    latestReport &= window.operationProblems().isEmpty() &&
                                    waitFor([&] { return window.operationStatus().startsWith("已导入 1 首"); }) &&
                                    waitFor(drained);
                    QCoreApplication::processEvents();
                    latestReport &=
                        window.operationProblems().isEmpty() && window.operationStatus().startsWith("已导入 1 首");
                    ctl.stop();
                }
                check("scan_cancel_report_generation_30", cancelledReport);
                check("scan_import_latest_report_generation_30", latestReport);
                check("scan_report_clears_without_rejections",
                      waitFor([&] { return details->toPlainText().isEmpty(); }));
                const auto stored = window.collections().tracksOf(Collections::kLibraryViewId);
                check("scan_report_does_not_discard_valid_tracks",
                      stored.size() == 1 && stored.first().url().toLocalFile() == good);
                QTemporaryDir cleanRoot, rejectedRoot;
                QFile::copy(good, cleanRoot.path() + "/good.wav");
                QFile::copy(broken, rejectedRoot.path() + "/broken.wav");
                window.m_libraryFolders = {rejectedRoot.path()};
                window.rescanLibrary();
                check("scan_all_rejected_details",
                      waitFor([&] { return window.operationStatus().startsWith("扫描完成：0 首"); }) &&
                          window.operationProblems().contains(rejectedRoot.path() + "/broken.wav：音频解码失败"));
                window.m_libraryFolders = {cleanRoot.path()};
                window.rescanLibrary();
                check("scan_clean_report_clears",
                      waitFor([&] { return window.operationStatus().startsWith("扫描完成：1 首"); }) &&
                          window.operationProblems().isEmpty() &&
                          waitFor([&] { return details->toPlainText().isEmpty(); }));
                window.m_libraryFolders.clear();
            }
            const QString deferredKey = "http://127.0.0.1:1/deferred";
            window.restoreLibrary();
            window.loadDirOrFiles(
                {deferredKey},
                {{deferredKey, QJsonObject{{"title", "Deferred"}, {"artist", "Artist"}, {"album", "Album"}}}});
            const bool deferred = !window.m_deferredRadioEdits.isEmpty();
            const bool restored = waitFor([&] {
                if (window.isRestoringLibrary()) return false;
                return window.collections().trackForKey(deferredKey).title() == "Deferred";
            });
            ctl.stop();
            const Track saved = window.collections().trackForKey(deferredKey);
            check("import_radio_info_survives_restore", deferred && restored && saved.artist() == "Artist" &&
                                                            saved.album() == "Album" &&
                                                            window.m_deferredRadioEdits.isEmpty());
        } else if (suite == "COVER") {
            QImage image(2000, 1000, QImage::Format_RGB32);
            image.fill(Qt::blue);
            image.save(dir.path() + "/cover.png");
            auto small = CoverArt::imageForTrack(a, 112), large = CoverArt::imageForTrack(a, 256);
            check("cover_small", small.width() == 112 && small.height() == 56);
            check("cover_large", large.width() == 256);
            check("cover_original_dimensions", CoverArt::pixelSizeForTrack(a) == QSize(2000, 1000));
            CoverArt::clearCache();
            check("cover_cache_clear", !CoverArt::imageForTrack(a).isNull());
            for (int i = 0; i < 48; ++i) {
                QDir().mkpath(dir.path() + QStringLiteral("/album%1").arg(i));
                const QString song = dir.path() + QStringLiteral("/album%1/song.wav").arg(i);
                QFile::copy(path, song);
                image.fill(QColor::fromHsv(i * 7 % 360, 200, 200));
                image.save(QFileInfo(song).absolutePath() + "/cover.png");
                check("cover_large_downsampled",
                      CoverArt::imageForTrack(Track(QUrl::fromLocalFile(song))).width() == 256);
            }
            check("cover_LRU_8MiB", CoverArt::cacheBytes() <= qint64{8} * 1024 * 1024);
            out << "PERF cover_cache_bytes=" << CoverArt::cacheBytes() << '\n';
        } else if (suite == "ARCHIVE") {
            const QDir fixtures(qEnvironmentVariable("TTPLAYER_TESTDIR", QStringLiteral("testlib")));
            // 7z 与加密 ZIP 只由 7z 工具现场生成；缺工具时 fixture-skips 已记一条 SKIP，
            // 这里也显式列出，避免「少测了两档却看起来全过」。
            if (!QFile::exists(fixtures.filePath(QStringLiteral("archive.7z"))))
                out << "REVIEW_PROBE archive_7z SKIP fixture unavailable\n";
            if (!QFile::exists(fixtures.filePath(QStringLiteral("encrypted.zip"))))
                out << "REVIEW_PROBE encrypted_archive_rejected SKIP fixture unavailable\n";
            int containers = 0;
            for (const QString &name :
                 fixtures.entryList({"*.zip", "*.tar", "*.tar.gz", "*.tar.bz2", "*.7z"}, QDir::Files, QDir::Name)) {
                const QString archivePath = fixtures.filePath(name);
                // 套件超时会直接杀掉进程，stdout 里的探针结果也就跟着丢了；容器名与条目名
                // 先刷到 stderr，卡在哪个归档上（Windows 曾整档超时）从日志里直接能看出来。
                std::fprintf(stderr, "ARCHIVE container=%s\n", qUtf8Printable(name));
                std::fflush(stderr);
                const auto entries = Archive::listAudioEntries(archivePath);
                if (name == "encrypted.zip") {
                    check("encrypted_archive_rejected", entries.isEmpty());
                    continue;
                }
                check("archive_entries", !entries.isEmpty());
                for (const QString &entry : entries) {
                    std::fprintf(stderr, "ARCHIVE entry=%s\n", qUtf8Printable(entry));
                    std::fflush(stderr);
                    const QUrl url = Archive::entryUrl(archivePath, entry);
                    QString parsed, entryName;
                    check("archive_URL_roundtrip", Archive::parseEntryUrl(url, parsed, entryName) &&
                                                       parsed == archivePath && entryName == entry);
                    // 开流与读 PCM 分开计时并刷到 stderr：超时被杀时能分辨卡在
                    // FFmpeg 探测（openStream）还是解归档取数据（read）。
                    QElapsedTimer stage;
                    stage.start();
                    auto decoder =
                        Decoder::openStream(std::make_shared<ArchiveEntrySource>(archivePath, entry), url.toString());
                    std::fprintf(stderr, "ARCHIVE openStream ok=%d ms=%lld\n", int(bool(decoder)),
                                 static_cast<long long>(stage.elapsed()));
                    std::fflush(stderr);
                    check("archive_true_decoder", bool(decoder));
                    if (decoder) {
                        float l[128], r[128], repeat[128], right[128];
                        stage.restart();
                        const int count = decoder->read(l, r, 128, 44100);
                        const int again = decoder->read(repeat, right, 128, 44100);
                        std::fprintf(stderr, "ARCHIVE read2 ms=%lld\n", static_cast<long long>(stage.elapsed()));
                        std::fflush(stderr);
                        check("archive_seek_PCM", count == 128 && again == 128 && std::equal(l, l + 128, repeat));
                    }
                }
                ++containers;
            }
            check("archive_matrix", containers >= 4);
        } else if (suite == "SEARCH" || suite == "UI") {
            auto engine = AudioEngine::create();
            PlayerController ctl(engine);
            Collections col;
            col.setAllTracks({a, b});
            ctl.setTracks(col.currentTracks());
            PlaylistWindow searchPanel(&ctl, &col);
            searchPanel.m_view->selectAt(1, Qt::NoModifier);
            searchPanel.m_search->setText("Alpha");
            searchPanel.applySearch();
            check("global_search", ctl.tracks().size() == 1);
            searchPanel.clearSearch();
            check("search_restore_selection", searchPanel.m_view->selectedRows() == QList<int>{1});
            searchPanel.m_formats = {"FLAC"};
            searchPanel.applySearch();
            check("format_filter", ctl.tracks().size() == 1 && ctl.tracks().first().identityKey() == b.identityKey());
            searchPanel.clearSearch();
            searchPanel.sortView(4);
            check("sort_persisted", col.currentTracks().first().identityKey() == b.identityKey());
            // 总时长补齐三段，覆盖进位、24 小时以上与电台不计时。
            bool totalTime = true;
            const QList<QPair<double, QString>> times = {
                {0, "00:00:00"},      {59, "00:00:59"},    {60, "00:01:00"},     {3599, "00:59:59"},
                {3599.6, "01:00:00"}, {90061, "25:01:01"}, {360000, "100:00:00"}};
            for (const auto &entry : times) {
                Track timed(a.url());
                timed.setMetadata(entry.first, 44100, 2, 128);
                Track live = Track::fromRadio(QUrl("http://example.com/time"));
                live.setMetadata(500, 44100, 2, 128);
                ctl.setTracks({timed, live});
                totalTime &= searchPanel.m_info->text() == QStringLiteral("共 2 首 · %1").arg(entry.second);
            }
            ctl.setTracks({});
            check("playlist_total_time_hh_mm_ss", totalTime && searchPanel.m_info->text() == "共 0 首 · 00:00:00");
            ctl.setTracks(col.currentTracks());
            col.replaceLibrary({a, b});
            col.toggleFavorite(a.identityKey());
            QString list;
            col.playlists().create("Named", &list);
            col.playlists().addKeys({a.identityKey()}, list);
            // 自建歌单可直接收音频/目录（同一条 Importer 链路），不必先写 m3u；固定页拒绝。
            QString direct;
            col.playlists().create("DirectAdd", &direct);
            check("playlist_add_tracks_to_list", searchPanel.addTracksToPlaylist({b}, direct) == 1 &&
                                                     col.playlists().keysOf(direct).contains(b.identityKey()));
            check("playlist_add_tracks_dedup", searchPanel.addTracksToPlaylist({b}, direct) == 0);
            check("playlist_add_tracks_fixed_view", searchPanel.addTracksToPlaylist({b}, Collections::kAllViewId) == 0);
            col.playlists().remove(direct);
            ctl.queue().begin({a, b, a}, 0);
            searchPanel.m_search->setText("Alpha");
            searchPanel.applySearch();
            searchPanel.removeRows({0});
            check("search_delete_all_writable_pages",
                  !col.isFavorite(a.identityKey()) && col.playlists().keysOf(list).isEmpty());
            check("search_delete_keeps_library", col.tracksOf(Collections::kLibraryViewId).size() == 2);
            check("search_delete_keeps_current",
                  ctl.queue().currentTrack().identityKey() == a.identityKey() && ctl.queue().count() == 2);
            check("search_stays_active_after_delete", searchPanel.m_beforeSearch.has_value());
            searchPanel.clearSearch();
            check("search_exit_original_page",
                  ctl.tracks().size() == 1 && ctl.tracks().first().identityKey() == b.identityKey());
            col.registerTracks({a});
            col.toggleFavorite(a.identityKey());
            ctl.queue().begin({a, b}, 0);
            int deleted = 0;
            auto deletion = QObject::connect(&searchPanel, &PlaylistWindow::trackRemoved, &searchPanel,
                                             [&deleted](const Track &) { ++deleted; });
            searchPanel.showPage(Collections::kFavViewId);
            searchPanel.removeRows({0});
            check("cancel_favorite_keeps_queue_and_default",
                  deleted == 0 && ctl.queue().count() == 2 && col.tracksOf(Collections::kAllViewId).size() == 2);
            searchPanel.showPage(Collections::kAllViewId);
            int otherRow = -1;
            for (int row = 0; row < ctl.tracks().size(); ++row)
                if (ctl.tracks()[row].identityKey() == b.identityKey()) otherRow = row;
            searchPanel.removeRows({otherRow});
            check("default_delete_drops_other_context_items",
                  deleted == 1 && ctl.queue().count() == 1 &&
                      ctl.queue().currentTrack().identityKey() == a.identityKey());
            QObject::disconnect(deletion);
            QDir().mkpath(dir.path() + "/ambiguous");
            const QString audio = dir.path() + "/ambiguous/01 - song.wav";
            for (const QString &name : QStringList{"song.lrc", "song!.lrc"}) {
                QFile f(dir.path() + "/ambiguous/" + name);
                f.open(QIODevice::WriteOnly);
                f.write("[00:00.00]Text\n");
            }
            check("ambiguous_normalized_lyric_rejected",
                  Lyric::loadForTrack(Track(QUrl::fromLocalFile(audio))).isEmpty());
            if (suite == "UI") {
                check("approved_dark_windowTop", Theme::windowTop.rgba() == 0xff3c4248u);
                check("approved_dark_windowBottom", Theme::windowBottom.rgba() == 0xff1c2024u);
                check("approved_dark_panel", Theme::panel.rgba() == 0xff2a2e32u);
                check("approved_dark_skinEdge", Theme::skinEdge.rgba() == 0xff565c62u);
                check("approved_dark_innerHighlight", Theme::innerHighlight.rgba() == 0x38ffffffu);
                check("approved_dark_shellDivider", Theme::shellDivider.rgba() == 0xff4a5056u);
                check("approved_dark_titleTop", Theme::titleTop.rgba() == 0xff454b51u);
                check("approved_dark_titleBottom", Theme::titleBottom.rgba() == 0xff262a2eu);
                check("approved_dark_titleText", Theme::titleText.rgba() == 0xffedeff1u);
                check("approved_dark_wellTop", Theme::wellTop.rgba() == 0xff14171au);
                check("approved_dark_wellBottom", Theme::wellBottom.rgba() == 0xff0c0e10u);
                check("approved_dark_listBackground", Theme::listBackground.rgba() == 0xff101315u);
                check("approved_dark_wellBevelDark", Theme::wellBevelDark.rgba() == 0xff000000u);
                check("approved_dark_wellBevelLight", Theme::wellBevelLight.rgba() == 0xff454b51u);
                check("approved_dark_groove", Theme::groove.rgba() == 0xff24282cu);
                check("approved_dark_textPrimary", Theme::textPrimary.rgba() == 0xffe8eaecu);
                check("approved_dark_textSecondary", Theme::textSecondary.rgba() == 0xffa6acb2u);
                check("approved_dark_textAccent", Theme::textAccent.rgba() == 0xfff2a93bu);
                check("approved_dark_textHighlight", Theme::textHighlight.rgba() == 0xffffffffu);
                check("approved_dark_buttonLightTop", Theme::buttonLightTop.rgba() == 0xff4e545au);
                check("approved_dark_buttonLightMid", Theme::buttonLightMid.rgba() == 0xff3a3e42u);
                check("approved_dark_buttonLightBottom", Theme::buttonLightBottom.rgba() == 0xff24282cu);
                check("approved_dark_buttonDownTop", Theme::buttonDownTop.rgba() == 0xff24282cu);
                check("approved_dark_buttonDownMid", Theme::buttonDownMid.rgba() == 0xff33373bu);
                check("approved_dark_buttonDownBottom", Theme::buttonDownBottom.rgba() == 0xff4a5056u);
                check("approved_dark_buttonTop", Theme::buttonTop.rgba() == 0xff4a5056u);
                check("approved_dark_buttonBottom", Theme::buttonBottom.rgba() == 0xff2c3034u);
                check("approved_dark_buttonHotTop", Theme::buttonHotTop.rgba() == 0xff565c62u);
                check("approved_dark_buttonHotBottom", Theme::buttonHotBottom.rgba() == 0xff383c40u);
                check("approved_dark_buttonFace", Theme::buttonFace.rgba() == 0xff3a3e42u);
                check("approved_dark_buttonHot", Theme::buttonHot.rgba() == 0xff484c50u);
                check("approved_dark_buttonPressed", Theme::buttonPressed.rgba() == 0xff22262au);
                check("approved_dark_buttonEdge", Theme::buttonEdge.rgba() == 0xff5a6066u);
                check("approved_dark_border", Theme::border.rgba() == 0xff4a5056u);
                check("approved_dark_flatText", Theme::flatText.rgba() == 0xffe0e2e4u);
                check("approved_dark_flatTextHot", Theme::flatTextHot.rgba() == 0xffffffffu);
                check("approved_dark_flatHotBG", Theme::flatHotBG.rgba() == 0x8c4a5056u);
                check("approved_dark_flatEdgeHot", Theme::flatEdgeHot.rgba() == 0xcc6a7076u);
                check("approved_dark_flatTextOnLight", Theme::flatTextOnLight.rgba() == 0xffe0e2e4u);
                check("approved_dark_flatTextOnLightHot", Theme::flatTextOnLightHot.rgba() == 0xffffffffu);
                check("approved_dark_flatHotOnLightBG", Theme::flatHotOnLightBG.rgba() == 0xe54a5056u);
                check("approved_dark_spectrumTop", Theme::spectrumTop.rgba() == 0xfff7c860u);
                check("approved_dark_spectrumBottom", Theme::spectrumBottom.rgba() == 0xffe08a20u);
                check("approved_dark_spectrumPeak", Theme::spectrumPeak.rgba() == 0xfffff2d0u);
                check("approved_dark_spectrumGrid", Theme::spectrumGrid.rgba() == 0x268a9096u);
                check("approved_dark_meterGreen", Theme::meterGreen.rgba() == 0xff7fd08au);
                check("approved_dark_meterYellow", Theme::meterYellow.rgba() == 0xfff0dc82u);
                check("approved_dark_meterRed", Theme::meterRed.rgba() == 0xffe88c7au);
                check("approved_dark_hairline", Theme::hairline.rgba() == 0x7f5a6066u);
                check("approved_dark_inkOnGlass", Theme::inkOnGlass.rgba() == 0xffedeff1u);
                check("approved_dark_inkOnGlassSoft", Theme::inkOnGlassSoft.rgba() == 0xffb0b6bcu);
                check("approved_dark_inkOnGlassAccent", Theme::inkOnGlassAccent.rgba() == 0xfff2a93bu);
                check("numeric_font_size_weight_preserved",
                      Fonts::numericSmall.pointSize() == Fonts::small.pointSize() &&
                          Fonts::numericTiny.pointSize() == Fonts::tiny.pointSize() &&
                          Fonts::numericSmall.weight() == Fonts::small.weight() &&
                          Fonts::numericTiny.weight() == Fonts::tiny.weight());
#ifdef Q_OS_WIN
                check("approved_font_size", Fonts::base.pointSize() == 12 && Fonts::small.pointSize() == 11 &&
                                                Fonts::tiny.pointSize() == 10 && Fonts::title.pointSize() == 12 &&
                                                Fonts::panelTitle.pointSize() == 12);
                check("approved_font_families",
                      Fonts::base.families() == QStringList{"Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI",
                                                            "Helvetica Neue", "Arial", "Noto Sans", "DejaVu Sans",
                                                            "PingFang SC", "sans-serif"});
                check("windows_font_all_roles", QApplication::font().family() == QStringLiteral("Microsoft YaHei UI") &&
                                                    Fonts::small.family() == Fonts::base.family() &&
                                                    Fonts::tiny.family() == Fonts::base.family() &&
                                                    Fonts::title.family() == Fonts::base.family() &&
                                                    Fonts::panelTitle.family() == Fonts::base.family());
                check("windows_numeric_font_roles",
                      Fonts::numericSmall.family() == QStringLiteral("Segoe UI") &&
                          Fonts::numericTiny.families() == Fonts::numericSmall.families() &&
                          Fonts::numericTiny.families().contains("Microsoft YaHei UI"));
#else
                check("approved_font_size", Fonts::base.pointSize() == 13 && Fonts::small.pointSize() == 12 &&
                                                Fonts::tiny.pointSize() == 11 && Fonts::title.pointSize() == 13 &&
                                                Fonts::panelTitle.pointSize() == 13);
                check("numeric_fonts_preserve_platform",
                      Fonts::numericSmall == Fonts::small && Fonts::numericTiny == Fonts::tiny);
                check("approved_font_families",
                      Fonts::base.families() == QStringList{"Helvetica Neue", "Arial", "Noto Sans",
                                                            "DejaVu Sans", "PingFang SC", "Microsoft YaHei",
                                                            "sans-serif"});
#endif
                {
                    Collections sidebar;
                    const Track station = Track::fromRadio(QUrl("http://example.com/sidebar"));
                    sidebar.setAllTracks({a, station});
                    sidebar.recordRadioPlay(station.identityKey());
                    QString listId, categoryId;
                    // 列表与分类故意同名，验证排序和选中恢复只依赖稳定身份。
                    sidebar.playlists().create(QStringLiteral("通勤"), &listId);
                    sidebar.radios().createCategory(QStringLiteral("通勤"), &categoryId, nullptr);
                    QString problem;
                    sidebar.radios().moveRadios({station.identityKey()}, categoryId, &problem);
                    PlayerController sidebarCtl(engine);
                    sidebarCtl.setTracks(sidebar.currentTracks());
                    PlaylistWindow sidebarPanel(&sidebarCtl, &sidebar);
                    QStringList visibleIds;
                    for (int row = 0; row < sidebarPanel.m_groups->count(); ++row)
                        visibleIds << sidebarPanel.m_groups->rowData(row).toString();
                    const QString categoryView = Collections::radioCatViewId(categoryId);
                    check("UI_sidebar_radio_entries_last",
                          visibleIds ==
                              QStringList({Collections::kAllViewId, Collections::kLibraryViewId,
                                           Collections::kRecentViewId, Collections::kFavViewId, listId,
                                           Collections::kRadioViewId, Collections::kRecentRadioViewId,
                                           Collections::radioCatViewId(RadioStations::uncategorizedID), categoryView}));
                    sidebarPanel.probeShowView(categoryView);
                    const int oldRow = sidebarPanel.m_groups->currentRow();
                    QString addedList;
                    sidebar.playlists().create(QStringLiteral("新增列表"), &addedList);
                    sidebarPanel.refreshGroups();
                    check("UI_sidebar_refresh_keeps_radio_identity",
                          sidebarPanel.m_groups->currentRow() == oldRow + 1 &&
                              sidebarPanel.m_groups->rowData(sidebarPanel.m_groups->currentRow()).toString() ==
                                  categoryView &&
                              sidebar.viewId() == categoryView && sidebarCtl.tracks().size() == 1 &&
                              sidebarCtl.tracks().first().identityKey() == station.identityKey());
                    LibraryStore::Loaded state;
                    sidebar.saveTo(state);
                    Collections restoredSidebar;
                    restoredSidebar.loadFrom(state);
                    restoredSidebar.setAllTracks(sidebar.allTracks());
                    PlayerController restoredCtl(engine);
                    restoredCtl.setTracks(restoredSidebar.currentTracks());
                    PlaylistWindow restoredPanel(&restoredCtl, &restoredSidebar);
                    check("UI_sidebar_restore_selects_radio_identity",
                          restoredPanel.m_groups->rowData(restoredPanel.m_groups->currentRow()).toString() ==
                                  categoryView &&
                              restoredSidebar.viewId() == categoryView && restoredCtl.tracks().size() == 1 &&
                              restoredCtl.tracks().first().identityKey() == station.identityKey());

                    sidebarPanel.show();
                    QCoreApplication::processEvents();
                    int sidebarChanges = 0;
                    QObject::connect(&sidebarPanel, &PlaylistWindow::collectionsChanged, &sidebarPanel,
                                     [&] { ++sidebarChanges; });
                    QStringList sidebarPaths;
                    bool inputMatched = false;
                    // 发送真实右键事件，并在菜单内按回车；弹窗操作与超时均由局部定时器收束。
                    const auto contextAt = [&](const QPoint &pos, const QString &actionText = QString(),
                                               const QString &name = QString(), bool accept = false) {
                        sidebarPaths.clear();
                        inputMatched = false;
                        bool menuSeen = false;
                        QTimer popup, input, timeout;
                        popup.setSingleShot(true);
                        input.setSingleShot(true);
                        QObject::connect(&input, &QTimer::timeout, &sidebarPanel, [&] {
                            auto *dialog = qobject_cast<QInputDialog *>(QApplication::activeModalWidget());
                            if (!dialog) return;
                            inputMatched = dialog->windowTitle() == "新建列表" && dialog->labelText() == "列表名称";
                            dialog->setTextValue(name);
                            if (accept)
                                dialog->accept();
                            else
                                dialog->reject();
                        });
                        QObject::connect(&popup, &QTimer::timeout, &sidebarPanel, [&] {
                            auto *menu = qobject_cast<QMenu *>(QApplication::activePopupWidget());
                            if (!menu) return;
                            menuSeen = true;
                            sidebarPaths = menuPaths(*menu);
                            QAction *action = findMenuAction(*menu, actionText);
                            if (!action) {
                                menu->close();
                                return;
                            }
                            input.start(0);
                            menu->setActiveAction(action);
                            QKeyEvent choose(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
                            QApplication::sendEvent(menu, &choose);
                        });
                        QObject::connect(&timeout, &QTimer::timeout, &sidebarPanel, [] {
                            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget()))
                                dialog->reject();
                            if (QWidget *menu = QApplication::activePopupWidget()) menu->close();
                        });
                        const QPoint global = sidebarPanel.m_groups->mapToGlobal(pos);
                        QMouseEvent press(QEvent::MouseButtonPress, pos, global, Qt::RightButton, Qt::RightButton,
                                          Qt::NoModifier);
                        QMouseEvent release(QEvent::MouseButtonRelease, pos, global, Qt::RightButton, Qt::NoButton,
                                            Qt::NoModifier);
                        QApplication::sendEvent(sidebarPanel.m_groups, &press);
                        QApplication::sendEvent(sidebarPanel.m_groups, &release);
                        popup.start(0);
                        timeout.start(1000);
                        QContextMenuEvent context(QContextMenuEvent::Mouse, pos, global);
                        QApplication::sendEvent(sidebarPanel.m_groups, &context);
                        return menuSeen;
                    };
                    bool everyRow = true, categoriesUnchanged = true;
                    for (int row = 0; row < sidebarPanel.m_groups->count(); ++row) {
                        const QString view = sidebarPanel.m_groups->rowData(row).toString();
                        const bool opened = contextAt(QPoint(10, row * 22 + 11));
                        everyRow &= opened && sidebarPaths.count("新建列表…") == 1;
                        const bool categoryActions =
                            view == Collections::kRadioViewId || Collections::isRadioCatView(view);
                        categoriesUnchanged &= sidebarPaths.contains("新建电台分类…") == categoryActions &&
                                               sidebarPaths.contains("重命名分类「通勤」…") == (view == categoryView) &&
                                               sidebarPaths.contains("删除分类「通勤」…") == (view == categoryView);
                    }
                    const QPoint blank(10, sidebarPanel.m_groups->height() - 10);
                    check("UI_sidebar_context_new_list_everywhere",
                          everyRow && sidebarPanel.m_groups->rowAt(blank) < 0 && contextAt(blank) &&
                              sidebarPaths.count("新建列表…") == 1 && sidebarPaths.contains("添加/添加文件…") &&
                              !sidebarPaths.contains("清空列表") && !sidebarPaths.contains("重命名列表…") &&
                              sidebar.playlists().count() == 2 && sidebarChanges == 0);
                    check("UI_sidebar_context_keeps_category_actions", categoriesUnchanged);
                    bool unopenedMenus = true;
                    for (int repeat = 0; repeat < 30; ++repeat) {
                        sidebarCtl.stop();
                        sidebarPanel.probeShowView(Collections::kAllViewId);
                        unopenedMenus &= contextAt(QPoint(10, 11)) && !sidebarPaths.contains("定位当前曲");
                        sidebarPanel.probeShowView(listId);
                        unopenedMenus &= sidebarCtl.tracks().isEmpty() && contextAt(QPoint(10, 4 * 22 + 11));
                        sidebarPanel.probeShowView(Collections::kAllViewId);
                        sidebarPanel.probeSearch("example.com");
                        unopenedMenus &= contextAt(QPoint(10, 11)) && !sidebarPaths.contains("定位当前曲") &&
                                         sidebarPanel.m_search->text() == "example.com" && contextAt(blank);
                    }
                    check("UI_sidebar_unplayed_empty_search_menus_30",
                          unopenedMenus && sidebarCtl.currentTrack().isNull());

                    sidebarPanel.probeShowView(Collections::kAllViewId);
                    sidebarPanel.probeSearch("example.com");
                    const QList<Track> searchTracks = sidebarCtl.tracks();
                    check("UI_sidebar_create_cancel_preserves_search",
                          contextAt(blank, "新建列表…", "取消的列表") && inputMatched &&
                              sidebar.playlists().count() == 2 && sidebarChanges == 0 && sidebarPanel.m_beforeSearch &&
                              sidebarPanel.m_search->text() == "example.com" &&
                              sidebar.viewId() == Collections::kAllViewId && searchTracks.size() == 1 &&
                              sidebarCtl.tracks().size() == 1 &&
                              sidebarCtl.tracks().first().identityKey() == searchTracks.first().identityKey());
                    const bool createdFromBlank = contextAt(blank, "新建列表…", "  侧栏新列表  ", true);
                    const QString createdId = sidebar.viewId();
                    check("UI_sidebar_create_from_blank_selects_new_list",
                          createdFromBlank && inputMatched && sidebar.playlists().count() == 3 && sidebarChanges == 1 &&
                              sidebar.playlists().nameOf(createdId) == "侧栏新列表" && sidebarCtl.tracks().isEmpty() &&
                              !sidebarPanel.m_beforeSearch && !sidebarPanel.m_searchOpen &&
                              sidebarPanel.selectedViewId() == createdId &&
                              sidebarPanel.m_groups->rowData(6).toString() == createdId &&
                              sidebarPanel.m_groups->rowData(7).toString() == Collections::kRadioViewId);
                    const bool createdFromRow = contextAt(QPoint(10, 11), "新建列表…", "侧栏新列表", true);
                    const QString secondId = sidebar.viewId();
                    LibraryStore::Loaded createdState;
                    sidebar.saveTo(createdState);
                    Collections createdBack;
                    createdBack.loadFrom(createdState);
                    check("UI_sidebar_create_from_row_deduplicates_and_restores",
                          createdFromRow && inputMatched && sidebar.playlists().count() == 4 && sidebarChanges == 2 &&
                              secondId != createdId && sidebar.playlists().contains(secondId) &&
                              sidebar.playlists().nameOf(secondId) != sidebar.playlists().nameOf(createdId) &&
                              sidebarPanel.selectedViewId() == secondId && createdBack.viewId() == secondId &&
                              createdBack.viewList() == sidebar.viewList());
                }
                {
                    // 长列表必须实际出现滚动条；检查绘制 alpha 与真实拖动，不只匹配 QSS 文本。
                    const bool wasEnabled = GlassStyle::enabled();
                    const float oldAlpha = GlassStyle::transparency();
                    PlayerController scrollCtl(AudioEngine::create());
                    QList<Track> longList;
                    for (int row = 0; row < 100; ++row) {
                        Track track(QUrl::fromLocalFile(dir.path() + QStringLiteral("/scroll-%1.wav").arg(row)));
                        track.setTitle(QStringLiteral("Track %1").arg(row));
                        longList.append(track);
                    }
                    scrollCtl.setTracks(longList);
                    PlaylistView view(&scrollCtl);
                    view.resize(360, 180);
                    view.show();
                    QCoreApplication::processEvents();
                    auto *bar = view.verticalScrollBar();
                    QScrollBar nativeBar(Qt::Vertical);
                    check("UI_playlist_scrollbar_long_list", bar->isVisible() && bar->maximum() > 0);
                    check("UI_playlist_scrollbar_preserves_width",
                          bar->width() == nativeBar.sizeHint().width() &&
                              view.viewport()->width() == view.width() - bar->width());
                    const auto handleRect = [&] {
                        QStyleOptionSlider option;
                        option.initFrom(bar);
                        option.orientation = Qt::Vertical;
                        option.minimum = bar->minimum();
                        option.maximum = bar->maximum();
                        option.sliderPosition = bar->sliderPosition();
                        option.sliderValue = bar->value();
                        option.singleStep = bar->singleStep();
                        option.pageStep = bar->pageStep();
                        return bar->style()->subControlRect(QStyle::CC_ScrollBar, &option, QStyle::SC_ScrollBarSlider,
                                                            bar);
                    };
                    const auto alphaMatches = [&](int expected) {
                        QImage image(bar->size(), QImage::Format_ARGB32_Premultiplied);
                        image.fill(Qt::transparent);
                        bar->render(&image, QPoint(), QRegion(), QWidget::RenderFlags{});
                        const QRect handle = handleRect();
                        bool transparentTrack = !handle.isEmpty() && !bar->autoFillBackground() &&
                                                !bar->parentWidget()->autoFillBackground();
                        for (int y = 0; y < image.height(); ++y)
                            for (int x = 0; x < image.width(); ++x)
                                if (!handle.contains(x, y)) transparentTrack &= image.pixelColor(x, y).alpha() == 0;
                        return transparentTrack && std::abs(image.pixelColor(handle.center()).alpha() - expected) <= 1;
                    };
                    view.selectAt(2, Qt::NoModifier);
                    bar->setValue(120);
                    const auto scene = view.scene();
                    GlassStyle::setEnabled(true);
                    bool alphaTracksGlass = true;
                    for (float alpha : {0.0f, 0.15f, 0.65f, 1.0f}) {
                        GlassStyle::setTransparency(alpha);
                        QCoreApplication::processEvents();
                        alphaTracksGlass &= alphaMatches(qRound(alpha * 255)) && view.scene().scroll == scene.scroll &&
                                            view.scene().selected == scene.selected;
                    }
                    check("UI_playlist_scrollbar_transparent_track_and_glass_handle", alphaTracksGlass);
                    GlassStyle::setEnabled(false);
                    check("UI_playlist_scrollbar_glass_off", alphaMatches(255));
                    GlassStyle::setTransparency(oldAlpha);
                    GlassStyle::setEnabled(wasEnabled);
                    bar->setValue(0);
                    const QPoint start = handleRect().center();
                    const QPoint end = start + QPoint(0, 40);
                    QMouseEvent press(QEvent::MouseButtonPress, start, bar->mapToGlobal(start), Qt::LeftButton,
                                      Qt::LeftButton, Qt::NoModifier);
                    QApplication::sendEvent(bar, &press);
                    QMouseEvent move(QEvent::MouseMove, end, bar->mapToGlobal(end), Qt::NoButton, Qt::LeftButton,
                                     Qt::NoModifier);
                    QApplication::sendEvent(bar, &move);
                    QMouseEvent release(QEvent::MouseButtonRelease, end, bar->mapToGlobal(end), Qt::LeftButton,
                                        Qt::NoButton, Qt::NoModifier);
                    QApplication::sendEvent(bar, &release);
                    check("UI_playlist_scrollbar_drag",
                          bar->value() > 0 && view.rowAtPos(QPoint(0, 0)) == bar->value() / PlaylistView::kRowH);
                    bar->setValue(0);
                    const QPoint wheelPos = view.viewport()->rect().center();
                    QWheelEvent wheel(wheelPos, view.viewport()->mapToGlobal(wheelPos), QPoint(), QPoint(0, -120),
                                      Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
                    QApplication::sendEvent(view.viewport(), &wheel);
                    check("UI_playlist_scrollbar_wheel", bar->value() > 0);
                    scrollCtl.setTracks({longList.first()});
                    QCoreApplication::processEvents();
                    check("UI_playlist_scrollbar_short_list", !bar->isVisible() && bar->value() == 0);
                }
                {
                    Collections favorites;
                    PlayerController favoriteCtl(engine);
                    QList<Track> tracks;
                    for (int i = 0; i < 40; ++i) {
                        Track t(QUrl::fromLocalFile(dir.path() + QStringLiteral("/favorite-%1.wav").arg(i)));
                        t.setTitle(QStringLiteral("Favorite %1 with a deliberately long title").arg(i));
                        t.setMetadata(300, 44100, 2, 1411);
                        tracks.append(t);
                    }
                    tracks[1] = Track::fromCueSegment(tracks[1].url(), 1,
                                                      QUrl::fromLocalFile(dir.path() + "/favorite.cue"), 0, 1);
                    tracks[2] = Track(Archive::entryUrl(dir.path() + "/archive.zip", "song.flac"));
                    tracks[3] = Track::fromRadio(QUrl("http://example.com/favorite"));
                    tracks[1].setMetadata(60000, 44100, 2, 1411);
                    tracks[4].setMetadata(599, 44100, 2, 1411);
                    tracks[5].setMetadata(5999, 44100, 2, 1411);
                    favorites.setAllTracks(tracks);
                    favoriteCtl.setTracks(favorites.currentTracks());
                    PlaylistWindow favoritePanel(&favoriteCtl, &favorites);
                    favoritePanel.resize(420, 240);
                    favoritePanel.show();
                    QCoreApplication::processEvents();
                    auto *view = favoritePanel.m_view;
                    auto mouse = [&](QEvent::Type type, QPoint pos, Qt::MouseButtons buttons) {
                        QMouseEvent event(type, pos, view->viewport()->mapToGlobal(pos),
                                          type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton, buttons,
                                          Qt::NoModifier);
                        QApplication::sendEvent(view->viewport(), &event);
                    };
                    auto click = [&](int row) {
                        const QPoint pos = view->favoriteRect(row).center();
                        mouse(QEvent::MouseButtonPress, pos, Qt::LeftButton);
                        mouse(QEvent::MouseButtonRelease, pos, Qt::NoButton);
                    };
                    int toggled = 0, played = 0, dragged = 0;
                    QObject::connect(view, &PlaylistView::toggleFavoriteRequested, view,
                                     [&](const QString &) { ++toggled; });
                    QObject::connect(view, &PlaylistView::activateRow, view, [&](int) { ++played; });
                    QObject::connect(view, &PlaylistView::reorderRequested, view, [&](int) { ++dragged; });
                    const QStringList durations = {"5:00", "1000:00", "...", "直播", "9:59", "99:59"};
                    const QImage spacing = view->viewport()->grab().toImage();
                    const qreal spacingDpr = spacing.devicePixelRatio();
                    bool gapGeometry = true, gapPixels = true;
                    for (int row = 0; row < durations.size(); ++row) {
                        QFont font = row == 3 ? Fonts::small : Fonts::numericSmall;
                        font.setStyleStrategy(QFont::PreferMatch);
                        const qreal textLeft = view->viewport()->width() - 4 -
                                               QFontMetricsF(font, view->viewport()).horizontalAdvance(durations[row]);
                        const QRectF glyph = view->favoriteGlyphRect(row);
                        const QRect hit = view->favoriteRect(row);
                        gapGeometry &= std::abs(textLeft - glyph.right() - 2) < 0.001 &&
                                       glyph.size() == QSizeF(14, 14) && hit.width() == 24 && hit.right() < textLeft &&
                                       view->favoriteHit(hit.center(), row) &&
                                       !view->favoriteHit(QPoint(int(std::ceil(textLeft)), row * 24 + 12), row);
                        // 间隙中心必须只有行背景，避免图标描边、名称或文字侵入 2 px 空隙。
                        const int x = qRound((textLeft - 1) * spacingDpr);
                        for (int y = qRound(row * 24 * spacingDpr);
                             y < qMin(spacing.height(), qRound((row + 1) * 24 * spacingDpr)); ++y)
                            gapPixels &= spacing.pixel(x, y) == spacing.pixel(spacing.width() - 1, y);
                    }
                    check("UI_favorite_duration_geometry", gapGeometry);
                    check("UI_favorite_duration_gap_pixels", gapPixels);
                    const QString spacingReport = qEnvironmentVariable("TTPLAYER_PROBE");
                    if (!spacingReport.isEmpty()) spacing.save(spacingReport + "/favorite-duration-spacing.png");
                    const QPoint durationPos(int(std::ceil(view->durationTextLeft(0))) + 2, 12);
                    mouse(QEvent::MouseButtonPress, durationPos, Qt::LeftButton);
                    mouse(QEvent::MouseButtonRelease, durationPos, Qt::NoButton);
                    check("UI_favorite_duration_click_not_favorite",
                          toggled == 0 && played == 0 && dragged == 0 && view->selectedRow() == 0);
                    view->selectAt(0, Qt::NoModifier);
                    view->selectAt(2, Qt::ControlModifier);
                    view->selectAt(0, Qt::ShiftModifier);
                    const auto before = view->scene();
                    const QImage outline = view->viewport()->grab().toImage();
                    click(0);
                    const QImage filled = view->viewport()->grab().toImage();
                    const QRect heart = view->favoriteRect(0);
                    const qreal dpr = filled.devicePixelRatio();
                    const QRect crop(qRound(heart.x() * dpr), qRound(heart.y() * dpr), qRound(heart.width() * dpr),
                                     qRound(heart.height() * dpr));
                    check("UI_favorite_outline_filled_pixels", outline.copy(crop) != filled.copy(crop));
                    check("UI_favorite_tooltip_updates_after_click", view->viewport()->toolTip() == "取消收藏");
                    check("UI_favorite_single_identity_preserves_selection",
                          favorites.isFavorite(tracks[0].identityKey()) &&
                              !favorites.isFavorite(tracks[1].identityKey()) &&
                              view->scene().selected == before.selected && view->scene().primary == before.primary &&
                              view->scene().anchor == before.anchor);
                    const QPoint pos = view->favoriteRect(0).center();
                    mouse(QEvent::MouseButtonDblClick, pos, Qt::LeftButton);
                    mouse(QEvent::MouseButtonRelease, pos, Qt::NoButton);
                    check("UI_favorite_double_click_no_play_or_retoggle", toggled == 1 && played == 0 && dragged == 0);
                    mouse(QEvent::MouseButtonPress, pos, Qt::LeftButton);
                    mouse(QEvent::MouseMove, pos - QPoint(40, 0), Qt::LeftButton);
                    mouse(QEvent::MouseMove, pos, Qt::LeftButton);
                    mouse(QEvent::MouseButtonRelease, pos, Qt::NoButton);
                    mouse(QEvent::MouseButtonPress, pos, Qt::LeftButton);
                    mouse(QEvent::MouseButtonRelease, pos - QPoint(40, 0), Qt::NoButton);
                    check("UI_favorite_drag_and_outside_release_cancel", toggled == 1 && dragged == 0);
                    mouse(QEvent::MouseButtonPress, pos, Qt::LeftButton);
                    view->verticalScrollBar()->setValue(24);
                    mouse(QEvent::MouseButtonRelease, pos, Qt::NoButton);
                    check("UI_favorite_scroll_identity_cancel", toggled == 1);
                    view->verticalScrollBar()->setValue(0);
                    mouse(QEvent::MouseButtonPress, pos, Qt::LeftButton);
                    favoriteCtl.setTracks(favorites.currentTracks());
                    mouse(QEvent::MouseButtonRelease, pos, Qt::NoButton);
                    check("UI_favorite_refresh_cancel", toggled == 1);
                    for (int row : {1, 2, 3})
                        click(row);
                    check("UI_favorite_all_identity_types", favorites.favorites().size() == 4);
                    favoritePanel.showPage(Collections::kFavViewId);
                    const QPoint removedPos = view->favoriteRect(0).center();
                    click(0);
                    const QString remaining = favoriteCtl.tracks().first().identityKey();
                    const int afterRemoval = toggled;
                    mouse(QEvent::MouseButtonDblClick, removedPos, Qt::LeftButton);
                    mouse(QEvent::MouseButtonRelease, removedPos, Qt::NoButton);
                    check("UI_favorite_page_removes_row_double_click_safe",
                          !favorites.isFavorite(tracks[0].identityKey()) && favorites.isFavorite(remaining) &&
                              !view->favoriteHit(removedPos, 0) && favoriteCtl.tracks().size() == 3 &&
                              toggled == afterRemoval && played == 0);
                    favoritePanel.showPage(Collections::kAllViewId);
                    view->selectAt(4, Qt::NoModifier);
                    view->verticalScrollBar()->setValue(48);
                    favoritePanel.m_search->setText("Favorite 0");
                    favoritePanel.applySearch();
                    const auto original = favoritePanel.m_beforeSearch;
                    click(0);
                    check("UI_favorite_search_preserves_presearch_scene",
                          favoritePanel.m_beforeSearch && original &&
                              favoritePanel.m_beforeSearch->selected == original->selected &&
                              favoritePanel.m_beforeSearch->scroll == original->scroll &&
                              favoritePanel.m_search->text() == "Favorite 0");
                    favoritePanel.clearSearch();
                    check("UI_favorite_search_exit_restores_scene",
                          view->selectedRows() == QList<int>{4} && view->verticalScrollBar()->value() == 48);
                    favoritePanel.m_formats = {"WAV"};
                    favoritePanel.applySearch();
                    const int beforeFormatClick = toggled;
                    click(view->verticalScrollBar()->value() / PlaylistView::kRowH);
                    check("UI_favorite_format_real_click", toggled == beforeFormatClick + 1);
                    check("UI_favorite_format_filter_preserved",
                          favoritePanel.m_formats == QSet<QString>{"WAV"} && favoritePanel.m_beforeSearch.has_value());
                    favoritePanel.clearSearch();
                    PlaylistView independent(&favoriteCtl);
                    check("UI_favorite_no_collection_no_hit", !independent.favoriteHit(QPoint(1, 1), 0));
                }
                {
                    const bool enabled = GlassStyle::enabled();
                    const float transparency = GlassStyle::transparency();
                    GlassStyle::setEnabled(true);
                    GlassStyle::setTransparency(0.2f);
                    SkinMenu menu;
                    auto *first = menu.addAction("First");
                    first->setCheckable(true);
                    first->setChecked(true);
                    auto *disabled = menu.addAction("Disabled");
                    disabled->setEnabled(false);
                    auto *sub = SkinMenu::addSubmenu(menu, "Submenu");
                    auto *nested = SkinMenu::addSubmenu(*sub, "Nested");
                    nested->addAction("Leaf");
                    menu.popup(QPoint(10, 10));
                    QCoreApplication::processEvents();
                    const auto render = [](QWidget &widget) {
                        QImage image(widget.size(), QImage::Format_ARGB32_Premultiplied);
                        image.fill(Qt::transparent);
                        widget.render(&image, QPoint(), QRegion(), QWidget::RenderFlags{});
                        return image;
                    };
                    menu.setActiveAction(nullptr);
                    const QImage idle = render(menu);
                    const QPoint blank(menu.width() - 6, menu.actionGeometry(first).center().y());
                    check("UI_menu_background_alpha",
                          std::abs(menu.backgroundAlpha() - 0.35f) < 0.001f &&
                              std::abs(idle.pixelColor(blank).alpha() - qRound(0.35 * 255)) <= 1 &&
                              menu.windowOpacity() == 1);
                    const QPoint hover = menu.actionGeometry(first).center();
                    QMouseEvent move(QEvent::MouseMove, hover, menu.mapToGlobal(hover), Qt::NoButton, Qt::NoButton,
                                     Qt::NoModifier);
                    QApplication::sendEvent(&menu, &move);
                    const QImage hot = render(menu);
                    check("UI_menu_hover_accent",
                          menu.activeAction() == first && hot.pixelColor(blank) != idle.pixelColor(blank));
                    QKeyEvent down(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
                    QApplication::sendEvent(&menu, &down);
                    check("UI_menu_keyboard_skips_disabled", menu.activeAction() == sub->menuAction());
                    menu.setActiveAction(disabled);
                    check(
                        "UI_menu_disabled_no_highlight",
                        render(menu).pixelColor(QPoint(menu.width() - 6, menu.actionGeometry(disabled).center().y())) ==
                            idle.pixelColor(QPoint(menu.width() - 6, menu.actionGeometry(disabled).center().y())));
                    bool foreground = false;
                    for (int y = menu.actionGeometry(first).top(); y <= menu.actionGeometry(first).bottom(); ++y)
                        for (int x = 4; x < menu.width() - 20; ++x) {
                            const QColor color = idle.pixelColor(x, y);
                            foreground |= color.alpha() > 240 && color.red() > 150;
                        }
                    check("UI_menu_foreground_opaque", foreground && first->isChecked());
                    bool childAlpha = true;
                    for (SkinMenu *child : {sub, nested}) {
                        child->resize(child->sizeHint());
                        childAlpha &= child->testAttribute(Qt::WA_TranslucentBackground) &&
                                      std::abs(child->backgroundAlpha() - menu.backgroundAlpha()) < 0.001f;
                    }
                    check("UI_menu_multilevel_factory", childAlpha);
                    bool triggered = false;
                    QObject::connect(first, &QAction::triggered, &menu, [&](bool checked) { triggered = !checked; });
                    menu.setActiveAction(first);
                    QKeyEvent enter(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
                    QApplication::sendEvent(&menu, &enter);
                    check("UI_menu_keyboard_trigger_and_check", triggered && !first->isChecked());
                    menu.popup(QPoint(10, 10));
                    menu.setActiveAction(nullptr);
                    GlassStyle::setEnabled(false);
                    check("UI_menu_glass_off_opaque",
                          menu.backgroundAlpha() == 1 && render(menu).pixelColor(blank).alpha() == 255 &&
                              sub->backgroundAlpha() == 1 && nested->backgroundAlpha() == 1);
                    GlassStyle::setEnabled(true);
                    GlassStyle::setTransparency(0.6f);
                    check("UI_menu_open_tracks_glass_change",
                          std::abs(render(menu).pixelColor(blank).alpha() - qRound(0.75 * 255)) <= 1);
                    menu.close();
                    GlassStyle::setTransparency(transparency);
                    GlassStyle::setEnabled(enabled);
                }
                {
                    // 左栏管理列表，右栏仅歌曲操作；不能生成越权或空页无效动作。
                    // 只核对菜单树与动作派发，不 exec：模态菜单会把探针卡在 exec 里。
                    Collections mcol;
                    PlayerController mctl(engine);
                    Track local(QUrl::fromLocalFile(path));
                    local.setTitle("Local");
                    Track missing(QUrl::fromLocalFile(dir.path() + "/missing.flac"));
                    missing.setTitle("Missing");
                    Track radio = Track::fromRadio(QUrl("http://example.com/live"));
                    radio.setTitle("Radio");
                    // 集合层按电台别名还原显示名，排序素材也走真实命名规则。
                    mcol.radios().setAlias(radio.identityKey(), "Radio");
                    mcol.setAllTracks({local, missing, radio});
                    mctl.setTracks(mcol.currentTracks());
                    PlaylistWindow panel(&mctl, &mcol);
                    bool unifiedListMenus = true;
                    auto menuPathsFor = [&](int row) {
                        QMenu menu;
                        panel.m_view->buildContextMenu(menu, row);
                        QStringList rootMenus;
                        for (QAction *action : menu.actions())
                            if (action->menu()) rootMenus << action->text();
                        const QStringList paths = menuPaths(menu);
                        unifiedListMenus &= !rootMenus.contains("列表") && !rootMenus.contains("添加") &&
                                            !rootMenus.contains("加入列表") &&
                                            (row < 0 || paths.contains("从列表移除")) &&
                                            !rootMenus.contains("歌单") &&
                                            std::none_of(paths.cbegin(), paths.cend(), [](const QString &text) {
                                                return text.contains(QStringLiteral("歌单"));
                                            });
                        return paths;
                    };
                    auto sidebarPathsFor = [&](const QString &id) {
                        QMenu menu;
                        panel.buildSidebarMenu(menu, id);
                        const QStringList paths = menuPaths(menu);
                        unifiedListMenus &= std::none_of(paths.cbegin(), paths.cend(), [](const QString &text) {
                            return text.contains(QStringLiteral("歌单"));
                        });
                        return paths;
                    };

                    panel.m_view->selectAt(0, Qt::NoModifier);
                    const QStringList rowLocal = menuPathsFor(0);
                    check("menu_grouped_submenus",
                          rowLocal.contains("在文件管理器中打开目录") &&
                              rowLocal.contains("转换为其他格式…") &&
                              sidebarPathsFor(Collections::kAllViewId).contains("播放模式/顺序播放") &&
                              sidebarPathsFor(Collections::kAllViewId).contains("添加/添加文件…") &&
                              sidebarPathsFor(Collections::kAllViewId).contains("新建列表…") &&
                              sidebarPathsFor(Collections::kAllViewId).contains("从列表移除") &&
                              rowLocal.contains("属性") &&
                              !rowLocal.contains("编辑显示信息…"));
                    check("menu_hides_radio_group_for_local",
                          !rowLocal.contains("电台/修改电台地址…") && !rowLocal.contains("电台/重命名台名…"));

                    // 探不到的文件：不给「转换为其他格式…」（不再用灰项代替隐藏）
                    panel.m_view->selectAt(1, Qt::NoModifier);
                    const QStringList rowMissing = menuPathsFor(1);
                    check("menu_hides_convert_for_missing_file",
                          rowMissing.contains("属性") && !rowMissing.contains("转换为其他格式…"));

                    panel.m_view->selectAt(2, Qt::NoModifier);
                    const QStringList rowRadio = menuPathsFor(2);
                    check("menu_radio_group",
                          rowRadio.contains("电台/修改电台地址…") && rowRadio.contains("电台/重试这个电台") &&
                              rowRadio.contains("电台/重命名台名…") && rowRadio.contains("电台/移入分类/未分类") &&
                              !rowRadio.contains("在文件管理器中打开目录") && rowRadio.contains("编辑显示信息…") &&
                              rowRadio.contains("属性"));
                    check("menu_song_blank_has_no_list_actions", menuPathsFor(-1).isEmpty());
                    panel.m_view->selectAt(0, Qt::NoModifier);
                    panel.m_view->selectAt(2, Qt::ControlModifier);
                    QMenu mixedLocal, mixedRadio;
                    panel.m_view->buildContextMenu(mixedLocal, 0);
                    panel.m_view->buildContextMenu(mixedRadio, 2);
                    QString editedKey, propertyKey;
                    QObject::connect(&panel, &PlaylistWindow::editRequested, &panel,
                                     [&](const Track &track) { editedKey = track.identityKey(); });
                    QObject::connect(&panel, &PlaylistWindow::propertiesRequested, &panel,
                                     [&](const Track &track) { propertyKey = track.identityKey(); });
                    QAction *edit = findMenuAction(mixedRadio, "编辑显示信息…");
                    QAction *properties = findMenuAction(mixedRadio, "属性");
                    if (edit) edit->trigger();
                    if (properties) properties->trigger();
                    check("menu_radio_edit_and_properties_dispatch", !findMenuAction(mixedLocal, "编辑显示信息…") &&
                                                                         editedKey == radio.identityKey() &&
                                                                         propertyKey == radio.identityKey());

                    // CUE 单轨与同源批量都应提供转换，并携带原始分轨身份和边界。
                    const QUrl sheet = QUrl::fromLocalFile(dir.path() + "/menu.cue");
                    Track cueOne = Track::fromCueSegment(local.url(), 1, sheet, 0.04, 0.4);
                    Track cueTwo = Track::fromCueSegment(local.url(), 2, sheet, 0.4, -1);
                    Track archived(Archive::entryUrl(path, "disc/audio.wav"));
                    mcol.setAllTracks({local, cueOne, cueTwo, archived, radio, missing});
                    mctl.setTracks(mcol.currentTracks());
                    panel.m_view->selectAt(1, Qt::NoModifier);
                    check("menu_cue_single_convert", menuPathsFor(1).contains("转换为其他格式…"));
                    panel.m_view->selectAt(2, Qt::ControlModifier);
                    QMenu cueMenu;
                    panel.m_view->buildContextMenu(cueMenu, 1);
                    QList<Track> converted;
                    const auto conversionConnection =
                        QObject::connect(panel.m_view, &PlaylistView::convertRequested, &panel,
                                         [&](const QList<Track> &tracks) { converted = tracks; });
                    QAction *convert = findMenuAction(cueMenu, "转换为其他格式…");
                    if (convert) convert->trigger();
                    check("menu_cue_batch_preserves_identity",
                          converted.size() == 2 && converted[0].identityKey() == cueOne.identityKey() &&
                              converted[1].identityKey() == cueTwo.identityKey() && converted[0].playStart() == 0.04 &&
                              converted[0].playEnd() == 0.4 && converted[1].playEnd() == -1);
                    QObject::disconnect(conversionConnection);
                    panel.m_view->selectAt(0, Qt::ControlModifier);
                    check("menu_cue_and_local_convert", menuPathsFor(1).contains("转换为其他格式…"));
                    bool mixedRejected = true;
                    for (int badRow : {3, 4, 5}) {
                        panel.m_view->selectAt(1, Qt::NoModifier);
                        panel.m_view->selectAt(badRow, Qt::ControlModifier);
                        mixedRejected &= !menuPathsFor(1).contains("转换为其他格式…");
                    }
                    check("menu_cue_mixed_unsupported_rejected", mixedRejected);
                    // 本地、CUE、归档、电台、缺失文件及混合选区均不再提供单曲重定位。
                    bool relocationRemoved = true;
                    for (int row = 0; row < 6; ++row) {
                        panel.m_view->selectAt(row, Qt::NoModifier);
                        relocationRemoved &= !menuPathsFor(row).contains("重新定位文件…");
                    }
                    panel.m_view->selectAllRows();
                    relocationRemoved &= !menuPathsFor(0).contains("重新定位文件…");
                    check("menu_file_relocation_removed",
                          relocationRemoved &&
                              panel.m_view->metaObject()->indexOfSignal("relocateRequested(Track)") < 0 &&
                              panel.metaObject()->indexOfSignal("relocateRequested(Track)") < 0);
                    mcol.setAllTracks({local, missing, radio});
                    mctl.setTracks(mcol.currentTracks());

                    // 媒体库是扫描只读投影：删行/清空都不列
                    mcol.setLibraryKeys({local.identityKey(), radio.identityKey()});
                    mcol.setViewId(Collections::kLibraryViewId);
                    mctl.setTracks(mcol.currentTracks());
                    panel.m_view->selectAt(0, Qt::NoModifier);
                    const QStringList rowLibrary = sidebarPathsFor(Collections::kLibraryViewId);
                    check("menu_hides_readonly_page_actions",
                          !rowLibrary.contains("从列表移除") && !rowLibrary.contains("清空列表") &&
                              !rowLibrary.contains("排序/按标题") && !rowLibrary.contains("重命名列表…") &&
                              !rowLibrary.contains("删除列表"));

                    // 自建列表页：定义级动作只在真有定义可改时出现；空页没有可导出的内容
                    QString mine;
                    mcol.playlists().create("Mine", &mine);
                    mcol.setViewId(mine);
                    mctl.setTracks(mcol.currentTracks());
                    const QStringList blankCustom = sidebarPathsFor(mine);
                    check("menu_playlist_definition_actions",
                          blankCustom.contains("重命名列表…") && blankCustom.contains("删除列表") &&
                              blankCustom.contains("添加/添加文件…") && blankCustom.contains("添加/添加文件夹…") &&
                              !blankCustom.contains("导出为 m3u…"));
                    check("menu_custom_empty_hint_uses_list",
                          Collections::emptyHintFor(mine) ==
                              QStringLiteral("选中歌曲后在左栏右键 → 加入列表，或左栏右键 → 添加 / 导入 m3u"));
                    auto cancelListDialog = [&](const QString &actionText, const QString &title,
                                                const QString &prompt) {
                        QMenu menu;
                        panel.buildSidebarMenu(menu, mine);
                        QAction *chosen = findMenuAction(menu, actionText);
                        if (!chosen) return false;
                        bool matched = false;
                        QTimer input, timeout;
                        input.setSingleShot(true);
                        timeout.setSingleShot(true);
                        QObject::connect(&input, &QTimer::timeout, &panel, [&] {
                            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                            if (!dialog) return;
                            if (auto *entry = qobject_cast<QInputDialog *>(dialog))
                                matched = entry->windowTitle() == title && entry->labelText() == prompt;
                            else if (auto *message = qobject_cast<QMessageBox *>(dialog)) {
                                matched = message->text() == prompt;
#ifdef Q_OS_MACOS
                                // macOS 消息框不显示窗口标题，仍严格核对确认正文。
                                matched &= message->windowTitle().isEmpty();
#else
                                matched &= message->windowTitle() == title;
#endif
                            }
                            dialog->reject();
                        });
                        QObject::connect(&timeout, &QTimer::timeout, &panel, [] {
                            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget()))
                                dialog->reject();
                        });
                        input.start(0);
                        timeout.start(1000);
                        chosen->trigger();
                        return matched;
                    };
                    check("menu_create_list_dialog_label",
                          cancelListDialog("新建列表…", "新建列表", "列表名称") && mcol.playlists().count() == 1);
                    check("menu_rename_list_dialog_label", cancelListDialog("重命名列表…", "重命名列表", "新名称") &&
                                                               mcol.playlists().nameOf(mine) == "Mine");
                    check("menu_delete_list_dialog_label",
                          cancelListDialog("删除列表", "删除列表",
                                           "确定删除列表「Mine」？（只删除此列表，不动文件和其他列表）") &&
                              mcol.playlists().contains(mine));
                    check("menu_blank_page_facts",
                          !blankCustom.contains("下一首播放") && !blankCustom.contains("从列表移除") &&
                              !blankCustom.contains("排序/按标题") && !blankCustom.contains("定位当前曲") &&
                              !blankCustom.contains("清空列表") && blankCustom.contains("添加/添加网络电台…"));

                    mcol.setViewId(Collections::kAllViewId);
                    mctl.setTracks(mcol.currentTracks());
                    panel.m_view->selectAt(0, Qt::NoModifier);
                    const QStringList withCustom = sidebarPathsFor(mine);
                    check("menu_add_to_list_label", withCustom.contains("加入列表/Mine"));
                    panel.refreshGroups();
                    panel.m_view->selectAt(2, Qt::ControlModifier);
                    const auto selection = panel.m_view->scene();
                    int mineRow = -1;
                    for (int row = 0; row < panel.m_groups->count(); ++row)
                        if (panel.m_groups->rowData(row).toString() == mine) mineRow = row;
                    panel.show();
                    const QPoint hit(20, mineRow * 22 + 11);
                    QMouseEvent rightPress(QEvent::MouseButtonPress, hit, panel.m_groups->mapToGlobal(hit),
                                           Qt::RightButton, Qt::RightButton, Qt::NoModifier);
                    QApplication::sendEvent(panel.m_groups, &rightPress);
                    bool sidebarEntry = false;
                    QTimer::singleShot(0, &panel, [&] {
                        if (auto *menu = qobject_cast<QMenu *>(QApplication::activePopupWidget())) {
                            sidebarEntry = findMenuAction(*menu, "重命名列表…") && findMenuAction(*menu, "Mine");
                            menu->close();
                        }
                    });
                    QContextMenuEvent context(QContextMenuEvent::Mouse, hit, panel.m_groups->mapToGlobal(hit));
                    QApplication::sendEvent(panel.m_groups, &context);
                    check("menu_sidebar_real_entry_preserves_source_selection",
                          mineRow >= 0 && sidebarEntry && mcol.viewId() == Collections::kAllViewId &&
                              panel.m_view->scene().selected == selection.selected);
                    QMenu addSelected;
                    panel.buildSidebarMenu(addSelected, mine);
                    QAction *join = findMenuAction(addSelected, "Mine");
                    // 菜单打开后更改选区，加入仍必须使用打开时的稳定身份快照。
                    panel.m_view->selectAt(1, Qt::NoModifier);
                    if (join) join->trigger();
                    if (join) join->trigger();
                    check("menu_sidebar_add_selected_snapshot_dedup",
                          join &&
                              mcol.playlists().keysOf(mine) == QStringList{local.identityKey(), radio.identityKey()} &&
                              mcol.viewId() == Collections::kAllViewId && mctl.tracks().size() == 3);
                    panel.m_view->selectAt(0, Qt::NoModifier);
                    panel.m_view->selectAt(2, Qt::ControlModifier);
                    check("menu_sidebar_hides_already_joined_list", !sidebarPathsFor(mine).contains("加入列表/Mine"));
                    QMenu targetSort;
                    panel.buildSidebarMenu(targetSort, mine);
                    if (QAction *action = findMenuAction(targetSort, "按标题降序")) action->trigger();
                    check("menu_sidebar_sort_noncurrent_target",
                          mcol.tracksOf(mine).first().identityKey() == radio.identityKey() &&
                              mctl.tracks().first().identityKey() == local.identityKey());
                    panel.m_view->selectAt(0, Qt::NoModifier);
                    QMenu targetRemove;
                    panel.buildSidebarMenu(targetRemove, mine);
                    QAction *remove = findMenuAction(targetRemove, "从列表移除");
                    panel.m_view->selectAt(1, Qt::NoModifier);
                    if (remove) remove->trigger();
                    check("menu_sidebar_remove_noncurrent_target_snapshot",
                          remove && mcol.playlists().keysOf(mine) == QStringList{radio.identityKey()} &&
                              mctl.tracks().size() == 3 && mcol.viewId() == Collections::kAllViewId);
                    panel.probeSearch("Local");
                    QMenu targetClear;
                    panel.buildSidebarMenu(targetClear, mine);
                    QAction *clearTarget = findMenuAction(targetClear, "清空列表");
                    if (clearTarget) clearTarget->trigger();
                    check("menu_sidebar_clear_target_keeps_search", clearTarget && mcol.tracksOf(mine).isEmpty() &&
                                                                        panel.m_search->text() == "Local" &&
                                                                        mctl.tracks().size() == 1);
                    panel.clearSearch();
                    bool dispatchedFiles = false, dispatchedFolder = false, dispatchedRadio = false;
                    QObject::connect(&panel, &PlaylistWindow::addRequested, &panel, [&] { dispatchedFiles = true; });
                    QObject::connect(&panel, &PlaylistWindow::addFolderRequested, &panel,
                                     [&] { dispatchedFolder = true; });
                    QObject::connect(&panel, &PlaylistWindow::radioRequested, &panel, [&] { dispatchedRadio = true; });
                    QMenu sidebarBlank;
                    panel.buildSidebarMenu(sidebarBlank, {});
                    for (const QString &text :
                         {QStringLiteral("添加文件…"), QStringLiteral("添加文件夹…"), QStringLiteral("添加网络电台…")})
                        if (QAction *action = findMenuAction(sidebarBlank, text)) action->trigger();
                    check("menu_sidebar_blank_global_add_dispatch", dispatchedFiles && dispatchedFolder &&
                                                                        dispatchedRadio &&
                                                                        !findMenuAction(sidebarBlank, "清空列表") &&
                                                                        !findMenuAction(sidebarBlank, "重命名列表…"));
                    QString category, categoryNote;
                    mcol.radios().createCategory("分类", &category, &categoryNote);
                    const QStringList categoryPaths = sidebarPathsFor(Collections::radioCatViewId(category));
                    const QStringList uncatPaths =
                        sidebarPathsFor(Collections::radioCatViewId(RadioStations::uncategorizedID));
                    check("menu_sidebar_radio_category_permissions",
                          categoryPaths.contains("新建电台分类…") && categoryPaths.contains("重命名分类「分类」…") &&
                              categoryPaths.contains("删除分类「分类」…") && uncatPaths.contains("新建电台分类…") &&
                              !uncatPaths.contains("删除分类「未分类电台」…"));
                    panel.hide();
                    QMenu controls;
                    panel.buildSidebarMenu(controls, Collections::kAllViewId);
                    QAction *random = findMenuAction(controls, "随机播放");
                    QAction *descending = findMenuAction(controls, "按标题降序");
                    if (random) random->trigger();
                    if (descending) descending->trigger();
                    check("menu_merged_mode_sort_dispatch",
                          random && descending && mctl.mode() == PlayMode::Random && mctl.tracks().size() == 3 &&
                              mctl.tracks().first().identityKey() == radio.identityKey() &&
                              mcol.currentTracks().size() == 3 &&
                              mcol.currentTracks().first().identityKey() == radio.identityKey());
                    if (QAction *order = findMenuAction(controls, "顺序播放")) order->trigger();
                    if (QAction *ascending = findMenuAction(controls, "按标题")) ascending->trigger();

                    // 筛选态：清空/排序会连带命中之外的内容，先不列
                    panel.probeSearch("Local");
                    panel.m_view->selectAt(0, Qt::NoModifier);
                    const QStringList filtered = sidebarPathsFor(Collections::kAllViewId);
                    check("menu_hides_page_actions_while_filtering", !filtered.contains("清空列表") &&
                                                                         !filtered.contains("排序/按标题") &&
                                                                         filtered.contains("从列表移除"));
                    panel.clearSearch();
                    check("menu_unified_list_naming", unifiedListMenus);

                    // 菜单中没有收藏或待播入口；清空仍走真实 triggered。
                    QMenu favMenu;
                    panel.m_view->buildContextMenu(favMenu, 0);
                    check("menu_removed_features_absent",
                          !findMenuAction(favMenu, "加入收藏") && !findMenuAction(favMenu, "取消收藏") &&
                              !findMenuAction(favMenu, "下一首播放") && !findMenuAction(favMenu, "稍后播放") &&
                              !findMenuAction(favMenu, "待播队列"));
                    QMenu clearMenu;
                    panel.buildSidebarMenu(clearMenu, Collections::kAllViewId);
                    QAction *clear = findMenuAction(clearMenu, "清空列表");
                    if (clear) clear->trigger();
                    check("menu_clear_list_dispatch", clear != nullptr && mctl.tracks().isEmpty());
                }
                {
                    ScopedTestState radioState;
                    PlayerController radioCtl(engine);
                    MainWindow radioWindow(&radioCtl, engine);
                    const QString key = "http://127.0.0.1:1/custom?station=1";
                    auto fill = [](QDialog &dialog, const QString &address, const QString &title, const QString &artist,
                                   const QString &album) {
                        for (const auto &entry : QList<QPair<QString, QString>>{{"radioAddress", address},
                                                                                {"radioTitle", title},
                                                                                {"radioArtist", artist},
                                                                                {"radioAlbum", album}}) {
                            auto *edit = dialog.findChild<QLineEdit *>(entry.first);
                            if (!edit) {
                                dialog.reject();
                                return false;
                            }
                            if (!edit->isReadOnly()) edit->setText(entry.second);
                        }
                        return true;
                    };
                    const auto initialGeneration = radioWindow.m_importGeneration;
                    const bool cancelled = driveRadioDialog(
                        radioWindow,
                        [&](QDialog &dialog) {
                            fill(dialog, key, "Cancelled", "Artist", "Album");
                            dialog.reject();
                        },
                        [&] { radioWindow.addRadioPrompt(); });
                    check("UI_radio_add_cancel_atomic", cancelled && radioWindow.collections().allTracks().isEmpty() &&
                                                            radioWindow.m_importGeneration == initialGeneration);
                    bool invalidBlocked = false;
                    driveRadioDialog(
                        radioWindow,
                        [&](QDialog &dialog) {
                            if (!fill(dialog, "file:///tmp/not-radio.wav", "Invalid", {}, {})) return;
                            auto *buttons = dialog.findChild<QDialogButtonBox *>();
                            if (buttons) buttons->button(QDialogButtonBox::Ok)->click();
                            auto *error = dialog.findChild<QLabel *>("radioAddressError");
                            invalidBlocked = error && !error->text().isEmpty() && dialog.isVisible();
                            dialog.reject();
                        },
                        [&] { radioWindow.addRadioPrompt(); });
                    check("UI_radio_invalid_address_blocked",
                          invalidBlocked && radioWindow.m_importGeneration == initialGeneration);
                    const bool added = driveRadioDialog(
                        radioWindow,
                        [&](QDialog &dialog) {
                            if (!fill(dialog, key, "  Custom radio  ", "  Artist  ", "  Album  ")) return;
                            if (auto *buttons = dialog.findChild<QDialogButtonBox *>())
                                buttons->button(QDialogButtonBox::Ok)->click();
                        },
                        [&] { radioWindow.addRadioPrompt(); });
                    const bool committed =
                        waitFor([&] { return radioWindow.collections().trackForKey(key).title() == "Custom radio"; });
                    radioCtl.stop();
                    const Track addedTrack = radioWindow.collections().trackForKey(key);
                    check("UI_radio_add_display_info", added && committed && addedTrack.artist() == "Artist" &&
                                                           addedTrack.album() == "Album" &&
                                                           addedTrack.identityKey() == key);
                    bool prefilled = false;
                    const bool edited = driveRadioDialog(
                        radioWindow,
                        [&](QDialog &dialog) {
                            auto *address = dialog.findChild<QLineEdit *>("radioAddress");
                            auto *title = dialog.findChild<QLineEdit *>("radioTitle");
                            auto *artist = dialog.findChild<QLineEdit *>("radioArtist");
                            auto *album = dialog.findChild<QLineEdit *>("radioAlbum");
                            prefilled = address && address->isReadOnly() && address->text() == key && title &&
                                        title->text() == "Custom radio" && artist && artist->text() == "Artist" &&
                                        album && album->text() == "Album";
                            if (!fill(dialog, key, "Updated", "New artist", "New album")) return;
                            if (auto *buttons = dialog.findChild<QDialogButtonBox *>())
                                buttons->button(QDialogButtonBox::Ok)->click();
                        },
                        [&] { radioWindow.editRadioPrompt(addedTrack); });
                    const Track updated = radioWindow.collections().trackForKey(key);
                    check("UI_radio_edit_prefill_and_submit", edited && prefilled && updated.title() == "Updated" &&
                                                                  updated.artist() == "New artist" &&
                                                                  updated.album() == "New album");
                    const auto stored = LibraryStore::load();
                    Collections restored;
                    restored.loadFrom(stored);
                    restored.setAllTracks({Track::fromRadio(QUrl(key))});
                    const Track reloaded = restored.trackForKey(key);
                    check("UI_radio_display_info_persisted", stored.valid && reloaded.title() == "Updated" &&
                                                                 reloaded.artist() == "New artist" &&
                                                                 reloaded.album() == "New album");
                    driveRadioDialog(
                        radioWindow,
                        [&](QDialog &dialog) {
                            fill(dialog, key, "Discarded", "Discarded", "Discarded");
                            dialog.reject();
                        },
                        [&] { radioWindow.editRadioPrompt(updated); });
                    check("UI_radio_edit_cancel_atomic", updated.title() == "Updated" &&
                                                             updated.artist() == "New artist" &&
                                                             updated.album() == "New album");
                    radioWindow.collections().editTrack(key, {}, {}, {});
                    radioWindow.collections().registerTracks({Track::fromRadio(QUrl(key))});
                    const Track fallback = radioWindow.collections().trackForKey(key);
                    check("UI_radio_clear_display_info_fallback",
                          fallback.title() == RadioURL::displayName(QUrl(key)) && fallback.artist().isEmpty() &&
                              fallback.album().isEmpty() &&
                              !radioWindow.collections().radios().hasCustomName(QUrl(key)));
                    Track local(QUrl::fromLocalFile(path));
                    radioWindow.editRadioPrompt(local);
                    check("UI_radio_edit_rejects_local", local.title() == "a");
                }
                {
                    ScopedTestState freshState;
                    MainWindow fresh(&ctl, engine);
                    check("UI_first_start_playlist_lazy_default", !fresh.m_playlist && fresh.m_listVisible);
                    fresh.flushState();
                    check("UI_first_start_save_preserves_list_default", LibraryStore::load().listVisible);
                    fresh.show();
                    QCoreApplication::processEvents();
                    check("UI_first_start_main_and_playlist_visible",
                          fresh.isVisible() && fresh.m_playlist && fresh.m_playlist->isVisible());
                    fresh.setGroupHideBypassTray(true);
                    bool backgroundSaved = true, startupRestored = true;
                    for (int cycle = 0; cycle < 30; ++cycle) {
                        fresh.hideGroupToBackground();
                        fresh.flushState();
                        const auto stored = LibraryStore::load();
                        backgroundSaved &= fresh.isGroupHidden() && !fresh.isVisible() &&
                                           !fresh.m_playlist->isVisible() && stored.valid && stored.listVisible;
                        {
                            MainWindow restored(&ctl, engine);
                            restored.show();
                            QCoreApplication::processEvents();
                            startupRestored &=
                                restored.isVisible() && restored.m_playlist && restored.m_playlist->isVisible();
                        }
                        fresh.restoreGroupFromBackground();
                    }
                    check("UI_background_save_preserves_playlist_intent_30", backgroundSaved);
                    check("UI_restart_after_background_shows_main_and_playlist_30", startupRestored);
                    fresh.togglePlaylistPanel();
                    fresh.flushState();
                    MainWindow reopened(&ctl, engine);
                    reopened.show();
                    check("UI_saved_hidden_playlist_remains_hidden", reopened.isVisible() && !reopened.m_playlist);
                    reopened.setGroupHideBypassTray(true);
                    reopened.hideGroupToBackground();
                    reopened.flushState();
                    check("UI_background_save_preserves_explicit_closed_playlist", !LibraryStore::load().listVisible);
                    reopened.restoreGroupFromBackground();
                    check("UI_background_restore_keeps_explicit_closed_playlist",
                          reopened.isVisible() && !reopened.m_playlist);
                }
                auto hiddenSettings = LibraryStore::load();
                hiddenSettings.listVisible = false;
                check("UI_hidden_playlist_fixture_saved", LibraryStore::save(hiddenSettings));
                MainWindow window(&ctl, engine);
                check("UI_hidden_playlist_startup_lazy", !window.m_playlist);
                window.show();
                QCoreApplication::processEvents();
                check("UI_main_visible", window.isVisible());
                check("UI_borderless", window.windowFlags().testFlag(Qt::FramelessWindowHint));
                check("UI_approved_compact_width", window.width() < 500 && window.minimumWidth() == 420);
                auto *meter = window.findChild<QWidget *>(QStringLiteral("levelMeter"));
                check("UI_level_meter_exists", meter != nullptr);
                if (meter) {
                    const QFont labelFont = meter->font();
                    const QFontMetricsF metrics(labelFont, meter);
                    check("UI_level_labels_smaller_font", labelFont.pointSize() == Fonts::numericTiny.pointSize() - 2 &&
                                                              labelFont.families() == Fonts::numericTiny.families() &&
                                                              labelFont.weight() == Fonts::numericTiny.weight());
                    check("UI_level_labels_fit_unchanged_meter",
                          meter->size() == QSize(72, 40) && metrics.height() <= 16 &&
                              metrics.horizontalAdvance("L") <= 14 && metrics.horizontalAdvance("R") <= 14);
                    QImage actual(meter->size(), QImage::Format_ARGB32_Premultiplied);
                    actual.fill(Qt::transparent);
                    meter->render(&actual, QPoint(), QRegion(), QWidget::RenderFlags{});
                    bool completeLabels = true;
                    const QStringList labels = {"L", "R"};
                    for (int row = 0; row < labels.size(); ++row) {
                        const QRectF rect(0, 3.5 + row * 17, 14, 16);
                        VolumeReadoutReference reference(meter, rect, labels[row], Theme::inkOnGlassSoft,
                                                         Qt::AlignCenter);
                        reference.setFont(labelFont);
                        QImage expected(meter->size(), QImage::Format_ARGB32_Premultiplied);
                        expected.fill(Qt::transparent);
                        reference.render(&expected, QPoint(), QRegion(), QWidget::RenderFlags{});
                        const QImage glyph = expected.copy(rect.toAlignedRect());
                        bool hasInk = false;
                        for (int y = 0; y < glyph.height(); ++y)
                            for (int x = 0; x < glyph.width(); ++x)
                                hasInk |= qAlpha(glyph.pixel(x, y)) > 0;
                        completeLabels &= hasInk && actual.copy(rect.toAlignedRect()) == glyph;
                    }
                    check("UI_level_labels_complete_pixels", completeLabels);
                    const QString report = qEnvironmentVariable("TTPLAYER_PROBE");
                    if (!report.isEmpty()) meter->grab().save(report + "/level-meter-labels.png");
                }
                check("UI_icon", !AppIcon::icon().isNull());
                bool iconMatches = true;
                for (int size : {16, 24, 32, 48, 64, 128, 256})
                    iconMatches &= AppIcon::image(size).convertToFormat(QImage::Format_ARGB32) ==
                                   AppIcon::pixmap(size).toImage().convertToFormat(QImage::Format_ARGB32);
                check("UI_build_icon_matches_window_icon", iconMatches);
                auto *brandIcon = window.findChild<QLabel *>(QStringLiteral("appIcon"));
                const QPixmap expectedBrand = AppIcon::icon().pixmap(QSize(16, 16), window.devicePixelRatioF());
                check("UI_brand_uses_headphone_icon",
                      brandIcon && brandIcon->pixmap().toImage() == expectedBrand.toImage());
                {
                    TrayController tray(&window, &ctl);
                    auto *nativeTray = tray.findChild<QSystemTrayIcon *>();
                    if (tray.available() && nativeTray) {
                        bool trayMatches = true;
                        for (int size : {16, 32, 64})
                            trayMatches &=
                                nativeTray->icon().pixmap(size).toImage() == AppIcon::icon().pixmap(size).toImage();
                        check("UI_tray_uses_headphone_icon", trayMatches);
                    } else {
                        out << "REVIEW_PROBE UI_tray_uses_headphone_icon SKIP requires system tray\n";
                    }
                }
#ifdef Q_OS_WIN
                HICON embeddedIcon = nullptr;
                const std::wstring executable = QCoreApplication::applicationFilePath().toStdWString();
                const UINT extracted = ExtractIconExW(executable.c_str(), 0, nullptr, &embeddedIcon, 1);
                check("UI_exe_embedded_icon", extracted == 1 && embeddedIcon != nullptr);
                if (embeddedIcon) DestroyIcon(embeddedIcon);
#endif
                check("UI_progress_below_transport",
                      window.m_seek->mapTo(&window, QPoint()).y() > window.m_transport->mapTo(&window, QPoint()).y());
                check("UI_volume_transport_same_row", std::abs(window.m_volume->mapTo(&window, QPoint()).y() -
                                                               window.m_transport->mapTo(&window, QPoint()).y()) < 5);
                {
                    auto *volume = window.m_volume;
                    const QRectF readout = volume->readoutRect();
                    const QRectF groove = volume->grooveRect();
                    const double radius = volume->knobDiameter() / 2.0;
                    const QFontMetricsF metrics(Fonts::tiny);
                    const QFontMetricsF numberMetrics(Fonts::numericTiny);
                    check("UI_volume_readout_fits_longest_text",
                          volume->width() == 96 && readout.left() >= 0 && readout.right() <= volume->width() &&
                              readout.width() >= numberMetrics.horizontalAdvance(QStringLiteral("100%")) &&
                              readout.width() >= metrics.horizontalAdvance(QStringLiteral("静音")));
                    check("UI_volume_knob_cannot_cover_readout",
                          groove.left() - radius >= 0.5 && groove.right() + radius + 0.5 < readout.left());
                    const auto textMatches = [&](double value, bool muted) {
                        volume->setValue(value);
                        volume->setMuted(muted);
                        QImage actual(volume->size(), QImage::Format_ARGB32_Premultiplied);
                        actual.fill(Qt::transparent);
                        volume->render(&actual, QPoint(), QRegion(), QWidget::RenderFlags{});
                        const QString text =
                            muted ? QStringLiteral("静音") : QStringLiteral("%1%").arg(int(value * 100));
                        VolumeReadoutReference reference(
                            volume, readout, text, (muted || value == 0) ? Theme::meterRed : Theme::inkOnGlassSoft);
                        reference.setFont(muted ? Fonts::tiny : Fonts::numericTiny);
                        QImage expected(volume->size(), QImage::Format_ARGB32_Premultiplied);
                        expected.fill(Qt::transparent);
                        reference.render(&expected, QPoint(), QRegion(), QWidget::RenderFlags{});
                        const QRect crop = readout.toAlignedRect();
                        const bool matches = actual.copy(crop) == expected.copy(crop) && volume->grooveRect() == groove;
                        if (!matches) {
                            out << "REVIEW_PROBE volume_pixels value=" << value << " muted=" << muted
                                << " widget_dpi=" << volume->logicalDpiX() << '/' << volume->logicalDpiY()
                                << " reference_dpi=" << reference.logicalDpiX() << '/' << reference.logicalDpiY()
                                << " widget_dpr=" << volume->devicePixelRatioF() << '\n';
                            const QString report = qEnvironmentVariable("TTPLAYER_PROBE");
                            if (!report.isEmpty()) {
                                const QString stem =
                                    report + QStringLiteral("/volume-%1-%2").arg(int(value * 100)).arg(muted);
                                actual.save(stem + QStringLiteral("-actual.png"));
                                expected.save(stem + QStringLiteral("-expected.png"));
                            }
                        }
                        return matches;
                    };
                    check("UI_volume_readout_unobscured_pixels", textMatches(0, false) && textMatches(0.99, false) &&
                                                                     textMatches(1, false) && textMatches(1, true));
                    volume->setMuted(false);
                    QMouseEvent atMinimum(QEvent::MouseButtonPress, QPointF(groove.left(), groove.center().y()),
                                          QPointF(groove.left(), groove.center().y()), Qt::LeftButton, Qt::LeftButton,
                                          Qt::NoModifier);
                    QApplication::sendEvent(volume, &atMinimum);
                    const bool reachedMinimum = volume->value() == 0 && window.userVolume() == 0;
                    QMouseEvent atMaximum(QEvent::MouseButtonPress, QPointF(groove.right(), groove.center().y()),
                                          QPointF(groove.right(), groove.center().y()), Qt::LeftButton, Qt::LeftButton,
                                          Qt::NoModifier);
                    QApplication::sendEvent(volume, &atMaximum);
                    check("UI_volume_drag_reaches_endpoints",
                          reachedMinimum && volume->value() == 1 && window.userVolume() == 1);
                    const QString report = qEnvironmentVariable("TTPLAYER_PROBE");
                    if (!report.isEmpty()) volume->grab().save(report + QStringLiteral("/volume-100.png"));
                    window.setUserVolume(0.8);
                }
                window.toggleEqPanel();
                check("UI_EQ_visible", window.m_eqWindow && window.m_eqWindow->isVisible());
                auto *eq = window.m_eqWindow;
                check("UI_EQ_gain_uses_numeric_font",
                      std::all_of(eq->m_gainLabels.begin(), eq->m_gainLabels.end(),
                                  [](const QLabel *label) { return label && label->font() == Fonts::numericTiny; }));
                eq->m_preamp->setValue(6);
                engine->setEQPreamp(6);
                eq->m_faders[3]->setGain(4.5);
                eq->applyGains();
                check("UI_EQ_backend_gain", engine->eqGains()[3] == 4.5);
                eq->m_reset->click();
                check("UI_EQ_reset_preamp", engine->eqPreamp() == 0 && engine->eqGains()[3] == 0);
                window.setUserVolume(0.3);
                window.toggleMute();
                eq->syncFromEngine();
                check("UI_muted_EQ_reads_output_volume", eq->m_volume->value() == 0 && window.userMuted());
                eq->volumeRequested(0.6);
                check("UI_EQ_volume_routes_main", window.userVolume() == 0.6 && !window.userMuted());
                if (!window.m_playlist || !window.m_playlist->isVisible()) window.m_list->click();
                check("UI_hidden_playlist_opens_from_main", window.m_playlist && window.m_playlist->isVisible());
                if (!window.m_playlist) return failed;
                window.m_playlist->focusSearch();
                window.m_playlist->m_search->setFocus();
                QKeyEvent f4(QEvent::KeyPress, Qt::Key_F4, Qt::NoModifier);
                QApplication::sendEvent(window.m_playlist->m_search, &f4);
                check("UI_Fkey_works_in_search", ctl.mode() == PlayMode::Random);
                const bool muted = window.userMuted();
                QKeyEvent typed(QEvent::KeyPress, Qt::Key_M, Qt::NoModifier, "m");
                auto *editor = window.m_playlist->m_search->findChild<QLineEdit *>();
                const QString previousText = editor->text();
                QApplication::sendEvent(editor, &typed);
                check("UI_typing_does_not_mute", window.userMuted() == muted && editor->text() != previousText);
                window.toggleLyricPanel();
                check("UI_lyric_visible", window.m_lyricWindow->isVisible());
#ifdef Q_OS_WIN
                window.toggleCoverPanel();
                const QList<QWidget *> windowsPanels{window.m_playlist, eq, window.m_lyricWindow, window.m_coverWindow};
                check("UI_windows_owned_tool_panels",
                      window.windowType() == Qt::Window &&
                          std::all_of(windowsPanels.begin(), windowsPanels.end(), [&window](QWidget *sub) {
                              return sub->isWindow() && sub->windowType() == Qt::Tool && sub->parentWidget() == &window;
                          }));
                if (QGuiApplication::platformName() == QStringLiteral("windows")) {
                    check("UI_windows_resolved_font",
                          QFontInfo(QApplication::font()).family() == QStringLiteral("Microsoft YaHei UI"));
                    check("UI_windows_resolved_numeric_font",
                          QFontInfo(Fonts::numericSmall).family() == QStringLiteral("Segoe UI") &&
                              QFontInfo(Fonts::numericTiny).family() == QStringLiteral("Segoe UI"));
                    QCoreApplication::processEvents();
                    const auto owned = [&] {
                        return std::all_of(windowsPanels.begin(), windowsPanels.end(),
                                           [&window](QWidget *sub) { return ownedToolWindow(sub, &window); });
                    };
                    check("UI_windows_native_single_taskbar", owned() && nativeTaskbarWindowCount() == 1);
                    {
                        QList<QWidget *> group = windowsPanels;
                        group.prepend(&window);
                        PinSurfaceMonitor surface(group);
                        check("UI_windows_pin_layered_baseline", surface.unchanged(false));
                        window.applyPinTop(true);
                        const bool immediatePin = surface.unchanged(true);
                        QCoreApplication::processEvents();
                        check("UI_windows_pin_preserves_layered_surface", immediatePin && surface.unchanged(true));
                        check("UI_windows_pin_preserves_taskbar", owned() && nativeTaskbarWindowCount() == 1);
                        window.applyPinTop(false);
                        const bool immediateUnpin = surface.unchanged(false);
                        QCoreApplication::processEvents();
                        check("UI_windows_unpin_preserves_layered_surface", immediateUnpin && surface.unchanged(false));
                        check("UI_windows_unpin_preserves_taskbar", owned() && nativeTaskbarWindowCount() == 1);
                        bool stable = true;
                        for (int cycle = 0; cycle < 30; ++cycle) {
                            for (bool pinned : {true, false}) {
                                window.applyPinTop(pinned);
                                stable &= surface.unchanged(pinned);
                                window.applyPinTop(pinned); // 同态重复请求也不能重建或重写透明样式。
                                QCoreApplication::processEvents();
                                stable &= surface.unchanged(pinned) && owned() && nativeTaskbarWindowCount() == 1 &&
                                          window.probeGroupPinned() == (pinned ? 5 : 0);
                            }
                        }
                        check("UI_windows_pin_toggle_30_preserves_surfaces", stable);
                    }
                    window.applyPinTop(true);
                    {
                        SkinWindow late(QStringLiteral("置顶继承探针"), SkinWindow::TitleButtons::Close, &window);
                        window.setWindowPinTop(&late, true);
                        const WId hwnd = late.internalWinId();
                        late.show();
                        QCoreApplication::processEvents();
                        check("UI_windows_pin_first_show_inherits",
                              hwnd != 0 && late.internalWinId() == hwnd && ownedToolWindow(&late, &window) &&
                                  (GetWindowLongPtrW(reinterpret_cast<HWND>(hwnd), GWL_EXSTYLE) & WS_EX_TOPMOST) != 0 &&
                                  !late.windowHandle()->flags().testFlag(Qt::WindowStaysOnTopHint));
                    }
                    eq->close();
                    window.toggleEqPanel();
                    QCoreApplication::processEvents();
                    check("UI_windows_reopen_preserves_taskbar", owned() && nativeTaskbarWindowCount() == 1);
                    check("UI_windows_pin_reopen_inherits", window.probeGroupPinned() == 5);
                    window.m_coverWindow->close();
                    window.applyPinTop(false);
                    window.toggleCoverPanel();
                    QCoreApplication::processEvents();
                    check("UI_windows_unpin_hidden_panel_reopen",
                          window.probeGroupPinned() == 0 && owned() && nativeTaskbarWindowCount() == 1);
                    window.applyPinTop(true);
                    window.showMinimized();
                    QCoreApplication::processEvents();
                    check("UI_windows_minimize_hides_panels",
                          std::none_of(windowsPanels.begin(), windowsPanels.end(), [](QWidget *sub) {
                              return IsWindowVisible(reinterpret_cast<HWND>(sub->winId())) != FALSE;
                          }));
                    window.showNormal();
                    QCoreApplication::processEvents();
                    check("UI_windows_restore_panels",
                          owned() && nativeTaskbarWindowCount() == 1 &&
                              std::all_of(windowsPanels.begin(), windowsPanels.end(), [](QWidget *sub) {
                                  return IsWindowVisible(reinterpret_cast<HWND>(sub->winId())) != FALSE;
                              }));
                    check("UI_windows_pin_minimize_restore", window.probeGroupPinned() == 5);
                    window.m_groupHideBypassTray = true;
                    if (auto *button = window.findChild<TTButton *>("mainMinimize")) button->click();
                    QCoreApplication::processEvents();
                    check("UI_windows_panel_minimize_group",
                          window.probeGroupVisible() == 0 && nativeTaskbarWindowCount() == 0);
                    window.restoreGroupFromBackground();
                    QCoreApplication::processEvents();
                    check("UI_windows_panel_minimize_restore",
                          window.probeGroupVisible() == 5 && owned() && nativeTaskbarWindowCount() == 1);
                    check("UI_windows_pin_background_restore", window.probeGroupPinned() == 5);
                    window.hideGroupToBackground();
                    window.applyPinTop(false);
                    window.restoreGroupFromBackground();
                    QCoreApplication::processEvents();
                    check("UI_windows_unpin_while_hidden_restore", window.probeGroupVisible() == 5 &&
                                                                       window.probeGroupPinned() == 0 && owned() &&
                                                                       nativeTaskbarWindowCount() == 1);
                } else {
                    out << "REVIEW_PROBE UI_windows_native_taskbar SKIP requires windows platform plugin\n";
                }
#endif
                for (SkinWindow *sub : QList<SkinWindow *>{window.m_playlist, eq, window.m_lyricWindow}) {
                    check("UI_panel_accepts_drop", sub->acceptDrops());
                    bool received = false;
                    QObject::connect(sub, &SkinWindow::filesDropped, sub,
                                     [&received](const QStringList &paths) { received = !paths.isEmpty(); });
                    QMimeData mime;
                    mime.setUrls({QUrl::fromLocalFile(path)});
                    QDragEnterEvent enter(QPoint(15, 15), Qt::CopyAction, &mime, Qt::LeftButton, Qt::NoModifier);
                    QApplication::sendEvent(sub, &enter);
                    QDropEvent drop(QPointF(15, 15), Qt::CopyAction, &mime, Qt::LeftButton, Qt::NoModifier);
                    QApplication::sendEvent(sub, &drop);
                    check("UI_panel_drop_import_contract", enter.isAccepted() && drop.isAccepted() && received);
                    sub->disconnect(sub);
                }
                GlassStyle::setTransparency(0.2f);
                check("UI_approved_uniform_glass", std::abs(GlassStyle::bodyAlpha() - 0.2f) < 0.001 &&
                                                       GlassStyle::wellAlpha() == GlassStyle::bodyAlpha() &&
                                                       GlassStyle::buttonAlpha() == GlassStyle::bodyAlpha());
                {
                    bool noControls = true;
                    for (SkinWindow *sub : QList<SkinWindow *>{window.m_playlist, eq, window.m_lyricWindow})
                        noControls &=
                            !sub->findChild<TTButton *>("panelMinimize") && !sub->findChild<TTButton *>("panelClose");
                    check("UI_three_panels_no_title_controls", noControls);
                    window.m_groupHideBypassTray = true;
                    bool cycles = true;
                    for (int cycle = 0; cycle < 30; ++cycle) {
                        window.m_list->click();
                        cycles &=
                            !window.m_playlist->isVisible() && eq->isVisible() && window.m_lyricWindow->isVisible();
                        if (auto *button = window.findChild<TTButton *>("mainMinimize")) button->click();
                        cycles &= window.isGroupHidden() && !eq->isVisible() && !window.m_lyricWindow->isVisible();
                        window.restoreGroupFromBackground();
                        cycles &=
                            !window.m_playlist->isVisible() && eq->isVisible() && window.m_lyricWindow->isVisible();
                        window.m_list->click();
                        window.m_eq->click();
                        cycles &= window.m_playlist->isVisible() && !eq->isVisible();
                        window.m_eq->click();
                        window.m_lyric->click();
                        cycles &= !window.m_lyricWindow->isVisible();
                        window.m_lyric->click();
                    }
                    check("UI_main_controls_group_visibility_30", cycles);
                    // 三个指定辅助窗跟随 GlassStyle，转换保持不透明，原窗控配置不变。
                    check("UI_main_panels_follow_glass", window.m_playlist->glassTransparencyFollows() &&
                                                             eq->glassTransparencyFollows() &&
                                                             window.m_lyricWindow->glassTransparencyFollows());
                    CoverWindow cover(&ctl);
                    PropertyWindow property(ctl.currentTrack(), &ctl);
                    SettingsWindow settings(&window);
                    ConvertWindow conversion({a}, &window);
                    check("UI_aux_title_controls_unchanged", cover.findChild<TTButton *>("panelMinimize") &&
                                                                 cover.findChild<TTButton *>("panelClose") &&
                                                                 !property.findChild<TTButton *>("panelMinimize") &&
                                                                 property.findChild<TTButton *>("panelClose") &&
                                                                 !settings.findChild<TTButton *>("panelMinimize") &&
                                                                 settings.findChild<TTButton *>("panelClose") &&
                                                                 !conversion.findChild<TTButton *>("panelMinimize") &&
                                                                 conversion.findChild<TTButton *>("panelClose"));
                    const QList<SkinWindow *> auxiliaries{&cover, &property, &settings};
                    const QStringList names{"cover", "property", "settings"};
                    for (int i = 0; i < auxiliaries.size(); ++i) {
                        auto *aux = auxiliaries[i];
                        ShellPaintObserver observer;
                        aux->installEventFilter(&observer);
                        aux->show();
                        QCoreApplication::processEvents();
                        GlassStyle::setEnabled(true);
                        GlassStyle::setTransparency(0.31f);
                        QCoreApplication::processEvents();
                        const int before = observer.paints;
                        GlassStyle::setTransparency(0.63f);
                        QCoreApplication::processEvents();
                        QCoreApplication::processEvents();
                        check(("UI_" + names[i] + "_glass_live_repaint").toUtf8().constData(),
                              aux->glassTransparencyFollows() && std::abs(aux->shellAlpha() - 0.63f) < 0.001f &&
                                  observer.paints > before && aux->windowOpacity() == 1.0);
                        const QImage transparent = aux->grab().toImage();
                        const QPoint sample(transparent.width() / 2,
                                            transparent.height() - int(3 * transparent.devicePixelRatio()));
                        const int alpha = qAlpha(transparent.pixel(sample));
                        GlassStyle::setEnabled(false);
                        QCoreApplication::processEvents();
                        const QImage opaque = aux->grab().toImage();
                        check(("UI_" + names[i] + "_glass_disabled_opaque").toUtf8().constData(),
                              aux->shellAlpha() == 1.0f && alpha > 0 && alpha < 255 &&
                                  qAlpha(opaque.pixel(sample)) == 255);
                        aux->hide();
                    }
                    check("UI_conversion_remains_opaque",
                          !conversion.glassTransparencyFollows() && conversion.shellAlpha() == 1.0f);
                    GlassStyle::setEnabled(true);
                    GlassStyle::setTransparency(0.2f);
                    check("UI_main_panel_glass_alpha", std::abs(eq->shellAlpha() - GlassStyle::glassAlpha()) < 0.001f);
                }
                {
                    // 真实打开入口：设置按钮直达、列表属性信号与封面按钮均走统一流程。
                    const QRect originalFrame = window.geometry();
                    const QRect available = window.screen()->availableGeometry();
                    QList<QPointer<QWidget>> visiblePanels;
                    for (const auto &member : window.groupWindows()) {
                        if (member && member != &window && member->isVisible()) {
                            visiblePanels.append(member);
                            member->hide();
                        }
                    }
                    window.move(available.topLeft());
                    ctl.queue().begin({a}, 0);
                    auto *settingsButton = window.findChild<TTButton *>(QStringLiteral("mainSettings"));
                    const int propertyCount = window.findChildren<PropertyWindow *>().size();
                    if (settingsButton) settingsButton->click();
                    check("UI_settings_button_direct_nonmodal",
                          settingsButton && settingsButton->toolTip() == QStringLiteral("设置…") &&
                              window.m_settingsWindow && window.m_settingsWindow->isVisible() &&
                              window.m_settingsWindow->windowModality() == Qt::NonModal &&
                              QApplication::activeModalWidget() == nullptr &&
                              QApplication::activePopupWidget() == nullptr &&
                              window.findChildren<PropertyWindow *>().size() == propertyCount);
                    QPointer<SettingsWindow> settings = window.m_settingsWindow;
                    if (settings) {
                        check("UI_settings_first_show_avoids_main",
                              available.contains(settings->frameGeometry()) &&
                                  !settings->frameGeometry().intersects(window.frameGeometry()));
                        settings->move(window.pos() + QPoint(500, 320));
                        QEventLoop loop;
                        QTimer::singleShot(110, &loop, &QEventLoop::quit);
                        loop.exec();
                        const QPoint position = settings->pos();
                        if (settingsButton) settingsButton->click();
                        check("UI_settings_reuses_instance_position",
                              window.m_settingsWindow == settings && settings->pos() == position);
                        auto *mode = settings->findChild<SkinComboBox *>("settingsPlayMode");
                        ctl.setMode(PlayMode::SingleLoop);
                        check("UI_settings_external_mode_sync",
                              mode && mode->itemData(mode->currentIndex()).toInt() == int(PlayMode::SingleLoop));
                    }
                    const auto before = window.findChildren<PropertyWindow *>();
                    window.m_playlist->propertiesRequested(a);
                    window.m_playlist->propertiesRequested(b);
                    auto properties = window.findChildren<PropertyWindow *>();
                    check("UI_playlist_properties_multi_instance",
                          properties.size() == before.size() + 2 && properties[0] != properties[1] &&
                              properties[0]->parentWidget() == &window && properties[1]->parentWidget() == &window);
                    for (auto *property : properties)
                        property->close();
                    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
                    check("UI_properties_close_destroy", window.findChildren<PropertyWindow *>().isEmpty());
                    if (!window.m_coverWindow || !window.m_coverWindow->isVisible()) window.toggleCoverPanel();
                    auto *cover = window.m_coverWindow;
                    cover->move(window.pos() + QPoint(510, 450));
                    QEventLoop loop;
                    QTimer::singleShot(110, &loop, &QEventLoop::quit);
                    loop.exec();
                    const QPoint coverPosition = cover->pos();
                    cover->close();
                    window.toggleCoverPanel();
                    check("UI_cover_reopen_keeps_user_position",
                          cover == window.m_coverWindow && cover->isVisible() && cover->pos() == coverPosition);
                    const QString frames = window.m_dock->panelFramesString();
                    check("UI_aux_frames_not_persisted", !frames.contains("settings") && !frames.contains("cover") &&
                                                             !frames.contains("property") &&
                                                             frames.split(';').size() == 3);
                    if (settings) settings->close();
                    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
                    check("UI_settings_close_destroys_unique_instance",
                          settings.isNull() && window.m_settingsWindow.isNull());
                    window.setGeometry(originalFrame);
                    for (const auto &member : visiblePanels)
                        if (member) member->show();
#ifdef Q_OS_WIN
                    if (QGuiApplication::platformName() == QStringLiteral("windows")) {
                        window.openSettings();
                        window.openProperties(a);
                        QCoreApplication::processEvents();
                        const auto group = window.groupWindows();
                        QList<QWidget *> visible;
                        bool owned = true;
                        for (const auto &member : group) {
                            if (!member || !member->isVisible()) continue;
                            visible.append(member);
                            if (member != &window) owned &= ownedToolWindow(member, &window);
                        }
                        check("UI_windows_aux_owned_single_taskbar", owned && nativeTaskbarWindowCount() == 1);
                        PinSurfaceMonitor monitor(visible);
                        bool stable = true;
                        for (int cycle = 0; cycle < 30; ++cycle) {
                            for (bool pin : {true, false}) {
                                window.applyPinTop(pin);
                                QCoreApplication::processEvents();
                                stable &=
                                    monitor.unchanged(pin) && window.probeGroupPinned() == (pin ? visible.size() : 0);
                            }
                        }
                        check("UI_windows_aux_pin_30_preserves_surfaces", stable);
                    }
#endif
                }
                check("UI_spectrum_24fps", window.m_spectrum->m_timer.interval() == 1000 / 24);
                {
                    SpectrumView view(engine);
                    view.resize(231, 40);
                    engine->setSpectrumEnabled(true);
                    auto before = view.grab().toImage();
                    bool covered = true, changed = false;
                    for (int frame = 0; frame < 30; ++frame) {
                        float pcm[2048];
                        for (int i = 0; i < 2048; ++i)
                            pcm[i] = float(std::sin(i * (0.03 + frame * 0.006)) * (1 - frame / 30.0));
                        engine->m_spectrum.feed(pcm, pcm, 2048);
                        const QRect damage = view.advanceFrame();
                        const auto after = view.grab().toImage();
                        for (int y = 0; y < after.height(); ++y) {
                            for (int x = 0; x < after.width(); ++x) {
                                if (after.pixel(x, y) == before.pixel(x, y)) continue;
                                changed = true;
                                covered &= damage.contains(int(x / after.devicePixelRatio()),
                                                           int(y / after.devicePixelRatio()));
                            }
                        }
                        before = after;
                    }
                    check("spectrum_damage_covers_every_changed_pixel", changed && covered);
                    engine->setSpectrumEnabled(false);
                    for (int i = 0; i < 60; ++i)
                        view.advanceFrame();
                    check("settled_spectrum_needs_no_repaint", view.advanceFrame().isEmpty());
                }
                window.hide();
                QCoreApplication::processEvents();
                check("UI_hide_stops_analyzer", !engine->m_spectrum.enabled());
                check("UI_hide_stops_timer", !window.m_spectrum->m_timer.isActive());
            }
        } else if (suite == "PERF") {
            // 夹具构造（10000 个 QUrl 解析 + Track 拷贝 + 列表增长）不计入搜索预算：
            // 它可以过秒级（MSVC Debug 实测约 12s），但和搜索路径无关。被测量仍是
            // 10000 首的首次索引构建与匹配，两个阶段分开打印便于核对口径。
            QElapsedTimer timer;
            timer.start();
            Collections col;
            QList<Track> many;
            many.reserve(10000);
            for (int i = 0; i < 10000; ++i) {
                Track track(QUrl::fromLocalFile(QStringLiteral("/music/%1.flac").arg(i)));
                track.setTitle(QStringLiteral("Track %1").arg(i));
                many << track;
            }
            col.setAllTracks(many);
            const qint64 buildMs = timer.elapsed();
            timer.restart();
            auto result = col.search(TrackFilter("Track 9999"));
            const qint64 searchMs = timer.elapsed();
            check("large_search_correct", result.hits.size() == 1);
            check("large_search_budget", searchMs < 6000);
            out << "PERF search_10000_ms=" << searchMs << '\n';
            out << "PERF search_10000_build_ms=" << buildMs << '\n';
#ifdef __APPLE__
            mach_task_basic_info info{};
            mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
            const bool measured = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                            reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS;
            check("resident_memory_measured", measured);
            check("resident_memory_budget", measured && info.resident_size < 190ULL * 1024 * 1024);
            out << "PERF resident_bytes=" << info.resident_size << '\n';
#endif
        } else if (suite == "SYSTEM") {
            RadioQuality quality;
            quality.startSession(1);
            quality.noteUnderrun(1);
            quality.noteUnderrun(2);
            check("radio_quality_one_outage", quality.totalUnderruns == 1 && quality.starved);
            quality.noteBuffer(0.3, 3);
            quality.noteUnderrun(4);
            quality.noteReconnect(5);
            check("radio_quality_recovered_outage", quality.totalUnderruns == 2 && quality.totalReconnects == 1);
            check("radio_quality_30s_window", quality.windowUnderruns(31) == 1 && quality.windowReconnects(35) == 0);
            check("radio_quality_totals_survive_window",
                  quality.totalUnderruns == 2 && quality.summary(35).contains("30"));
            quality.startSession(2);
            check("radio_quality_new_session",
                  quality.totalUnderruns == 0 && quality.totalReconnects == 0 && !quality.starved);
            check("state_isolated", LibraryStore::stateFilePath().startsWith(dir.path()));
            LibraryStore::Loaded s;
            s.volume = 0.4;
            check("atomic_save", LibraryStore::save(s));
            check("state_roundtrip", LibraryStore::load().volume == 0.4);
            check("db_created", QFileInfo::exists(LibraryStore::dbFilePath()));
            // schema 世代：表名一律带 v1_ 前缀，user_version 与之一致
            const QString dbPath = LibraryStore::dbFilePath();
            struct SchemaInfo {
                QStringList tables;
                int version = -1;
            };
            auto schemaInfo = [](const QString &file) {
                SchemaInfo info;
                QSqlDatabase probe =
                    QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("schema-probe"));
                probe.setDatabaseName(file);
                if (probe.open()) {
                    QSqlQuery q(probe);
                    if (q.exec(QStringLiteral("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")))
                        while (q.next())
                            info.tables << q.value(0).toString();
                    if (q.exec(QStringLiteral("PRAGMA user_version")) && q.next()) info.version = q.value(0).toInt();
                    probe.close();
                }
                probe = QSqlDatabase();
                QSqlDatabase::removeDatabase(QStringLiteral("schema-probe"));
                return info;
            };
            const SchemaInfo v1Schema = schemaInfo(dbPath);
            bool onlyVersioned = !v1Schema.tables.isEmpty();
            for (const QString &table : v1Schema.tables)
                onlyVersioned = onlyVersioned && table.startsWith(QLatin1String("v1_"));
            check("schema_user_version", v1Schema.version == LibraryStore::kSchemaVersion);
            check("schema_tables_versioned", v1Schema.tables.size() == 14 && onlyVersioned);

            // 表名版本化之前建的库（user_version=1 但表名裸写）：打开时就地改名，数据不动
            LibraryStore::closeDatabase();
            QFile::remove(dbPath);
            QFile::remove(dbPath + QStringLiteral("-wal"));
            QFile::remove(dbPath + QStringLiteral("-shm"));
            {
                QSqlDatabase legacy =
                    QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("legacy-probe"));
                legacy.setDatabaseName(dbPath);
                check("legacy_db_built", legacy.open());
                QSqlQuery q(legacy);
                check("legacy_db_schema",
                      q.exec(QStringLiteral("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")) &&
                          q.exec(QStringLiteral("INSERT INTO settings (key, value) VALUES ('volume', '0.25')")) &&
                          q.exec(QStringLiteral("PRAGMA user_version = 1")));
                legacy.close();
                legacy = QSqlDatabase();
                QSqlDatabase::removeDatabase(QStringLiteral("legacy-probe"));
            }
            check("legacy_tables_adopted", LibraryStore::load().volume == 0.25);
            const SchemaInfo adopted = schemaInfo(dbPath);
            check("legacy_tables_renamed", adopted.tables.contains(QStringLiteral("v1_settings")) &&
                                               !adopted.tables.contains(QStringLiteral("settings")));
            check("legacy_version_kept", adopted.version == LibraryStore::kSchemaVersion);
            // 旧 JSON 一次性迁移：先关连接删库，再摆两份旧档——下次 load 应整份导入并改名留底
            LibraryStore::closeDatabase();
            QFile::remove(LibraryStore::dbFilePath());
            QFile::remove(LibraryStore::dbFilePath() + QStringLiteral("-wal"));
            QFile::remove(LibraryStore::dbFilePath() + QStringLiteral("-shm"));
            QFile state(LibraryStore::stateFilePath());
            state.open(QIODevice::WriteOnly);
            state.write(
                "{\"trackPaths\":[],\"libraryKeys\":[\"/offline/song.flac\"],\"eqPreGain\":-3,\"eqGains\":[1,2],\"trackEdits\":{\"/offline/song.flac\":{\"title\":\"Edited\"}},\"foreign\":123}");
            state.close();
            QFile resume(dir.path() + "/resume.json");
            resume.open(QIODevice::WriteOnly);
            resume.write(
                "{\"queueKeys\":[\"/offline/song.flac\"],\"queueExplicit\":[false],\"queueNext\":[],\"queueIndex\":0,\"position\":12,\"wasPlaying\":false}");
            resume.close();
            auto migrated = LibraryStore::load();
            check("migrated_resume_valid", migrated.resumeValid && migrated.resumeQueue.size() == 1 &&
                                               migrated.resumeQueue.first() == "/offline/song.flac" &&
                                               migrated.resumePosition == 12);
            check("migrated_fields_consumed", migrated.libraryKeys.size() == 1 && migrated.eqPreGain == -3);
            Collections restored;
            restored.loadFrom(migrated);
            restored.setAllTracks({Collections::resolveToken("/offline/song.flac")});
            check("migrated_track_edit_applied", restored.allTracks().first().title() == "Edited");
            check(
                "legacy_json_archived",
                QDir(dir.path()).entryList(QStringList{QStringLiteral("state.json.migrated-*")}, QDir::Files).size() ==
                    1);
            check("foreign_fields_preserved", LibraryStore::legacyUnknownFields().value("foreign").toInt() == 123);
            check("db_roundtrip_after_migration", LibraryStore::save(migrated) && LibraryStore::load().eqPreGain == -3);
            bool jsonCompatible = true, sqliteCompatible = true, sourcesZero = true;
            for (int source : {1, 2})
                for (int cursor : {0, 2, 3, 8})
                    for (bool matching : {false, true}) {
                        const QStringList keys{"/a.flac", "/discard.flac", "/current.flac", "/b.flac", "/later.flac",
                                               "",        "/unknown.flac"};
                        const QList<int> sources{0, 1, source, 0, 2, 0, 9};
                        const QList<int> oldHistory{0, 1, 0, 2, 4, 3, 5, 6, -1, 8};
                        const bool keepCurrent = cursor == 2 && matching;
                        const QString currentKey =
                            matching && cursor >= 0 && cursor < keys.size() ? keys[cursor] : QString();
                        const QStringList expected =
                            keepCurrent ? QStringList{keys[0], keys[2], keys[3]} : QStringList{keys[0], keys[3]};
                        const int newCursor = cursor == 0   ? 0
                                              : cursor == 3 ? (keepCurrent ? 2 : 1)
                                              : keepCurrent ? 1
                                                            : -1;
                        const QList<int> expectedHistory = newCursor < 0 ? QList<int>{}
                                                           : keepCurrent ? QList<int>{0, 0, 1, 2}
                                                                         : QList<int>{0, 0, 1};
                        auto matches = [&](const LibraryStore::Loaded &loaded) {
                            return loaded.resumeQueue == expected && loaded.resumeCursor == newCursor &&
                                   loaded.resumeValid == (newCursor >= 0) &&
                                   loaded.resumeWasPlaying == (newCursor >= 0) &&
                                   loaded.resumeHistoryIndexes == expectedHistory &&
                                   loaded.resumePosition == (newCursor >= 0 ? 12 : 0) && loaded.volume == 0.4 &&
                                   loaded.favoriteKeys == QStringList{keys[0]} &&
                                   loaded.radioAliases.value("http://example.com/live") == "Alias";
                        };
                        {
                            ScopedTestState legacyState;
                            QJsonArray entries, history;
                            for (int i = 0; i < keys.size(); ++i)
                                entries.append(QJsonObject{{"k", keys[i]}, {"s", sources[i]}});
                            for (int index : oldHistory)
                                history.append(index);
                            entries.append(QJsonObject{{"k", "/invalid.flac"}, {"s", "bad"}});
                            history.append("bad");
                            QJsonObject fixture{{"resumeQueue", entries},
                                                {"resumeCursor", cursor},
                                                {"resumeValid", true},
                                                {"resumeTrackKey", currentKey},
                                                {"resumePosition", 12},
                                                {"resumeWasPlaying", true},
                                                {"resumeHistoryIndexes", history},
                                                {"volume", 0.4},
                                                {"favoriteKeys", QJsonArray{keys[0]}},
                                                {"radioAliases", QJsonObject{{"http://example.com/live", "Alias"}}}};
                            QFile legacy(LibraryStore::stateFilePath());
                            const bool written =
                                legacy.open(QIODevice::WriteOnly) && legacy.write(QJsonDocument(fixture).toJson()) > 0;
                            legacy.close();
                            const auto loaded = LibraryStore::load();
                            jsonCompatible &= written && matches(loaded);
                        }
                        {
                            ScopedTestState legacyState;
                            LibraryStore::Loaded seed;
                            seed.resumeQueue = keys;
                            seed.resumeCursor = cursor;
                            seed.resumeValid = true;
                            seed.resumeTrackKey = currentKey;
                            seed.resumeWasPlaying = true;
                            seed.resumePosition = 12;
                            seed.resumeHistoryIndexes = oldHistory;
                            seed.volume = 0.4;
                            seed.favoriteKeys = {keys[0]};
                            seed.radioAliases.insert("http://example.com/live", "Alias");
                            sqliteCompatible &= LibraryStore::save(seed);
                            LibraryStore::closeDatabase();
                            const QString name = "resume-compat-probe";
                            {
                                QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", name);
                                db.setDatabaseName(LibraryStore::dbFilePath());
                                sqliteCompatible &= db.open();
                                {
                                    QSqlQuery query(db);
                                    query.prepare("UPDATE v1_resume_queue SET source=? WHERE position=?");
                                    for (int i = 0; i < sources.size(); ++i) {
                                        query.bindValue(0, sources[i]);
                                        query.bindValue(1, i);
                                        sqliteCompatible &= query.exec();
                                    }
                                    sqliteCompatible &=
                                        query.exec("INSERT INTO v1_resume_queue VALUES (7, '/invalid.flac', 'bad')") &&
                                        query.exec("INSERT INTO v1_resume_history VALUES (10, 'bad')");
                                }
                                db.close();
                            }
                            QSqlDatabase::removeDatabase(name);
                            const auto loaded = LibraryStore::load();
                            sqliteCompatible &= matches(loaded);
                            sourcesZero &= LibraryStore::save(loaded);
                            LibraryStore::closeDatabase();
                            {
                                QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", name);
                                db.setDatabaseName(LibraryStore::dbFilePath());
                                sourcesZero &= db.open();
                                {
                                    QSqlQuery query(db);
                                    sourcesZero &= query.exec("SELECT COUNT(*) FROM v1_resume_queue WHERE source<>0") &&
                                                   query.next() && query.value(0).toInt() == 0;
                                }
                                db.close();
                            }
                            QSqlDatabase::removeDatabase(name);
                        }
                    }
            check("legacy_JSON_filter_cursor_history_matrix", jsonCompatible);
            check("legacy_SQLite_filter_cursor_history_matrix", sqliteCompatible);
            check("new_SQLite_scene_sources_always_zero", sourcesZero);
            {
                ScopedTestState legacyState;
                QFile legacy(LibraryStore::stateFilePath());
                legacy.open(QIODevice::WriteOnly);
                legacy.write(
                    "{\"resumeValid\":true,\"resumeQueue\":[{\"k\":\"/pending.flac\",\"s\":1}],\"resumeCursor\":0,\"resumeWasPlaying\":true}");
                legacy.close();
                const auto loaded = LibraryStore::load();
                check("legacy_pending_only_no_current_discarded",
                      loaded.resumeQueue.isEmpty() && !loaded.resumeValid && !loaded.resumeWasPlaying);
            }
        }
        return failed;
    }
    int edges() {
        QTemporaryDir dir;
        qputenv("TTPLAYER_QT_STATE", (dir.path() + "/state.json").toUtf8());
        const QByteArray wav = wave();
        const QString path = dir.path() + "/ramp.wav";
        QFile file(path);
        file.open(QIODevice::WriteOnly);
        file.write(wav);
        file.close();
        auto engine = AudioEngine::create();
        engine->stopPump();
        engine->m_silentOutput = false;
        int stale = 0, tail = 0, end = 0;
        for (int n = 0; n < 30; ++n) {
            engine->m_decoder = std::shared_ptr<Decoder>(Decoder::openFile(path));
            engine->m_playing = true;
            engine->m_eos = true;
            engine->m_finishPending = false;
            engine->ringClear();
            int called = 0;
            engine->onFinished = [&] { ++called; };
            std::vector<float> buf(16384, 123);
            engine->callback(buf.data(), 8192);
            tail += std::all_of(buf.begin(), buf.end(), [](float v) { return v == 0; });
            engine->stop();
            QCoreApplication::processEvents();
            stale += called == 0;
            engine->m_decoder = std::shared_ptr<Decoder>(Decoder::openFile(path));
            engine->m_sampleRate = 44100;
            engine->m_endFrame = 44100;
            engine->m_playStart = 0;
            engine->seekSeconds(1);
            end += engine->m_eos && engine->m_readPos == 44100;
        }
        check("EOF_stop_30", stale == 30);
        check("callback_zero_all_30", tail == 30);
        check("CUE_end_seek_30", end == 30);
        engine->onFinished = nullptr;
        engine->stop();
        int seek = 0;
        for (int n = 0; n < 30; ++n) {
            auto src = std::make_shared<GateSource>();
            src->data = wav;
            auto dec = Decoder::openStream(src, "gate");
            if (!dec) {
                check("gate_open", false);
                break;
            }
            dec->seek(0);
            engine->m_decoder = std::shared_ptr<Decoder>(std::move(dec));
            engine->m_readPos = 0;
            engine->m_delivered = 0;
            engine->m_endFrame = INT64_MAX;
            engine->m_playStart = 0;
            engine->m_eos = false;
            engine->m_playing = true;
            engine->ringClear();
            src->armed = true;
            engine->startPump();
            bool blocked;
            {
                std::unique_lock<std::mutex> lk(src->mutex);
                blocked = src->cv.wait_for(lk, std::chrono::seconds(2), [&] { return src->blocked; });
            }
            engine->seekSeconds(20);
            src->cancel();
            bool correct = false;
            for (int k = 0; k < 200; ++k) {
                QThread::msleep(1);
                std::lock_guard<std::mutex> lk(engine->m_mutex);
                if (engine->m_ringCount) {
                    correct = engine->m_ringL[engine->m_ringHead] > 0.3f;
                    break;
                }
            }
            seek += blocked && correct;
            engine->stopPump();
            engine->stop();
        }
        check("seek_inflight_PCM_30", seek == 30);
        {
            // Drive the real output callback with deterministic network arrival times.
            engine->m_liveRadio = true;
            engine->m_sampleRate = 48000;
            engine->resetPlaybackBuffer();
            engine->m_playing = true;
            std::vector<float> pcm(96000, 0.5f), output(std::size_t{96000} * 2);
            const auto baseline = engine->underruns();
            engine->ringPush(pcm.data(), pcm.data(), 48000);
            engine->callback(output.data(), 1024);
            check("radio_preroll_keeps_first_second",
                  engine->m_ringCount == 48000 && output.front() == 0 && engine->underruns() == baseline);
            engine->ringPush(pcm.data(), pcm.data(), 48000);
            engine->callback(output.data(), 95000);
            check("radio_low_reserve_still_playing",
                  output.front() > 0 && engine->m_ringCount == 1000 &&
                      engine->radioBufferState() == AudioEngine::RadioBufferState::Playing);
            engine->callback(output.data(), 1024);
            check("radio_actual_short_read_refills",
                  engine->underruns() == baseline + 1 &&
                      engine->radioBufferState() == AudioEngine::RadioBufferState::Refilling);
            engine->ringPush(pcm.data(), pcm.data(), 48000);
            engine->callback(output.data(), 1024);
            check("radio_refill_holds_trickle", output.front() == 0 && engine->m_ringCount == 48000);
            engine->ringPush(pcm.data(), pcm.data(), 48000);
            engine->callback(output.data(), 96000);
            check("radio_refill_resumes_audio", output.back() > 0 && engine->underruns() == baseline + 1);
            engine->callback(output.data(), 1024);
            engine->ringPush(pcm.data(), pcm.data(), 100);
            engine->m_eos = true;
            engine->callback(output.data(), 1024);
            check("radio_refill_drains_short_eof", output.front() > 0 && output[200] == 0 && engine->m_ringCount == 0);
            engine->stop();
        }
        {
            PlayerController ctl(engine);
            Collections col;
            const Track a(QUrl::fromLocalFile("/a.wav")), b(QUrl::fromLocalFile("/b.wav")),
                c(QUrl::fromLocalFile("/c.wav"));
            PlaylistWindow panel(&ctl, &col);
            int reordered = 0;
            for (int n = 0; n < 30; ++n) {
                col.setAllTracks({a, b, c});
                ctl.setTracks(col.allTracks());
                panel.m_view->selectAt(0, Qt::NoModifier);
                panel.reorderCurrentView(3);
                reordered += col.currentTracks().first().identityKey() == b.identityKey() &&
                             col.currentTracks().last().identityKey() == a.identityKey();
            }
            check("window_reorder_30", reordered == 30);
        }
        const QString token = Archive::entryUrl(dir.path() + "/album.zip", "disc/a.flac").toString();
        const QString m3u = dir.path() + "/list.m3u8";
        PlaylistM3U::exportTracks({Track(QUrl(token))}, m3u);
        PlaylistM3U::Imported imp;
        PlaylistM3U::importFile(m3u, imp);
        check("archive_M3U_identity", imp.keys == QStringList{token});
        check("windows_drive_local", Collections::resolveToken("C:/Music/a.flac").url().isLocalFile());
        check("windows_UNC_local", Collections::resolveToken("\\\\server\\Music\\a.flac").url().isLocalFile());
        engine.reset();
        return failed;
    }
};

int runRegressionSuite(const QString &suite, QTextStream &out) {
    if (!regressionSuites().contains(suite)) return -1;
    RegressionTests tests{out};
    if (suite == "REVIEW") return tests.edges();
    if (suite == "CONVERT") return tests.convert();
    if (suite == "MIDI" || suite == "MODULE") return tests.sequences(suite);
    if (QStringList{"DECODER", "FORMAT", "GAPLESS", "GAIN", "SPECTRUM", "PLAYBACK", "SCENE", "DEVICE", "SLEEP"}
            .contains(suite))
        return tests.audio(suite);
    return tests.models(suite);
}

QStringList regressionSuites() {
    return {"MIDI",     "MODULE", "REVIEW",  "CONVERT", "DECODER", "FORMAT", "GAPLESS", "GAIN",   "SPECTRUM",
            "PLAYBACK", "SCENE",  "DEVICE",  "SLEEP",   "LIBRARY", "IMPORT", "COVER",   "SEARCH", "UI",
            "PERF",     "SYSTEM", "ARCHIVE", "CUE",     "LISTS",   "SHIFT",  "PLAYLIST"};
}