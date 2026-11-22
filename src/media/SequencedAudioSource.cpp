#include "SequencedAudioSource.h"
#include "MidiSequence.h"

#include <QFile>
#include <QFileInfo>
#include <QtEndian>
#include <algorithm>
#include <array>
#include <bit>
#include <cstring>
#include <limits>
#include <mutex>
#include <fluidlite.h>
#include <xmp.h>
extern "C" {
#include <libavformat/avio.h>
#include <libavutil/error.h>
}

namespace {
constexpr int kRate = MidiSequence::kSampleRate;
constexpr int kBlock = 1024;
constexpr int kFrameBytes = 8;
constexpr int kHeaderBytes = 80;
constexpr int kModuleLimit = 64 * 1024 * 1024;
// 上游默认 fileapi、SF3 Vorbis 临时结构以及首次初始化的表不是线程安全的。
std::mutex synthInitMutex;

struct FontFile {
    QFile file{QStringLiteral(":/soundfont/FluidR3Mono_GM.sf3")};
    std::shared_ptr<const std::atomic<bool>> cancel;
    bool cancelled() const { return cancel && cancel->load(); }
};

fluid_fileapi_t fontApi(std::shared_ptr<const std::atomic<bool>> *cancel) {
    fluid_fileapi_t api{};
    api.data = cancel;
    api.fopen = [](fluid_fileapi_t *self, const char *) -> void * {
        auto file = std::make_unique<FontFile>();
        file->cancel = *static_cast<std::shared_ptr<const std::atomic<bool>> *>(self->data);
        if (file->cancelled() || !file->file.open(QIODevice::ReadOnly)) return nullptr;
        return file.release();
    };
    api.fread = [](void *buffer, int count, void *handle) {
        auto *file = static_cast<FontFile *>(handle);
        return !file->cancelled() && count >= 0 && file->file.read(static_cast<char *>(buffer), count) == count ? 0
                                                                                                                : -1;
    };
    api.fseek = [](void *handle, long offset, int origin) {
        auto *file = static_cast<FontFile *>(handle);
        const qint64 base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? file->file.pos() : file->file.size();
        const qint64 target = base + offset;
        return !file->cancelled() && target >= 0 && target <= file->file.size() && file->file.seek(target) ? 0 : -1;
    };
    api.fclose = [](void *handle) {
        delete static_cast<FontFile *>(handle);
        return 0;
    };
    api.ftell = [](void *handle) {
        auto *file = static_cast<FontFile *>(handle);
        return file->cancelled() ? -1L : long(file->file.pos());
    };
    return api;
}

QByteArray waveHeader(int64_t frames) {
    QByteArray header(kHeaderBytes, '\0');
    const uint64_t bytes = uint64_t(frames) * kFrameBytes;
    auto *data = reinterpret_cast<uchar *>(header.data());
    std::copy_n("RF64", 4, data);
    qToLittleEndian<quint32>(0xffffffffU, data + 4);
    std::copy_n("WAVEds64", 8, data + 8);
    qToLittleEndian<quint32>(28, data + 16);
    qToLittleEndian<quint64>(bytes + kHeaderBytes - 8, data + 20);
    qToLittleEndian<quint64>(bytes, data + 28);
    qToLittleEndian<quint64>(uint64_t(frames), data + 36);
    std::copy_n("fmt ", 4, data + 48);
    qToLittleEndian<quint32>(16, data + 52);
    qToLittleEndian<quint16>(3, data + 56);
    qToLittleEndian<quint16>(2, data + 58);
    qToLittleEndian<quint32>(kRate, data + 60);
    qToLittleEndian<quint32>(kRate * kFrameBytes, data + 64);
    qToLittleEndian<quint16>(kFrameBytes, data + 68);
    qToLittleEndian<quint16>(32, data + 70);
    std::copy_n("data", 4, data + 72);
    qToLittleEndian<quint32>(0xffffffffU, data + 76);
    return header;
}
} // namespace

