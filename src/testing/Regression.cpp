#include "Regression.h"
#include "audio/AudioEngine.h"
#include "core/Collections.h"
#include "core/PlayerController.h"
#include "decoder/Archive.h"
#include "decoder/FFmpeg.h"
#include "ui/MainWindow.h"
#include "ui/PlaylistWindow.h"
#include "ui/PlaylistView.h"
#include "ui/EqWindow.h"
#include "ui/LyricWindow.h"
#include "ui/CoverWindow.h"
#include "ui/QueueWindow.h"
#include "ui/PropertyWindow.h"
#include "ui/SettingsWindow.h"
#include "ui/SpectrumView.h"
#include "ui/Theme.h"
#include "ui/TransportBar.h"
#include "ui/AppIcon.h"
#include <QKeyEvent>
#include <QLineEdit>
#include <QDropEvent>
#include <QDragEnterEvent>
#include <QMimeData>
#include "models/PlaylistM3U.h"
#include "models/Importer.h"
#include "models/CoverArt.h"
#include "models/Lyric.h"
#include "models/CueSheet.h"
#include "audio/RadioQuality.h"
#include "ui/SkinWidgets.h"
#include <QElapsedTimer>
#include <QApplication>
#include <QDataStream>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <cmath>
#include <chrono>
#ifdef __APPLE__
#include <mach/mach.h>
#include <CoreAudio/CoreAudio.h>

namespace {
// CFStringRef 是引用计数指针，CoreAudio 要的“缓冲区大小”就是一个对象指针
constexpr UInt32 kCfStringRefSize = sizeof(void *);
} // namespace
#endif

