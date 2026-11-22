#include "MidiSequence.h"

#include <QByteArrayView>
#include <QStringDecoder>
#include <QtEndian>
#include <algorithm>
#include <cmath>
#ifdef TTPLAYER_HAVE_TEXTCODEC
#include <QTextCodec>
#endif

namespace {
struct Reader {
    QByteArrayView data;
    qsizetype pos = 0;
    bool valid = true;

    QByteArrayView take(qsizetype size) {
        if (size < 0 || size > data.size() - pos) {
            valid = false;
            return {};
        }
        const auto value = data.sliced(pos, size);
        pos += size;
        return value;
    }
    uint8_t byte() {
        const auto value = take(1);
        return value.isEmpty() ? 0 : uint8_t(value[0]);
    }
    uint32_t integer(int count, bool little = false) {
        if (count < 1 || count > 4) {
            valid = false;
            return 0;
        }
        const auto value = take(count);
        uint32_t result = 0;
        for (qsizetype i = 0; i < value.size(); ++i) {
            const qsizetype index = little ? value.size() - i - 1 : i;
            result = (result << 8) | uint8_t(value[index]);
        }
        return result;
    }
    uint32_t variable() {
        uint32_t value = 0;
        for (int i = 0; i < 4; ++i) {
            const uint8_t next = byte();
            value = (value << 7) | (next & 0x7f);
            if (!(next & 0x80)) return value;
        }
        valid = false;
        return 0;
    }
};

struct TimedEvent {
    int64_t tick = 0;
    uint8_t status = 0;
    uint8_t first = 0;
    uint8_t second = 0;
    QByteArray payload;
};

QString text(const QByteArray &bytes) {
    // 与外置歌词一致：严格 UTF-8 → GB18030 → Latin-1。
    QStringDecoder utf8(QStringDecoder::Utf8);
    QString decoded = utf8(bytes);
    if (!utf8.hasError()) return decoded;
#ifdef TTPLAYER_HAVE_TEXTCODEC
    if (QTextCodec *codec = QTextCodec::codecForName("GB18030")) return codec->toUnicode(bytes);
#endif
    return QString::fromLatin1(bytes);
}

bool resetMessage(QByteArrayView bytes) {
    if (bytes.size() == 5 && uint8_t(bytes[0]) == 0x7e && uint8_t(bytes[2]) == 9 &&
        (uint8_t(bytes[3]) == 1 || uint8_t(bytes[3]) == 3) && uint8_t(bytes[4]) == 0xf7)
        return true;
    if (bytes.size() == 8 && uint8_t(bytes[0]) == 0x43 && uint8_t(bytes[2]) == 0x4c &&
        bytes.sliced(3) == QByteArrayView("\0\0\x7e\0\xf7", 5))
        return true;
    return bytes.size() == 10 && uint8_t(bytes[0]) == 0x41 && uint8_t(bytes[2]) == 0x42 &&
           bytes.sliced(3) == QByteArrayView("\x12\x40\0\x7f\0\x41\xf7", 7);
}

bool track(Reader &reader, std::vector<TimedEvent> &events, QString &error, const std::atomic<bool> *cancel) {
    int64_t tick = 0;
    uint8_t running = 0;
    bool ended = false;
    while (reader.pos < reader.data.size() && reader.valid) {
        if (cancel && cancel->load()) {
            error = QStringLiteral("MIDI 读取已取消");
            return false;
        }
        if (events.size() >= 1000000) {
            error = QStringLiteral("MIDI 事件超过 100 万条限制");
            return false;
        }
        tick += reader.variable();
        uint8_t status = reader.byte();
        if (status < 0x80) {
            if (!running) break;
            --reader.pos;
            status = running;
        }
        TimedEvent event{tick, status, 0, 0, {}};
        if (status < 0xf0) {
            running = status;
            event.first = reader.byte();
            if ((status & 0xe0) != 0xc0) event.second = reader.byte();
            if (event.first >= 0x80 || event.second >= 0x80) break;
        } else {
            running = 0;
            if (status == 0xff) {
                event.first = reader.byte();
                const auto size = reader.variable();
                const auto payload = reader.take(size);
                if (!reader.valid) break;
                // 即使不保留 payload，也计入事件预算并校验长度。
                if (event.first == 0x2f) {
                    if (size != 0 || reader.pos != reader.data.size()) break;
                    ended = true;
                } else if (event.first == 0x51) {
                    if (size != 3 || (payload[0] == 0 && payload[1] == 0 && payload[2] == 0)) break;
                    event.payload = payload.toByteArray();
                } else if (event.first == 0x21) {
                    if (size != 1) break;
                    if (payload[0] != 0) {
                        error = QStringLiteral("不支持需要多个 MIDI 端口的文件");
                        return false;
                    }
                } else if (event.first == 1 || event.first == 3 || event.first == 5) {
                    event.payload = payload.toByteArray();
                }
            } else if (status == 0xf0 || status == 0xf7) {
                const auto size = reader.variable();
                const auto payload = reader.take(size);
                if (!reader.valid) break;
                if (payload.size() >= 3 && uint8_t(payload[0]) == 0x41 && uint8_t(payload[2]) == 0x16) {
                    error = QStringLiteral("不支持需要 Roland MT-32 专用音源的 MIDI");
                    return false;
                }
                // 用独立状态表示可还原为 GM 的 reset；其余专有 SysEx 不猜测。
                event.status = resetMessage(payload) ? 0xf0 : 0xf7;
            } else {
                break;
            }
        }
        if (!reader.valid) break;
        events.push_back(std::move(event));
        if (ended) return true;
    }
    error = QStringLiteral("MIDI 轨道损坏：事件截断、非法状态/长度或缺少结束标记");
    return false;
}
} // namespace