struct SequencedAudioSource::State {
    QString format;
    QHash<QString, QString> tags;
    MidiSequence midi;
    std::shared_ptr<const std::atomic<bool>> externalCancel;
    std::atomic<bool> aborted{false};
    fluid_fileapi_t api{};
    fluid_settings_t *settings = nullptr;
    fluid_synth_t *synth = nullptr;
    xmp_context module = nullptr;
    bool moduleLoaded = false;
    bool moduleStarted = false;
    int moduleEntry = 0;
    bool moduleEnded = false;
    size_t nextEvent = 0;
    bool released = false;
    int64_t frames = 0;
    int64_t rendered = 0;
    int64_t position = 0;
    QByteArray header;
    std::array<float, size_t(kBlock) * 2> pcm{};
    std::array<int16_t, size_t(kBlock) * 2> integerPcm{};
    std::array<uint8_t, size_t(kBlock) * kFrameBytes> cache{};
    int64_t cacheFrame = -1;
    int cacheFrames = 0;

    ~State() {
        if (synth) delete_fluid_synth(synth);
        if (settings) delete_fluid_settings(settings);
        if (moduleStarted) xmp_end_player(module);
        if (moduleLoaded) xmp_release_module(module);
        if (module) xmp_free_context(module);
    }
    bool cancelled() const { return aborted.load() || (externalCancel && externalCancel->load()); }
    bool initSynth() {
        const std::lock_guard lock(synthInitMutex);
        if (cancelled()) return false;
        settings = new_fluid_settings();
        if (!settings) return false;
        fluid_settings_setnum(settings, "synth.sample-rate", kRate);
        fluid_settings_setnum(settings, "synth.gain", 0.5);
        fluid_settings_setint(settings, "synth.polyphony", 256);
        api = fontApi(&externalCancel);
        fluid_set_default_fileapi(&api);
        synth = new_fluid_synth(settings);
        const int font = synth ? fluid_synth_sfload(synth, "embedded-gm.sf3", 1) : -1;
        fluid_set_default_fileapi(nullptr);
        return font >= 0 && !cancelled();
    }
    bool reset() {
        if (synth) {
            const std::lock_guard lock(synthInitMutex);
            if (cancelled()) return false;
            // 同一 owner 内转移音色，不与别的 synth 共享有引用计数的样本。
            // 重建 synth 可清除内部 64 帧缓存及 chorus/reverb 的全部历史。
            fluid_sfont_t *font = fluid_synth_get_sfont(synth, 0);
            fluid_synth_remove_sfont(synth, font);
            delete_fluid_synth(synth);
            synth = new_fluid_synth(settings);
            if (!synth) {
                font->free(font);
                return false;
            }
            fluid_synth_add_sfont(synth, font);
            fluid_synth_program_reset(synth);
        } else {
            if (moduleStarted) xmp_end_player(module);
            moduleStarted = xmp_start_player(module, kRate, 0) == 0;
            if (!moduleStarted) return false;
            // libxmp 以 -1 表示尚未播放的第 0 个位置，真正错误码小于 -1。
            if (xmp_set_position(module, moduleEntry) < -1) return false;
            moduleEnded = false;
        }
        rendered = 0;
        nextEvent = 0;
        released = false;
        cacheFrame = -1;
        cacheFrames = 0;
        return !cancelled();
    }
    void dispatch(const MidiEvent &event) const {
        const int channel = event.status & 0xf;
        switch (event.status & 0xf0) {
        case 0x80:
            fluid_synth_noteoff(synth, channel, event.first);
            break;
        case 0x90:
            fluid_synth_noteon(synth, channel, event.first, event.second);
            break;
        case 0xa0:
            fluid_synth_key_pressure(synth, channel, event.first, event.second);
            break;
        case 0xb0:
            fluid_synth_cc(synth, channel, event.first, event.second);
            break;
        case 0xc0:
            fluid_synth_program_change(synth, channel, event.first);
            break;
        case 0xd0:
            fluid_synth_channel_pressure(synth, channel, event.first);
            break;
        case 0xe0:
            fluid_synth_pitch_bend(synth, channel, event.first | (event.second << 7));
            break;
        case 0xf0:
            fluid_synth_system_reset(synth);
            break;
        default:
            break;
        }
    }
    bool render(int count) {
        if (cancelled()) return false;
        if (synth) {
            int done = 0;
            while (done < count) {
                if (cancelled()) return false;
                while (nextEvent < midi.events.size() && midi.events[nextEvent].frame <= rendered) {
                    if (cancelled()) return false;
                    dispatch(midi.events[nextEvent++]);
                }
                if (!released && rendered >= midi.endFrame) {
                    for (int channel = 0; channel < 16; ++channel) {
                        fluid_synth_cc(synth, channel, 64, 0);
                        fluid_synth_cc(synth, channel, 66, 0);
                        fluid_synth_cc(synth, channel, 123, 0);
                    }
                    released = true;
                }
                int64_t until = frames;
                if (nextEvent < midi.events.size()) until = midi.events[nextEvent].frame;
                if (!released) until = std::min(until, midi.endFrame);
                const int block = int(std::min<int64_t>(count - done, until - rendered));
                if (block <= 0) return false;
                if (fluid_synth_write_float(synth, block, pcm.data(), done * 2, 2, pcm.data(), done * 2 + 1, 2) != 0)
                    return false;
                done += block;
                rendered += block;
            }
        } else {
            integerPcm.fill(0);
            if (!moduleEnded) {
                const int status = xmp_play_buffer(module, integerPcm.data(), count * 4, 1);
                if (status == -XMP_END)
                    moduleEnded = true;
                else if (status != 0)
                    return false;
            }
            for (int i = 0; i < count * 2; ++i)
                pcm[size_t(i)] = integerPcm[size_t(i)] / 32768.0f;
            rendered += count;
        }
        return !cancelled();
    }
    bool cacheAt(int64_t frame) {
        if (cacheFrame >= 0 && frame >= cacheFrame && frame < cacheFrame + cacheFrames) return true;
        if (frame < rendered && !reset()) return false;
        while (rendered < frame) {
            const int count = int(std::min<int64_t>(kBlock, frame - rendered));
            if (!render(count)) return false;
        }
        cacheFrame = frame;
        cacheFrames = int(std::min<int64_t>(kBlock, frames - frame));
        if (!render(cacheFrames)) return false;
        for (int i = 0; i < cacheFrames * 2; ++i)
            qToLittleEndian<quint32>(std::bit_cast<quint32>(pcm[size_t(i)]), cache.data() + size_t(i) * 4);
        return true;
    }
};