namespace {
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
                check("encoded_matrix_available", count >= 20);
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
                float out[256];
                engine->callback(out, 128);
                check("gain_real_output", std::all_of(out, out + 256, [gain](float v) {
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
            controller.enqueueLater({track});
            controller.togglePlay();
            waitFor([&] { return controller.isPlaying(); });
            check("play_pending_head",
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
            check("resume_source", controller.queue().current()->source == QueueSource::Basic);
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
            window.collections().setAllTracks({});
            controller.enqueueLater({track});
            window.requestSave();
            const auto pending = LibraryStore::load();
            check("pending_only_scene_saved", pending.trackPaths.isEmpty() && pending.resumeQueue.size() == 1 &&
                                                  pending.resumeQueue.first().second == int(QueueSource::Later));
            controller.queue().reset();
            window.restoreLibrary();
            waitFor([&] { return !window.isRestoringLibrary(); });
            check("pending_only_scene_restored_paused",
                  controller.queue().count() == 1 && controller.queue().current()->source == QueueSource::Later &&
                      !controller.isPlaying());
            controller.stop();
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
                  lists.create("Road", &two, &note) && one != two && lists.nameOf(one) != lists.nameOf(two));
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
                const QString path = dir.path() + "/list." + ext;
                check("list_export", PlaylistM3U::exportTracks(source, path));
                PlaylistM3U::Imported imported;
                check("list_import", PlaylistM3U::importFile(path, imported));
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
            ctl.queue().appendLater({a});
            const auto entry = ctl.queue().items().first().id;
            const QString old = a.identityKey();
            ctl.setLyricShiftTable({{old, 1.5}});
            check("root_relocation", window.relocateLibraryRoot(dir.path(), dir.path() + "/new").isEmpty());
            const QString moved = QUrl::fromLocalFile(dir.path() + "/new/a.wav").toLocalFile();
            check("root_favorite_migrated", window.collections().favorites() == QStringList{moved});
            check("root_list_migrated", window.collections().playlists().keysOf(id) == QStringList{moved});
            check("root_queue_identity_source", ctl.queue().items().first().id == entry &&
                                                    ctl.queue().items().first().source == QueueSource::Later &&
                                                    ctl.queue().items().first().track.identityKey() == moved);
            check("root_old_reference_gone", window.collections().allTracks().first().identityKey() != old);
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
            int containers = 0;
            for (const QString &name :
                 fixtures.entryList({"*.zip", "*.tar", "*.tar.gz", "*.tar.bz2", "*.7z"}, QDir::Files, QDir::Name)) {
                const QString path = fixtures.filePath(name);
                const auto entries = Archive::listAudioEntries(path);
                if (name == "encrypted.zip") {
                    check("encrypted_archive_rejected", entries.isEmpty());
                    continue;
                }
                check("archive_entries", !entries.isEmpty());
                for (const QString &entry : entries) {
                    const QUrl url = Archive::entryUrl(path, entry);
                    QString parsed, name;
                    check("archive_URL_roundtrip",
                          Archive::parseEntryUrl(url, parsed, name) && parsed == path && name == entry);
                    auto decoder =
                        Decoder::openStream(std::make_shared<ArchiveEntrySource>(path, entry), url.toString());
                    check("archive_true_decoder", bool(decoder));
                    if (decoder) {
                        float l[128], r[128], repeat[128], right[128];
                        const int count = decoder->read(l, r, 128, 44100);
                        const int again = decoder->read(repeat, right, 128, 44100);
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
            PlaylistWindow panel(&ctl, &col);
            panel.m_view->selectAt(1, Qt::NoModifier);
            panel.m_search->setText("Alpha");
            panel.applySearch();
            check("global_search", ctl.tracks().size() == 1);
            panel.clearSearch();
            check("search_restore_selection", panel.m_view->selectedRows() == QList<int>{1});
            panel.m_formats = {"FLAC"};
            panel.applySearch();
            check("format_filter", ctl.tracks().size() == 1 && ctl.tracks().first().identityKey() == b.identityKey());
            panel.clearSearch();
            panel.sortView(4);
            check("sort_persisted", col.currentTracks().first().identityKey() == b.identityKey());
            col.replaceLibrary({a, b});
            col.toggleFavorite(a.identityKey());
            QString list;
            col.playlists().create("Named", &list);
            col.playlists().addKeys({a.identityKey()}, list);
            // 自建歌单可直接收音频/目录（同一条 Importer 链路），不必先写 m3u；固定页拒绝。
            QString direct;
            col.playlists().create("DirectAdd", &direct);
            check("playlist_add_tracks_to_list", panel.addTracksToPlaylist({b}, direct) == 1 &&
                                                     col.playlists().keysOf(direct).contains(b.identityKey()));
            check("playlist_add_tracks_dedup", panel.addTracksToPlaylist({b}, direct) == 0);
            check("playlist_add_tracks_fixed_view", panel.addTracksToPlaylist({b}, Collections::kAllViewId) == 0);
            col.playlists().remove(direct);
            ctl.queue().begin({a, b}, 0);
            ctl.enqueueLater({a});
            panel.m_search->setText("Alpha");
            panel.applySearch();
            panel.removeRows({0});
            check("search_delete_all_writable_pages",
                  !col.isFavorite(a.identityKey()) && col.playlists().keysOf(list).isEmpty());
            check("search_delete_keeps_library", col.tracksOf(Collections::kLibraryViewId).size() == 2);
            check("search_delete_keeps_current",
                  ctl.queue().currentTrack().identityKey() == a.identityKey() && ctl.queue().pendingCount() == 1);
            check("search_stays_active_after_delete", panel.m_beforeSearch.has_value());
            panel.clearSearch();
            check("search_exit_original_page",
                  ctl.tracks().size() == 1 && ctl.tracks().first().identityKey() == b.identityKey());
            col.registerTracks({a});
            col.toggleFavorite(a.identityKey());
            ctl.queue().begin({a, b}, 0);
            int deleted = 0;
            auto deletion = QObject::connect(&panel, &PlaylistWindow::trackRemoved, &panel,
                                             [&deleted](const Track &) { ++deleted; });
            panel.showPage(Collections::kFavViewId);
            panel.removeRows({0});
            check("cancel_favorite_keeps_queue_and_default",
                  deleted == 0 && ctl.queue().count() == 2 && col.tracksOf(Collections::kAllViewId).size() == 2);
            panel.showPage(Collections::kAllViewId);
            int pendingRow = -1;
            for (int row = 0; row < ctl.tracks().size(); ++row)
                if (ctl.tracks()[row].identityKey() == b.identityKey()) pendingRow = row;
            panel.removeRows({pendingRow});
            check("default_delete_drops_pending", deleted == 1 && ctl.queue().count() == 1 &&
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
                check("approved_font_size",
                      Fonts::base.pointSize() == 13 && Fonts::small.pointSize() == 12 && Fonts::tiny.pointSize() == 11);
                check("approved_font_families",
                      Fonts::base.families() == QStringList{"Segoe UI", "Helvetica Neue", "Arial", "Noto Sans",
                                                            "DejaVu Sans", "PingFang SC", "Microsoft YaHei",
                                                            "sans-serif"});
                MainWindow window(&ctl, engine);
                window.show();
                QCoreApplication::processEvents();
                check("UI_main_visible", window.isVisible());
                check("UI_borderless", window.windowFlags().testFlag(Qt::FramelessWindowHint));
                check("UI_approved_compact_width", window.width() < 500 && window.minimumWidth() == 420);
                check("UI_icon", !AppIcon::icon().isNull());
                check("UI_progress_below_transport",
                      window.m_seek->mapTo(&window, QPoint()).y() > window.m_transport->mapTo(&window, QPoint()).y());
                check("UI_volume_transport_same_row", std::abs(window.m_volume->mapTo(&window, QPoint()).y() -
                                                               window.m_transport->mapTo(&window, QPoint()).y()) < 5);
                window.toggleEqPanel();
                check("UI_EQ_visible", window.m_eqWindow && window.m_eqWindow->isVisible());
                auto *eq = window.m_eqWindow;
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
                    // 半透明只作用于四个主面板；队列/封面/属性/设置等辅助窗保持不透明，
                    // 叠在主面板上时文字不会被下层透上来。
                    check("UI_main_panels_follow_glass", window.m_playlist->glassTransparencyFollows() &&
                                                             eq->glassTransparencyFollows() &&
                                                             window.m_lyricWindow->glassTransparencyFollows());
                    CoverWindow cover(&ctl);
                    QueueWindow queue(&ctl);
                    PropertyWindow property(ctl.currentTrack(), &ctl);
                    SettingsWindow settings(&window);
                    for (SkinWindow *aux : QList<SkinWindow *>{&cover, &queue, &property, &settings})
                        check("UI_aux_windows_opaque", !aux->glassTransparencyFollows() && aux->shellAlpha() == 1.0f);
                    check("UI_main_panel_glass_alpha", std::abs(eq->shellAlpha() - GlassStyle::glassAlpha()) < 0.001f);
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
            QElapsedTimer timer;
            timer.start();
            Collections col;
            QList<Track> many;
            for (int i = 0; i < 10000; ++i) {
                Track track(QUrl::fromLocalFile(QStringLiteral("/music/%1.flac").arg(i)));
                track.setTitle(QStringLiteral("Track %1").arg(i));
                many << track;
            }
            col.setAllTracks(many);
            auto result = col.search(TrackFilter("Track 9999"));
            check("large_search_correct", result.hits.size() == 1);
            check("large_search_budget", timer.elapsed() < 6000);
            out << "PERF search_10000_ms=" << timer.elapsed() << '\n';
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
                "{\"queueKeys\":[\"/offline/song.flac\"],\"queueExplicit\":[true],\"queueNext\":[],\"queueIndex\":0,\"position\":12,\"wasPlaying\":false}");
            resume.close();
            auto migrated = LibraryStore::load();
            check("migrated_resume_valid", migrated.resumeValid && migrated.resumeQueue.size() == 1 &&
                                               migrated.resumeQueue.first().second == 1 &&
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
    if (QStringList{"DECODER", "FORMAT", "GAPLESS", "GAIN", "SPECTRUM", "PLAYBACK", "SCENE", "DEVICE", "SLEEP"}
            .contains(suite))
        return tests.audio(suite);
    return tests.models(suite);
}

QStringList regressionSuites() {
    return {"REVIEW", "DECODER", "FORMAT",  "GAPLESS", "GAIN",  "SPECTRUM", "PLAYBACK", "SCENE",
            "DEVICE", "SLEEP",   "LIBRARY", "IMPORT",  "COVER", "SEARCH",   "UI",       "PERF",
            "SYSTEM", "ARCHIVE", "CUE",     "LISTS",   "SHIFT", "PLAYLIST"};
}

int runQueueCoverage(QTextStream &out) {
    RegressionTests tests{out};
    bool natural = true, preview = true, intents = true, manual = true;
    int cases = 0;
    const Track next(QUrl::fromLocalFile("/next.flac")), later(QUrl::fromLocalFile("/later.flac"));
    for (int size = 1; size <= 5; ++size)
        for (int cursor = 0; cursor < size; ++cursor)
            for (PlayMode mode : {PlayMode::Order, PlayMode::ListLoop, PlayMode::SingleLoop, PlayMode::Random})
                for (bool insert : {false, true})
                    for (bool append : {false, true}) {
                        QList<Track> base;
                        for (int i = 0; i < size; ++i)
                            base << Track(QUrl::fromLocalFile(QStringLiteral("/base%1.flac").arg(i)));
                        auto setup = [&](PlayQueue &queue) {
                            queue.begin(base, cursor);
                            queue.randomIndex = [](int, int) { return 0; };
                            if (append) queue.appendLater({later});
                            if (insert) queue.insertNext({next});
                        };
                        PlayQueue queue;
                        setup(queue);
                        QString expected;
                        const bool atEnd = cursor + 1 >= size;
                        if (insert)
                            expected = next.identityKey();
                        else if (mode == PlayMode::SingleLoop)
                            expected = base[cursor].identityKey();
                        else if (mode == PlayMode::Random || (mode == PlayMode::ListLoop && atEnd && !append))
                            expected = base.first().identityKey();
                        else if (!atEnd)
                            expected = base[cursor + 1].identityKey();
                        else if (append)
                            expected = later.identityKey();
                        const auto *peek = queue.peekOnFinish(mode);
                        const QUuid picked = peek ? peek->id : QUuid();
                        const auto *again = queue.peekOnFinish(mode);
                        preview &= queue.cursor() == cursor && (again ? again->id : QUuid()) == picked;
                        const auto *actual = queue.advanceOnFinish(mode);
                        natural &= (actual ? actual->track.identityKey() : QString()) == expected;
                        for (const QueueItem &item : queue.items()) {
                            if (item.track.identityKey() == next.identityKey())
                                intents &= item.source == QueueSource::Next;
                            else if (item.track.identityKey() == later.identityKey())
                                intents &= item.source == QueueSource::Later;
                            else
                                intents &= item.source == QueueSource::Basic;
                        }
                        PlayQueue user;
                        setup(user);
                        const auto *selected = user.advanceByUser(mode);
                        QString wanted = insert                     ? next.identityKey()
                                         : mode == PlayMode::Random ? base.first().identityKey()
                                         : cursor + 1 < size        ? base[cursor + 1].identityKey()
                                         : append                   ? later.identityKey()
                                         : mode == PlayMode::Order  ? QString()
                                                                    : base.first().identityKey();
                        manual &= (selected ? selected->track.identityKey() : QString()) == wanted;
                        ++cases;
                    }
    tests.check("queue_mode_source_natural_matrix", natural);
    tests.check("queue_peek_stable_without_cursor_change", preview);
    tests.check("queue_sources_immutable_matrix", intents);
    tests.check("queue_manual_next_matrix", manual);
    out << "QUEUE matrix_cases=" << cases << '\n';
    PlayQueue queue;
    queue.begin({next, later, next}, 0);
    const QUuid current = queue.current()->id;
    queue.remove({current});
    tests.check("queue_current_cannot_remove", queue.current() && queue.current()->id == current && queue.count() == 3);
    const auto before = queue.items();
    tests.check("queue_invalid_reorder_atomic",
                !queue.reorderPending({before[1].id, before[1].id}) && queue.items() == before);
    queue.dropTracks({next.identityKey()});
    tests.check("queue_drop_duplicate_preserves_playing", queue.count() == 2 && queue.current()->id == current);
    queue.clearPending();
    tests.check("queue_clear_keeps_current", queue.count() == 1 && queue.current()->id == current);
    return tests.failed;
}
