#pragma once

// 歌词窗（滚动显示，自包含版）：监听控制器位置回显，
// 带时间歌词居中高亮、上下渐隐；内嵌纯文本可滚动阅读，不参与时间校准。

#include "playback/PlayerController.h"
#include "media/Lyric.h"
#include "SkinWindow.h"

#include <QWidget>

class QPlainTextEdit;

class LyricWindow : public SkinWindow {
    Q_OBJECT
public:
    explicit LyricWindow(PlayerController *controller, QWidget *parent = nullptr);

    void reload(); // 按当前曲目重新查找歌词

protected:
    void paintBody(QPainter *p, const QRectF &rect) override;

private:
    PlayerController *m_controller;
    Lyric m_lyric;
    QPlainTextEdit *m_plainText = nullptr;
    double m_pos = 0;
    int m_index = -1;
};
