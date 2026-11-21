#pragma once

// 均衡器窗：左栏音量旋钮 + 开关/重置/预设 + dB 刻度
// + 10 段竖推子 + 增益/频率读数。直接驱动 AudioEngine 的 Equalizer（RBJ biquad）。
// 左栏保留独立 EQ 前置增益和音量；音量通过主窗统一静音/存档入口。

#include "audio/AudioEngine.h"
#include "SkinWindow.h"

#include <QWidget>
#include <array>

class FaderView;
class KnobView;
class TTButton;
class QLabel;

class EqWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit EqWindow(AudioEnginePtr engine, QWidget *parent = nullptr);

    void syncFromEngine();
signals:
    void volumeRequested(double volume);

protected:
    void paintBody(QPainter *p, const QRectF &rect) override;

private:
    friend class RegressionTests;
    void applyGains();
    void refreshReadout();
    void showPresetMenu();

    AudioEnginePtr m_engine;
    KnobView *m_volume = nullptr;
    KnobView *m_preamp = nullptr;
    TTButton *m_enable = nullptr;
    TTButton *m_reset = nullptr;
    TTButton *m_preset = nullptr;
    std::array<FaderView *, 10> m_faders{};
    std::array<QLabel *, 10> m_gainLabels{};
    QString m_currentPreset = QStringLiteral("默认");
};
