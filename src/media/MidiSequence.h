#pragma once

#include <QByteArray>
#include <QHash>
#include <QString>
#include <atomic>
#include <cstdint>
#include <vector>

// 时间轴始终为 48 kHz；事件按 tick、轨道、轨内顺序稳定排列。
struct MidiEvent {
    int64_t frame = 0;
    uint8_t status = 0;
    uint8_t first = 0;
    uint8_t second = 0;
};

struct MidiSequence {
    static constexpr int kSampleRate = 48000;
    static constexpr int kMaxBytes = 32 * 1024 * 1024;
    static constexpr int64_t kMaxFrames = int64_t(kSampleRate) * 24 * 60 * 60;
    std::vector<MidiEvent> events;
    int64_t endFrame = 0;
    QHash<QString, QString> tags;

    static bool parse(const QByteArray &bytes, MidiSequence &result, QString &error,
                      const std::atomic<bool> *cancel = nullptr);
};
