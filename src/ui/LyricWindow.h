#pragma once

// 歌词窗（滚动显示，自包含版）：监听控制器位置回显，
// 用同名 .lrc 查当前行，居中高亮、上下渐隐。完整的时间轴校准/整盘 CUE 偏移属后续。

#include "playback/PlayerController.h"
#include "media/Lyric.h"
#include "SkinWindow.h"

#include <QWidget>

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
    double m_pos = 0;
    int m_index = -1;
};
