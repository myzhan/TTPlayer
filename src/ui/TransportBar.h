#pragma once

// 传输键带（浅玻璃 SegmentedGlassBar）：改用 SkinParts 的 TTButton + Skin::drawGlyph，
// 与主面板其它按钮共用同一套玻璃砖渲染（bodyAlpha 走 buttonAlpha）。

#include "playback/PlayerController.h"
#include "SkinParts.h"

#include <QWidget>

/// 传输键带：上一首 / 播放暂停 / 停止 / 下一首 / 模式（音量推子在 MainWindow 底部条）
class TransportBar : public QWidget {
    Q_OBJECT
public:
    explicit TransportBar(PlayerController *controller, QWidget *parent = nullptr);

protected:
    void paintEvent(QPaintEvent *) override;

private:
    PlayerController *m_controller;
    TTButton *m_play = nullptr;
    TTButton *m_mode = nullptr;
};