const QSet<QString> &SequencedAudioSource::extensions() {
    static const QSet<QString> value{QStringLiteral("mid"), QStringLiteral("midi"), QStringLiteral("kar"),
                                     QStringLiteral("mod"), QStringLiteral("xm"),   QStringLiteral("s3m"),
                                     QStringLiteral("it")};
    return value;
}

QString SequencedAudioSource::identify(QByteArrayView prefix) {
    if (prefix.startsWith("MThd") ||
        (prefix.size() >= 12 && prefix.startsWith("RIFF") && prefix.sliced(8, 4) == QByteArrayView("RMID", 4)))
        return QStringLiteral("MIDI");
    if (prefix.startsWith("Extended Module: ")) return QStringLiteral("XM");
    if (prefix.startsWith("IMPM")) return QStringLiteral("IT");
    if (prefix.size() >= 48 && prefix.sliced(44, 4) == QByteArrayView("SCRM", 4)) return QStringLiteral("S3M");
    if (prefix.size() >= 1084) {
        const auto magic = prefix.sliced(1080, 4);
        if (magic == QByteArrayView("M.K.", 4) || magic == QByteArrayView("M!K!", 4) ||
            magic == QByteArrayView("FLT4", 4) || magic == QByteArrayView("FLT8", 4) ||
            (magic[0] >= '1' && magic[0] <= '9' && magic.sliced(1) == QByteArrayView("CHN", 3)) ||
            (magic[0] >= '1' && magic[0] <= '3' && magic[1] >= '0' && magic[1] <= '9' &&
             magic.sliced(2) == QByteArrayView("CH", 2)))
            return QStringLiteral("MOD");
    }
    return {};
}