bool MidiSequence::parse(const QByteArray &bytes, MidiSequence &result, QString &error,
                         const std::atomic<bool> *cancel) {
    result = {};
    error.clear();
    const auto fail = [&](const QString &message) {
        error = message;
        return false;
    };
    if (bytes.size() > kMaxBytes) return fail(QStringLiteral("MIDI 文件超过 32 MiB 限制"));
    Reader input{bytes};
    if (bytes.startsWith("RIFF")) {
        input.take(4);
        const uint32_t riffSize = input.integer(4, true);
        if (riffSize != uint64_t(bytes.size() - 8) || input.take(4) != QByteArrayView("RMID", 4))
            return fail(QStringLiteral("RMID 容器长度或标识无效"));
        QByteArrayView smf;
        while (input.valid && input.pos < input.data.size()) {
            const auto id = input.take(4);
            const uint32_t size = input.integer(4, true);
            const auto payload = input.take(size);
            if (id == QByteArrayView("data", 4)) {
                if (!smf.isEmpty()) return fail(QStringLiteral("RMID 包含多个 MIDI 数据块"));
                smf = payload;
            }
            if (size & 1) input.take(1);
        }
        if (!input.valid || smf.isEmpty()) return fail(QStringLiteral("RMID 数据块损坏或缺失"));
        input = Reader{smf};
    }
    if (input.take(4) != QByteArrayView("MThd", 4)) return fail(QStringLiteral("MIDI 文件头无效"));
    const uint32_t headerSize = input.integer(4);
    Reader header{input.take(headerSize)};
    const uint32_t format = header.integer(2);
    const uint32_t tracks = header.integer(2);
    const uint32_t division = header.integer(2);
    if (format == 2) return fail(QStringLiteral("不支持 SMF 格式 2 的独立多曲时间轴"));
    if (!header.valid || !input.valid || format > 1 || tracks == 0 || (format == 0 && tracks != 1) || division == 0)
        return fail(QStringLiteral("MIDI 文件头参数或长度无效"));
    long double ticksPerSecond = 0;
    if (division & 0x8000) {
        const int fps = 256 - int(division >> 8);
        const int subframes = int(division & 0xff);
        if ((fps != 24 && fps != 25 && fps != 29 && fps != 30) || subframes == 0)
            return fail(QStringLiteral("MIDI SMPTE 时间基无效"));
        ticksPerSecond = (fps == 29 ? 30000.0L / 1001 : fps) * subframes;
    }
    std::vector<TimedEvent> events;
    for (uint32_t i = 0; i < tracks; ++i) {
        if (input.take(4) != QByteArrayView("MTrk", 4)) return fail(QStringLiteral("MIDI 轨道块缺失"));
        const uint32_t length = input.integer(4);
        Reader reader{input.take(length)};
        if (!input.valid) return fail(QStringLiteral("MIDI 轨道块长度超出文件"));
        if (!track(reader, events, error, cancel)) return false;
    }
    if (input.pos != input.data.size()) return fail(QStringLiteral("MIDI 包含未声明的尾部数据"));
    std::stable_sort(events.begin(), events.end(), [](const auto &a, const auto &b) { return a.tick < b.tick; });
    const bool hasLyrics = std::any_of(events.begin(), events.end(), [](const auto &event) {
        return event.status == 0xff && event.first == 5 && !event.payload.isEmpty();
    });
    int64_t previous = 0;
    long double seconds = 0;
    uint32_t tempo = 500000;
    QString lyrics, line;
    int64_t lineFrame = 0;
    const auto flushLine = [&] {
        if (line.trimmed().isEmpty()) return;
        const int64_t millis = lineFrame * 1000 / kSampleRate;
        lyrics += QStringLiteral("[%1:%2.%3]%4\n")
                      .arg(millis / 60000, 2, 10, QLatin1Char('0'))
                      .arg(millis / 1000 % 60, 2, 10, QLatin1Char('0'))
                      .arg(millis % 1000, 3, 10, QLatin1Char('0'))
                      .arg(line.trimmed());
        line.clear();
    };
    for (const auto &event : events) {
        if (cancel && cancel->load()) return fail(QStringLiteral("MIDI 解析已取消"));
        const int64_t delta = event.tick - previous;
        seconds += ticksPerSecond > 0 ? delta / ticksPerSecond
                                      : static_cast<long double>(delta) * tempo / (division * 1000000.0L);
        previous = event.tick;
        if (seconds > 24 * 60 * 60) return fail(QStringLiteral("MIDI 时间轴超过 24 小时限制"));
        const int64_t frame = int64_t(std::llround(seconds * kSampleRate));
        result.endFrame = frame;
        if (event.status < 0xf0 || event.status == 0xf0) {
            result.events.push_back({frame, event.status, event.first, event.second});
        } else if (event.status == 0xff) {
            if (event.first == 0x51) {
                Reader value{event.payload};
                tempo = value.integer(3);
            } else if (event.first == 3 && !result.tags.contains(QStringLiteral("title"))) {
                const QString title = text(event.payload).trimmed();
                if (!title.isEmpty()) result.tags.insert(QStringLiteral("title"), title);
            } else if (event.first == (hasLyrics ? 5 : 1)) {
                const QString value = text(event.payload);
                if (value.startsWith(QLatin1Char('@'))) {
                    if (value.startsWith(QLatin1String("@T")) && !result.tags.contains(QStringLiteral("title")))
                        result.tags.insert(QStringLiteral("title"), value.mid(2).trimmed());
                    continue;
                }
                for (const QChar character : value) {
                    if (character == QLatin1Char('/') || character == QLatin1Char('\\') ||
                        character == QLatin1Char('\r') || character == QLatin1Char('\n')) {
                        flushLine();
                    } else if (!character.isNull()) {
                        if (line.isEmpty()) lineFrame = frame;
                        line += character;
                    }
                }
            }
        }
    }
    flushLine();
    if (!lyrics.isEmpty()) result.tags.insert(QStringLiteral("lyrics"), lyrics);
    return true;
}
