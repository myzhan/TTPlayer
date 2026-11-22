#pragma once

#include "Decoder.h"
#include <QByteArrayView>
#include <QSet>

// 有限的事件/模块数据 → 按需 RF64 Float32；FFmpeg 仍负责 PCM 解码与重采样。
class SequencedAudioSource final : public StreamSource {
public:
    static const QSet<QString> &extensions();
    static QString identify(QByteArrayView prefix);
    // 非序列输入返回空且 error 为空；已识别但非法的输入返回具体原因。
    static std::shared_ptr<SequencedAudioSource> openFile(const QString &path, QString &error,
                                                          std::shared_ptr<const std::atomic<bool>> cancel);
    static std::shared_ptr<SequencedAudioSource> openStream(const std::shared_ptr<StreamSource> &source, QString &error,
                                                            std::shared_ptr<const std::atomic<bool>> cancel);
    ~SequencedAudioSource() override;
    int64_t read(uint8_t *buf, int size) override;
    bool seekable() const override { return true; }
    int64_t seek(int64_t offset, int whence) override;
    void cancel() override;
    const QString &format() const;
    const QHash<QString, QString> &tags() const;

private:
    struct State;
    explicit SequencedAudioSource(std::unique_ptr<State> state);
    static std::shared_ptr<SequencedAudioSource> create(const QByteArray &bytes, const QString &format, QString &error,
                                                        std::shared_ptr<const std::atomic<bool>> cancel);
    std::unique_ptr<State> m_state;
};