std::shared_ptr<SequencedAudioSource> SequencedAudioSource::create(const QByteArray &bytes, const QString &format,
                                                                   QString &error,
                                                                   std::shared_ptr<const std::atomic<bool>> cancel) {
    auto state = std::make_unique<State>();
    state->format = format;
    state->externalCancel = std::move(cancel);
    if (format == QLatin1String("MIDI")) {
        if (!MidiSequence::parse(bytes, state->midi, error, state->externalCancel.get())) return {};
        state->frames = state->midi.endFrame + int64_t(kRate) * 2;
        state->tags = state->midi.tags;
        if (!state->initSynth()) {
            error = state->cancelled() ? QStringLiteral("MIDI 合成初始化已取消")
                                       : QStringLiteral("无法加载内置 GM 音色或创建 MIDI 合成器");
            return {};
        }
    } else {
        state->module = xmp_create_context();
        if (state->module && !state->cancelled())
            state->moduleLoaded =
                xmp_load_module_from_memory(state->module, bytes.constData(), long(bytes.size())) == 0;
        if (!state->moduleLoaded || state->cancelled()) {
            error = QStringLiteral("模块音乐损坏、格式不支持或读取已取消");
            return {};
        }
        xmp_module_info info{};
        xmp_get_module_info(state->module, &info);
        for (int i = 0; i < info.num_sequences; ++i) {
            if (info.seq_data[i].duration <= 0) continue;
            state->frames = int64_t(info.seq_data[i].duration) * kRate / 1000;
            state->moduleEntry = info.seq_data[i].entry_point;
            break;
        }
        if (state->frames <= 0 || state->frames > MidiSequence::kMaxFrames || !state->reset()) {
            error = QStringLiteral("模块没有有效的有限播放序列，或时间轴超过 24 小时");
            return {};
        }
        if (info.mod) state->tags.insert(QStringLiteral("title"), QString::fromLatin1(info.mod->name).trimmed());
    }
    state->header = waveHeader(state->frames);
    return std::shared_ptr<SequencedAudioSource>(new SequencedAudioSource(std::move(state)));
}

std::shared_ptr<SequencedAudioSource> SequencedAudioSource::openFile(const QString &path, QString &error,
                                                                     std::shared_ptr<const std::atomic<bool>> cancel) {
    error.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    const QString format = identify(file.peek(1084));
    if (format.isEmpty()) {
        if (extensions().contains(QFileInfo(path).suffix().toLower()))
            error = QStringLiteral("序列音乐文件头无效或不是受支持的 MIDI/MOD/XM/S3M/IT");
        return {};
    }
    const int limit = format == QLatin1String("MIDI") ? MidiSequence::kMaxBytes : kModuleLimit;
    if (file.size() > limit) {
        error = QStringLiteral("%1 文件超过 %2 MiB 限制").arg(format).arg(limit / 1024 / 1024);
        return {};
    }
    QByteArray bytes;
    while (!file.atEnd()) {
        if (cancel && cancel->load()) {
            error = QStringLiteral("序列音乐读取已取消");
            return {};
        }
        const QByteArray block = file.read(65536);
        if (block.isEmpty() || bytes.size() + block.size() > limit) {
            error = QStringLiteral("序列音乐读取失败或超过大小限制");
            return {};
        }
        bytes += block;
    }
    return create(bytes, format, error, std::move(cancel));
}

