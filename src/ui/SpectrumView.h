#pragma once

// 频谱：24 fps 重绘（不是 30，AGENTS.md 热路径约定）；整块渐变 + 柱路径裁一次 +
// 柱尖高光一次填充（不逐柱各画渐变，否则 CPU 退化 8 个百分点）。
// 窗口不可见时 timer 停摆不重绘（occlusion 处理）。

#include "audio/AudioEngine.h"

#include <QTimer>
#include <QWidget>
#include <array>

class SpectrumView : public QWidget {
    Q_OBJECT
public:
    explicit SpectrumView(AudioEnginePtr engine, QWidget *parent = nullptr);

signals:
    void frameRequested();

protected:
    void paintEvent(QPaintEvent *) override;
    void hideEvent(QHideEvent *) override;
    void showEvent(QShowEvent *) override;

private:
    friend class RegressionTests;
    QRect advanceFrame();
    AudioEnginePtr m_engine;
    QTimer m_timer;
    std::array<float, SpectrumAnalyzer::kBands> m_bands{}; // 平滑后的显示值（不是原始 FFT 能量）
    std::array<float, SpectrumAnalyzer::kBands> m_peaks{}; // 柱尖回落
};