std::shared_ptr<SequencedAudioSource>
SequencedAudioSource::openStream(const std::shared_ptr<StreamSource> &source, QString &error,
                                 std::shared_ptr<const std::atomic<bool>> cancel) {
    error.clear();
    if (!source || !source->seekable()) return {};
    std::array<uint8_t, 1084> prefix{};
    int size = 0;
    while (size < int(prefix.size())) {
        if (cancel && cancel->load()) {
            error = QStringLiteral("序列音乐探测已取消");
            return {};
        }
        const int64_t count = source->read(prefix.data() + size, int(prefix.size()) - size);
        if (count <= 0) break;
        size += int(count);
    }
    if (source->seek(0, SEEK_SET) != 0) {
        error = QStringLiteral("无法复原媒体探测前缀");
        return {};
    }
    const QString format = identify(QByteArrayView(reinterpret_cast<const char *>(prefix.data()), size));
    if (format.isEmpty()) return {};
    const int limit = format == QLatin1String("MIDI") ? MidiSequence::kMaxBytes : kModuleLimit;
    QByteArray bytes;
    std::array<uint8_t, 65536> block{};
    for (;;) {
        if (cancel && cancel->load()) {
            error = QStringLiteral("序列音乐读取已取消");
            return {};
        }
        const int64_t count = source->read(block.data(), int(block.size()));
        if (count == 0) break;
        if (count < 0 || bytes.size() + count > limit) {
            error = QStringLiteral("%1 读取失败或超过 %2 MiB 限制").arg(format).arg(limit / 1024 / 1024);
            return {};
        }
        bytes.append(reinterpret_cast<const char *>(block.data()), qsizetype(count));
    }
    return create(bytes, format, error, std::move(cancel));
}

SequencedAudioSource::SequencedAudioSource(std::unique_ptr<State> state) : m_state(std::move(state)) {}
SequencedAudioSource::~SequencedAudioSource() = default;
const QString &SequencedAudioSource::format() const {
    return m_state->format;
}
const QHash<QString, QString> &SequencedAudioSource::tags() const {
    return m_state->tags;
}
void SequencedAudioSource::cancel() {
    m_state->aborted.store(true);
}

int64_t SequencedAudioSource::seek(int64_t offset, int whence) {
    const int64_t size = kHeaderBytes + m_state->frames * kFrameBytes;
    if (whence & AVSEEK_SIZE) return size;
    whence &= ~AVSEEK_FORCE;
    const int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? m_state->position : size;
    if ((whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) || offset < -base || offset > size - base)
        return AVERROR(EINVAL);
    m_state->position = base + offset;
    // 只移动逻辑位置；查长度及探测尾部不能触发整首合成。
    return m_state->position;
}

int64_t SequencedAudioSource::read(uint8_t *buf, int size) {
    State &state = *m_state;
    if (size < 0) return AVERROR(EINVAL);
    if (state.cancelled()) return AVERROR_EXIT;
    const int64_t end = kHeaderBytes + state.frames * kFrameBytes;
    int done = 0;
    while (done < size && state.position < end) {
        if (state.cancelled()) return AVERROR_EXIT;
        int count = 0;
        if (state.position < kHeaderBytes) {
            count = int(std::min<int64_t>(size - done, kHeaderBytes - state.position));
            std::memcpy(buf + done, state.header.constData() + state.position, size_t(count));
        } else {
            const int64_t offset = state.position - kHeaderBytes;
            if (!state.cacheAt(offset / kFrameBytes)) return state.cancelled() ? AVERROR_EXIT : AVERROR(EIO);
            const int64_t cachedOffset = offset - state.cacheFrame * kFrameBytes;
            count = int(std::min<int64_t>(size - done, int64_t(state.cacheFrames) * kFrameBytes - cachedOffset));
            std::memcpy(buf + done, state.cache.data() + cachedOffset, size_t(count));
        }
        done += count;
        state.position += count;
    }
    return done;
}
